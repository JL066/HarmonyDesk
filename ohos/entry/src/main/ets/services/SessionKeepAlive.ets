/**
 * Keep the remote session alive briefly after lock / minimize.
 * Uses HarmonyOS transient task (requestSuspendDelay); we disconnect after ~60s.
 *
 * Lifecycle semantics (background vs. user disconnect):
 *   - The 60s hold timeout is a *background-timeout* disconnect. The remote
 *     channel must come down so the process can be suspended, but the
 *     Session page itself is still logically active and should resume the
 *     prior remote session automatically on next foreground, with no user
 *     tap. This is signaled to the page via onBackgroundTimeout + a
 *     pending-resume latch that onAppForeground reads.
 *   - User-explicit disconnect (the 断开 button / page-exit teardown) does
 *     NOT go through this class — Session.disconnect() calls setActive(false)
 *     and Session's own state machine marks the disconnect as final, so the
 *     next foreground event will not auto-resume.
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const KEEP_MS = 60 * 1000;

export class SessionKeepAlive {
  private static active: boolean = false;
  private static foreground: boolean = true;
  private static requestId: number = -1;
  private static timer: number = -1;
  // Resumable teardown callback (background timeout). Distinct from any
  // user-explicit disconnect path that Session handles itself.
  private static backgroundTimeoutHandler: (() => void) | null = null;
  // Foreground-resume callback fired only when the hold timer actually
  // expired (resumable disconnect). Used to re-establish the prior remote
  // session without a user tap.
  private static foregroundResumeHandler: (() => void) | null = null;
  // Set when the background hold fires; cleared by consumePendingResume()
  // or by setActive(false). The foreground-resume callback is gated on
  // this flag so a normal foreground that returned within the hold window
  // does not spuriously start a reconnect.
  private static pendingResume: boolean = false;
  private static visibilityHandler: ((foreground: boolean) => void) | null = null;

  static setActive(
    active: boolean,
    onBackgroundTimeout?: () => void,
    onForegroundResume?: () => void,
    onVisibilityChange?: (foreground: boolean) => void
  ): void {
    SessionKeepAlive.active = active;
    if (active) {
      if (onVisibilityChange) { SessionKeepAlive.visibilityHandler = onVisibilityChange; }
      SessionKeepAlive.visibilityHandler?.(SessionKeepAlive.foreground);
      if (onBackgroundTimeout) {
        SessionKeepAlive.backgroundTimeoutHandler = onBackgroundTimeout;
      }
      if (onForegroundResume) {
        SessionKeepAlive.foregroundResumeHandler = onForegroundResume;
      }
      if (!SessionKeepAlive.foreground) { SessionKeepAlive.onAppBackground(); }
    }
    if (!active) {
      SessionKeepAlive.clearBackgroundHold();
      SessionKeepAlive.backgroundTimeoutHandler = null;
      SessionKeepAlive.foregroundResumeHandler = null;
      SessionKeepAlive.pendingResume = false;
      SessionKeepAlive.visibilityHandler = null;
    }
  }

  static isActive(): boolean {
    return SessionKeepAlive.active;
  }

  static isPendingResume(): boolean {
    return SessionKeepAlive.pendingResume;
  }

  /** Clear the pending-resume latch once the page has handled (or skipped) it. */
  static consumePendingResume(): void {
    SessionKeepAlive.pendingResume = false;
  }

  /** Ability entered background (lock screen / home / switch app). */
  static onAppBackground(): void {
    SessionKeepAlive.foreground = false;
    SessionKeepAlive.visibilityHandler?.(false);
    if (!SessionKeepAlive.active) {
      return;
    }
    SessionKeepAlive.clearBackgroundHold();
    let waitMs = KEEP_MS;
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay('保留远程桌面连接', () => {
        console.info('[SessionKeepAlive] suspend delay about to timeout');
        SessionKeepAlive.forceDisconnect();
      });
      SessionKeepAlive.requestId = delayInfo.requestId;
      const sysMs = delayInfo.actualDelayTime;
      if (sysMs > 0) {
        waitMs = Math.min(KEEP_MS, Math.max(3000, sysMs - 1500));
      }
      console.info(`[SessionKeepAlive] background hold id=${SessionKeepAlive.requestId} wait=${waitMs} sys=${sysMs}`);
    } catch (error) {
      console.warn('[SessionKeepAlive] requestSuspendDelay failed: ' + JSON.stringify(error));
    }
    SessionKeepAlive.timer = setTimeout(() => {
      SessionKeepAlive.forceDisconnect();
    }, waitMs);
  }

  /** Ability returned to foreground. */
  static onAppForeground(): void {
    SessionKeepAlive.foreground = true;
    SessionKeepAlive.visibilityHandler?.(true);
    if (SessionKeepAlive.requestId >= 0 || SessionKeepAlive.timer !== -1) {
      console.info('[SessionKeepAlive] foreground, cancel background disconnect');
    }
    SessionKeepAlive.clearBackgroundHold();
    if (SessionKeepAlive.pendingResume && SessionKeepAlive.foregroundResumeHandler) {
      const handler = SessionKeepAlive.foregroundResumeHandler;
      console.info('[SessionKeepAlive] foreground resume reconnect');
      try {
        // Keep the pending-resume latch observable while the handler runs:
        // Session.resumeFromBackground() gates on isPendingResume() and would
        // otherwise short-circuit before re-establishing the channel.
        handler();
      } catch (error) {
        console.warn('[SessionKeepAlive] resume handler threw: ' + JSON.stringify(error));
      } finally {
        // Clear the latch whether the page consumed it via
        // consumePendingResume() or threw before consuming it, so a later
        // foreground event cannot re-fire this same teardown's resume.
        SessionKeepAlive.pendingResume = false;
      }
    }
  }

  private static forceDisconnect(): void {
    SessionKeepAlive.clearBackgroundHold();
    if (!SessionKeepAlive.active) {
      return;
    }
    // Mark as a RESUMABLE background release — do not flip the Session
    // page's intentionalDisconnect; the next foreground should reconnect.
    console.info('[SessionKeepAlive] background timeout -> resumable disconnect');
    SessionKeepAlive.pendingResume = true;
    SessionKeepAlive.active = false;
    const handler = SessionKeepAlive.backgroundTimeoutHandler;
    if (handler) {
      try {
        handler();
      } catch (error) {
        console.warn('[SessionKeepAlive] background timeout handler threw: ' + JSON.stringify(error));
      }
    }
  }

  private static clearBackgroundHold(): void {
    if (SessionKeepAlive.timer !== -1) {
      clearTimeout(SessionKeepAlive.timer);
      SessionKeepAlive.timer = -1;
    }
    if (SessionKeepAlive.requestId >= 0) {
      try {
        backgroundTaskManager.cancelSuspendDelay(SessionKeepAlive.requestId);
      } catch (_e) {
      }
      SessionKeepAlive.requestId = -1;
    }
  }
}
