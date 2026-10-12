import type common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import type { HarmonyDeskNative } from '../native/HarmonyDeskNative';

// Text transport belongs to the session; this service never sends key events.
// Background pasteboard access is OS-restricted. Foreground refresh reconciles
// changes missed while suspended; the timer also compensates for missed events.
export class ClipboardSync {
  private native: HarmonyDeskNative | null = null;
  private context: common.UIAbilityContext | null = null;
  private allowed: () => boolean = (): boolean => false;
  private report: (status: string) => void = (_status: string): void => {};
  private timer: number = -1;
  private epoch: number = 0;
  private runningEpoch: number = -1;
  private foreground: boolean = true;
  private listening: boolean = false;
  private permissionAttempted: boolean = false;
  private permissionGranted: boolean = false;
  private remoteSeq: number = 0;
  private peerAllowed: boolean = true;
  private lastLocalText: string | null = null;
  private localObserved: boolean = false;
  private pendingEchoes: Array<string> = [];
  private baselineAfterEmpty: boolean = false;
  private lastStatus: string = '';
  private updateHandler: () => void = (): void => { this.refresh(); };

  start(native: HarmonyDeskNative, context: common.UIAbilityContext,
    canSync: () => boolean, onStatus: (status: string) => void): void {
    this.stop();
    this.native = native;
    this.context = context;
    this.allowed = canSync;
    this.report = onStatus;
    this.lastStatus = '';
    this.remoteSeq = 0;
    this.lastLocalText = null;
    this.localObserved = false;
    this.pendingEchoes = [];
    this.baselineAfterEmpty = false;
    try {
      pasteboard.getSystemPasteboard().on('update', this.updateHandler);
      this.listening = true;
    } catch (_) {
      // Polling remains available on devices without update notifications.
    }
    this.timer = setInterval((): void => { this.refresh(); }, 750);
    this.refresh();
  }

