/**
 * Type declarations for libharmonydesk.so native module
 * This file provides TypeScript definitions for the NAPI bindings
 */

export interface NativeVideoFrame {
  width: number;
  height: number;
  data: ArrayBuffer;
  timestamp: number;
}

export interface NativeVideoStats {
  status: number;
  packets: number;
  frames: number;
  width: number;
  height: number;
  decoded: number;
  pushed?: number;
  surface?: number;
  convertMs?: number;
  queue?: number;
}

export interface HarmonyDeskNativeModule {
  /**
   * Initialize the native module
   * @returns 0 on success, error code otherwise
   */
  init(): number;
  initDebug(): number;

  /**
   * Configure server settings
   * @param idServer - ID server address
   * @param relayServer - Relay server address
   * @param forceRelay - Whether to force relay connection
   * @param key - Encryption key
   * @returns 0 on success, error code otherwise
   */
  setServerConfig(idServer: string, relayServer: string, forceRelay: boolean, key: string): number;

  /**
   * Connect to a remote desktop
   * @param deskId - Remote desktop ID
   * @param password - Connection password
   * @returns 0 on success, error code otherwise
   */
  connect(deskId: string, password: string): number;

  /**
   * Disconnect all connections
   */
  disconnect(): void;

  /**
   * Clean up resources
   */
  cleanup(): void;

  /**
   * Get current connection status
   * @returns Connection status code (0 = disconnected, 1 = connecting, 2 = connected)
   */
  getConnectionStatus(): number;

  /**
   * Send keyboard event
   * @param keyCode - Key code
   * @param pressed - Whether key is pressed
   */
  sendKeyEvent(keyCode: number, pressed: boolean): void;

  /**
   * Send mouse move event
   * @param x - X coordinate
   * @param y - Y coordinate
   */
  sendMouseMove(x: number, y: number): void;

  /**
   * Send mouse click event
   * @param button - Button number (0 = left, 1 = middle, 2 = right)
   * @param pressed - Whether button is pressed
   */
  sendMouseClick(button: number, pressed: boolean): void;
  sendText(text: string): void;
  /**
   * Send plain text via RustDesk clipboard transport (Message field 16).
   * Returns: 0 = enqueued, 1 = empty (no-op), -1 = core not ready.
   * UTF-8 is forwarded byte-for-byte — no trimming / normalization.
   */
  sendClipboardText(text: string): number;
  isClipboardAllowed(): boolean;
  /**
   * Stage 3A: monotonic generation counter for the cached remote clipboard.
   * Increases by 1 for every accepted plain-text clipboard update.
   * UI snapshots this before triggering a local read action and waits for
   * a new value to detect a fresh remote clipboard.
   */
  getRemoteClipboardSeq(): number;
  /**
   * Stage 3A: return the latest remote clipboard text (UTF-8 round-tripped).
   * Empty string when no clipboard has been received in the current session,
   * or when the cached payload is inconsistent / exceeds the 8 MiB cap.
   * The C++ wrapper dynamically sizes its buffer from the FFI size query,
   * so the full accepted payload (up to 8 MiB) is returned byte-for-byte
   * with no truncation.
   */
  getRemoteClipboardText(): string;
  sendControlKey(code: number, pressed: boolean): void;
  /** kind: 1 = character code point, 2 = RustDesk ControlKey; modifiers are ControlKey values. */
  sendHardwareKey(kind: number, code: number, pressed: boolean, modifiers: number[]): void;
  /** modifier+key: chr ASCII or 1000+ControlKey; modifier ControlKey (Alt=1,Ctrl=4,Meta=23) */
  sendChord(chr: number, modifier: number): void;
  setImageQuality(quality: number): void;

  /**
   * Get latest video frame
   * @returns Video frame or null if no frame available
   */
  getVideoFrame(): NativeVideoFrame | null;
  getVideoStats(): NativeVideoStats;
  bindVideoSurface(surfaceId: string): number;
  unbindVideoSurface(): void;
  getLogs(): string;
  getLastError(): string | null;
  clearLogs(): void;
}

export default {} as HarmonyDeskNativeModule;