  stop(): void {
    this.epoch++;
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.listening) {
      try { pasteboard.getSystemPasteboard().off('update', this.updateHandler); } catch (_) {}
      this.listening = false;
    }
    this.native = null;
    this.context = null;
    this.lastLocalText = null;
    this.localObserved = false;
    this.pendingEchoes = [];
    this.baselineAfterEmpty = false;
    this.permissionGranted = false;
  }

  setForeground(value: boolean): void {
    if (this.foreground !== value) {
      this.foreground = value;
      this.epoch++;
    }
    if (value) { this.refresh(); }
  }

  refresh(): void {
    const peerAllowed = this.native !== null && this.native.isClipboardAllowed();
    if (peerAllowed !== this.peerAllowed) {
      this.peerAllowed = peerAllowed;
      this.epoch++;
    }
    if (this.native !== null && !peerAllowed) {
      this.status('远端已禁用剪贴板同步');
      return;
    }
    const token = this.epoch;
    // Serialize across lifecycle epochs as well: an OS write already submitted
    // cannot be cancelled and must settle before a new session starts a write.
    if (!this.valid(token) || this.runningEpoch !== -1) { return; }
    this.runningEpoch = token;
    void this.reconcile(token);
  }

  private valid(token: number): boolean {
    return this.epoch === token && this.native !== null && this.foreground &&
      this.allowed() && this.native.isClipboardAllowed();
  }

  private status(value: string): void {
    if (this.lastStatus !== value) {
      this.lastStatus = value;
      this.report(value);
    }
  }

  private async checkPermission(token: number): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const permission: Permissions = 'ohos.permission.READ_PASTEBOARD';
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      if (manager.checkAccessTokenSync(info.appInfo.accessTokenId, permission) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { return true; }
      if (!this.permissionAttempted && this.context !== null && this.valid(token)) {
        // Preserve this latch across stop/start: a denial must never produce
        // timer-driven or reconnect-driven permission dialogs.
        this.permissionAttempted = true;
        await manager.requestPermissionsFromUser(this.context, [permission]);
        if (!this.valid(token)) { return false; }
        return manager.checkAccessTokenSync(info.appInfo.accessTokenId, permission) ===
          abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      }
    } catch (_) {
      this.permissionAttempted = true;
    }
    return false;
  }

  private async reconcile(token: number): Promise<void> {
    try {
      const granted = await this.checkPermission(token);
      if (!this.valid(token)) { return; }
      this.permissionGranted = granted;
      const native = this.native;
      if (native === null) { return; }
      const board = pasteboard.getSystemPasteboard();
      let local: string | null = null;
      let localReadable: boolean = false;
      if (this.permissionGranted) {
        const observedSeq = native.getRemoteClipboardSeq();
        try {
          const data = await board.getData();
          if (!this.valid(token) || native.getRemoteClipboardSeq() !== observedSeq) { return; }
          if (data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
            const value = data.getPrimaryText();
            if (value.length > 0) { local = value; }
          }
          localReadable = true;
        } catch (_) {
          // A temporarily unreadable or empty OS clipboard must not disable
          // remote-to-local writes, which do not need READ_PASTEBOARD.
          if (!this.valid(token)) { return; }
        }
      }
      if (localReadable && this.baselineAfterEmpty) {
        this.lastLocalText = local;
        this.localObserved = true;
        this.baselineAfterEmpty = false;
      }
      // Read an internally consistent snapshot. A failed/racing read is
      // retried next tick without acknowledging the generation.
      const before = native.getRemoteClipboardSeq();
      // When both endpoints changed while suspended, the newly observed local
      // copy wins. Inspect it BEFORE writing a pending remote snapshot so that
      // returning from another app never erases the text just copied there.
      if (localReadable && this.localObserved && local !== null && local !== this.lastLocalText) {
        if (!this.sendLocal(native, local)) { return; }
        this.remoteSeq = before;
        this.status('剪贴板同步已开启（文本）');
        return;
      }
      if (before > 0 && before !== this.remoteSeq) {
        const remote = native.getRemoteClipboardText();
        const after = native.getRemoteClipboardSeq();
        if (!this.valid(token) || before !== after) { return; }
        const echoIndex = this.pendingEchoes.indexOf(remote);
        if (echoIndex >= 0) {
          // A delayed echo of A must not replace a newer local B. Consume each
          // expected echo once; do not permanently blacklist matching content.
          this.pendingEchoes.splice(echoIndex, 1);
          this.remoteSeq = after;
        } else if (remote.length > 0) {
          // Native represents empty and invalid snapshots identically. Do not
          // erase a user's clipboard from an ambiguous empty snapshot.
          if (remote !== this.lastLocalText) {
            await board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, remote));
            if (!this.valid(token)) { return; }
            this.lastLocalText = remote;
          }
          local = remote;
          this.localObserved = true;
          this.remoteSeq = after;
          this.baselineAfterEmpty = false;
        } else {
          // Empty cannot be distinguished from an invalid native snapshot.
          // Observe it without erasing local data or sending old local text
          // back over it. A subsequent fresh local copy can still be sent.
          this.remoteSeq = after;
          this.baselineAfterEmpty = !localReadable;
          if (localReadable) {
            this.lastLocalText = local;
            this.localObserved = true;
          }
          this.status('文本剪贴板同步已开启；暂不支持同步清空');
          return;
        }
      }
      if (!this.permissionGranted) {
        this.status('剪贴板接收已开启；发送需允许读取剪贴板');
        return;
      }
      if (!localReadable) {
        this.status('剪贴板接收已开启；本地读取暂不可用，发送正在重试');
        return;
      }
      this.localObserved = true;
      if (local === null) {
        this.lastLocalText = null;
      } else if (local !== this.lastLocalText) {
        if (!this.sendLocal(native, local)) { return; }
      }
      this.status('剪贴板同步已开启（文本）');
    } catch (_) {
      if (this.valid(token)) { this.status('剪贴板暂不可用，返回前台后自动重试'); }
    } finally {
      if (this.runningEpoch === token) { this.runningEpoch = -1; }
    }
  }

  private sendLocal(native: HarmonyDeskNative, text: string): boolean {
    if (native.sendClipboardText(text) !== 0) {
      this.status('剪贴板发送暂不可用，正在重试');
      return false;
    }
    this.lastLocalText = text;
    this.localObserved = true;
    const previous = this.pendingEchoes.indexOf(text);
    if (previous >= 0) { this.pendingEchoes.splice(previous, 1); }
    this.pendingEchoes.push(text);
    // Bound both entry count and total UTF-16 code units (at most 16 MiB).
    // Retain newest ownership hints first. Never log clipboard contents.
    let characters: number = 0;
    for (const pending of this.pendingEchoes) { characters += pending.length; }
    while (this.pendingEchoes.length > 16 || characters > 8 * 1024 * 1024) {
      const removed = this.pendingEchoes.shift();
      if (removed !== undefined) { characters -= removed.length; }
    }
    return true;
  }
}
