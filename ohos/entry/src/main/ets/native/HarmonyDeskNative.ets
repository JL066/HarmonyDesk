/**
 * HarmonyDesk Native Module Bridge
 *
 * This module provides a bridge to the Rust native library (libharmonydesk.so)
 * for HarmonyOS remote desktop functionality.
 */

// Import the native module
import nativeModule from 'libharmonydesk.so';

// Native module interface
export interface HarmonyDeskNative {
  // Initialize the native module
  init(): number;

  // Initialize debug mode (set up panic hook)
  initDebug(): number;

  // Configure server settings
  setServerConfig(idServer: string, relayServer: string, forceRelay: boolean, key: string): number;

  // Connect to a remote desktop
  connect(deskId: string, password: string): number;

  // Punch-hole online check (non-blocking). Poll getCheckResult().
  checkPeer(deskId: string): number;
  getCheckResult(): string;

  // Disconnect all connections
  disconnect(): void;

  // Clean up resources
  cleanup(): void;

  // Get current connection status
  getConnectionStatus(): number;

  // Send keyboard event
  sendKeyEvent(keyCode: number, pressed: boolean): void;

  // Send mouse move event
  sendMouseMove(x: number, y: number): void;

  // Send mouse click event
  sendMouseClick(button: number, pressed: boolean): void;
  // Vertical wheel: positive = up, negative = down
  sendMouseWheel(deltaY: number): void;
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
  /**
   * Modifier + key chord.
   * modifier: ControlKey (Control=4, Alt=1, Shift=29, Meta=23)
   * chr: ASCII 1..255, or 32=Space, or 1000+ControlKey (e.g. 1015=F4)
   */
  sendChord(chr: number, modifier: number): void;
  /** 2=Low, 3=Balanced, 4=Best */
  setImageQuality(quality: number): void;

  // Get latest video frame
  getVideoFrame(): VideoFrame | null;
  getVideoStats(): VideoStats;
  bindVideoSurface(surfaceId: string): number;
  unbindVideoSurface(): void;

  // ===== Debug functions =====

  // Get all Rust logs
  getLogs(): string;

  // Get last error or panic message
  getLastError(): string | null;

  // Clear all logs
  clearLogs(): void;
}

export interface VideoFrame {
  width: number;
  height: number;
  data: ArrayBuffer;
  timestamp: number;
}

export interface VideoStats {
  status: number;
  packets: number;
  frames: number;
  width: number;
  height: number;
  decoded: number;
  pushed: number;
  surface: number;
  convertMs: number;
  queue: number;
}

// Module info interface
export interface ModuleInfo {
  usingMock: boolean;
  initialized: boolean;
}

// Wrapper class that implements HarmonyDeskNative interface
class NativeModuleWrapper implements HarmonyDeskNative {
  init(): number {
    try {
      console.info('[HarmonyDeskNative] Calling nativeModule.init()...');
      const result: number = nativeModule.init();
      console.info('[HarmonyDeskNative] nativeModule.init() returned:', result);
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] init error:', e);
      console.error('[HarmonyDeskNative] Error type:', typeof e);
      console.error('[HarmonyDeskNative] Error string:', String(e));
      if (e instanceof Error) {
        console.error('[HarmonyDeskNative] Error message:', e.message);
        console.error('[HarmonyDeskNative] Error stack:', e.stack);
      }
      return -1;
    }
  }

  initDebug(): number {
    try {
      const result: number = nativeModule.initDebug();
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] initDebug error:', e);
      return -1;
    }
  }

  setServerConfig(idServer: string, relayServer: string, forceRelay: boolean, key: string): number {
    try {
      const result: number = nativeModule.setServerConfig(idServer, relayServer, forceRelay, key);
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] setServerConfig error: ' + JSON.stringify(e));
      return -1;
    }
  }

  connect(deskId: string, password: string): number {
    try {
      const result: number = nativeModule.connect(deskId, password);
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] connect error: ' + JSON.stringify(e));
      return -1;
    }
  }

  checkPeer(deskId: string): number {
    try {
      return nativeModule.checkPeer(deskId);
    } catch (e) {
      console.error('[HarmonyDeskNative] checkPeer error: ' + JSON.stringify(e));
      return -1;
    }
  }

  getCheckResult(): string {
    try {
      return nativeModule.getCheckResult();
    } catch (e) {
      console.error('[HarmonyDeskNative] getCheckResult error: ' + JSON.stringify(e));
      return '';
    }
  }

  disconnect(): void {
    try {
      nativeModule.disconnect();
    } catch (e) {
      console.error('[HarmonyDeskNative] disconnect error: ' + JSON.stringify(e));
    }
  }

  cleanup(): void {
    try {
      nativeModule.cleanup();
    } catch (e) {
      console.error('[HarmonyDeskNative] cleanup error: ' + JSON.stringify(e));
    }
  }

  getConnectionStatus(): number {
    try {
      const result: number = nativeModule.getConnectionStatus();
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] getConnectionStatus error: ' + JSON.stringify(e));
      return 0;
    }
  }

  sendKeyEvent(keyCode: number, pressed: boolean): void {
    try {
      nativeModule.sendKeyEvent(keyCode, pressed);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendKeyEvent error: ' + JSON.stringify(e));
    }
  }

  sendMouseMove(x: number, y: number): void {
    try {
      nativeModule.sendMouseMove(x, y);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendMouseMove error: ' + JSON.stringify(e));
    }
  }

  sendMouseClick(button: number, pressed: boolean): void {
    try {
      nativeModule.sendMouseClick(button, pressed);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendMouseClick error: ' + JSON.stringify(e));
    }
  }

  sendMouseWheel(deltaY: number): void {
    try {
      nativeModule.sendMouseWheel(deltaY);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendMouseWheel error: ' + JSON.stringify(e));
    }
  }

  sendText(text: string): void {
    try {
      nativeModule.sendText(text);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendText error: ' + JSON.stringify(e));
    }
  }

  sendClipboardText(text: string): number {
    try {
      const result: number = nativeModule.sendClipboardText(text);
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] sendClipboardText error: ' + JSON.stringify(e));
      return -1;
    }
  }

  isClipboardAllowed(): boolean {
    try {
      return nativeModule.isClipboardAllowed();
    } catch (e) {
      return false;
    }
  }

  getRemoteClipboardSeq(): number {
    try {
      const result: number = nativeModule.getRemoteClipboardSeq();
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] getRemoteClipboardSeq error: ' + JSON.stringify(e));
      return 0;
    }
  }

  getRemoteClipboardText(): string {
    try {
      const result: string = nativeModule.getRemoteClipboardText();
      return result;
    } catch (e) {
      console.error('[HarmonyDeskNative] getRemoteClipboardText error: ' + JSON.stringify(e));
      return '';
    }
  }

  sendControlKey(code: number, pressed: boolean): void {
    try {
      nativeModule.sendControlKey(code, pressed);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendControlKey error: ' + JSON.stringify(e));
    }
  }

  sendChord(chr: number, modifier: number): void {
    try {
      nativeModule.sendChord(chr, modifier);
    } catch (e) {
      console.error('[HarmonyDeskNative] sendChord error: ' + JSON.stringify(e));
    }
  }

  setImageQuality(quality: number): void {
    try {
      nativeModule.setImageQuality(quality);
    } catch (e) {
      console.error('[HarmonyDeskNative] setImageQuality error: ' + JSON.stringify(e));
    }
  }

  getVideoFrame(): VideoFrame | null {
    try {
      const frame: ESObject | null = nativeModule.getVideoFrame();
      if (frame !== null && typeof frame === 'object') {
        return {
          width: (frame as ESObject)['width'] as number,
          height: (frame as ESObject)['height'] as number,
          data: (frame as ESObject)['data'] as ArrayBuffer,
          timestamp: (frame as ESObject)['timestamp'] as number
        };
      }
      return null;
    } catch (e) {
      console.error('[HarmonyDeskNative] getVideoFrame error: ' + JSON.stringify(e));
      return null;
    }
  }

  getVideoStats(): VideoStats {
    try {
      const stats: ESObject = nativeModule.getVideoStats() as ESObject;
      return {
        status: (stats['status'] as number) ?? 0,
        packets: (stats['packets'] as number) ?? 0,
        frames: (stats['frames'] as number) ?? 0,
        width: (stats['width'] as number) ?? 0,
        height: (stats['height'] as number) ?? 0,
        decoded: (stats['decoded'] as number) ?? 0,
        pushed: (stats['pushed'] as number) ?? 0,
        surface: (stats['surface'] as number) ?? 0,
        convertMs: (stats['convertMs'] as number) ?? 0,
        queue: (stats['queue'] as number) ?? 0
      };
    } catch (e) {
      return {
        status: 0, packets: 0, frames: 0, width: 0, height: 0, decoded: 0,
        pushed: 0, surface: 0, convertMs: 0, queue: 0
      };
    }
  }

  bindVideoSurface(surfaceId: string): number {
    try {
      return nativeModule.bindVideoSurface(surfaceId);
    } catch (e) {
      console.error('[HarmonyDeskNative] bindVideoSurface error: ' + JSON.stringify(e));
      return -1;
    }
  }

  unbindVideoSurface(): void {
    try {
      nativeModule.unbindVideoSurface();
    } catch (e) {
      console.error('[HarmonyDeskNative] unbindVideoSurface error: ' + JSON.stringify(e));
    }
  }

  // ===== Debug functions =====

  getLogs(): string {
    try {
      const logs: string = nativeModule.getLogs();
      return logs;
    } catch (e) {
      console.error('[HarmonyDeskNative] getLogs error: ' + JSON.stringify(e));
      return '[HarmonyDeskNative] Failed to get logs: ' + JSON.stringify(e);
    }
  }

  getLastError(): string | null {
    try {
      const error: ESObject | null = nativeModule.getLastError();
      if (error === null || error === undefined) {
        return null;
      }
      const errorStr = String(error);
      if (errorStr === 'null' || errorStr === 'undefined') {
        return null;
      }
      return errorStr;
    } catch (e) {
      console.error('[HarmonyDeskNative] getLastError error: ' + JSON.stringify(e));
      return JSON.stringify(e);
    }
  }

  clearLogs(): void {
    try {
      nativeModule.clearLogs();
    } catch (e) {
      console.error('[HarmonyDeskNative] clearLogs error: ' + JSON.stringify(e));
    }
  }
}

// Module loading state
let nativeModuleInstance: NativeModuleWrapper | null = null;
let isInitialized = false;
let initPromise: Promise<boolean> | null = null;

/**
 * Initialize the native HarmonyDesk module
 */
export async function initHarmonyDesk(): Promise<boolean> {
  if (isInitialized && nativeModuleInstance != null) {
    return true;
  }

  if (initPromise != null) {
    return initPromise;
  }

  initPromise = new Promise<boolean>((resolve, reject) => {
    setTimeout(() => {
    try {
      console.info('[HarmonyDeskNative] Loading native module...');
      console.info('[HarmonyDeskNative] nativeModule type:', typeof nativeModule);
      console.info('[HarmonyDeskNative] nativeModule:', nativeModule);

      // Create wrapper instance
      nativeModuleInstance = new NativeModuleWrapper();
      console.info('[HarmonyDeskNative] Wrapper instance created');

      // Initialize the native module
      const result: number = nativeModuleInstance.init();
      console.info('[HarmonyDeskNative] init() returned:', result);
      
      if (result === 0) {
        isInitialized = true;
        console.info('[HarmonyDeskNative] Native module initialized successfully');
        resolve(true);
      } else if (result === 1) {
        // Already initialized
        isInitialized = true;
        console.info('[HarmonyDeskNative] Native module already initialized');
        resolve(true);
      } else {
        console.error('[HarmonyDeskNative] Native module initialization failed with code: ' + result);
        reject(new Error('Native module initialization failed with code: ' + result));
      }
    } catch (error) {
      console.error('[HarmonyDeskNative] Failed to initialize:', error);
      console.error('[HarmonyDeskNative] Error type:', typeof error);
      if (error instanceof Error) {
        console.error('[HarmonyDeskNative] Error message:', error.message);
        console.error('[HarmonyDeskNative] Error stack:', error.stack);
      }
      reject(error);
    }
    }, 0);
  });

  return initPromise;
}

/**
 * Get the native module instance (initializes if needed)
 */
export async function getNativeModule(): Promise<HarmonyDeskNative | null> {
  try {
    await initHarmonyDesk();
    return nativeModuleInstance;
  } catch (error) {
    console.error('[HarmonyDeskNative] Failed to get native module: ' + JSON.stringify(error));
    return null;
  }
}

/**
 * Check if the actual native module is loaded (not mock)
 */
export function isNativeModuleLoaded(): boolean {
  return isInitialized && nativeModuleInstance !== null;
}

/**
 * Get module info for debugging
 */
export function getModuleInfo(): ModuleInfo {
  const info: ModuleInfo = {
    usingMock: false, // Using real native module
    initialized: isInitialized
  };
  return info;
}

/**
 * Debug information interface
 */
export interface DebugInfo {
  initialized: boolean;
  logs: string;
  lastError: string;
  connectionStatus: number;
}

/**
 * Get debug information from the native module
 * Useful for troubleshooting Rust layer errors
 */
export async function getDebugInfo(): Promise<DebugInfo> {
  const module = await getNativeModule();

  if (module === null) {
    return {
      initialized: false,
      logs: 'Native module not initialized',
      lastError: 'Native module not initialized',
      connectionStatus: 0
    };
  }

  const logs = module.getLogs();
  const lastError = module.getLastError();

  return {
    initialized: isInitialized,
    logs: logs,
    lastError: lastError ?? 'No error',
    connectionStatus: module.getConnectionStatus()
  };
}

/**
 * Print debug info to console (useful for hdc shell hidumper)
 */
export async function printDebugInfo(): Promise<void> {
  const info = await getDebugInfo();
  console.info('========== HarmonyDesk Debug Info ==========');
  console.info('Initialized:', info.initialized);
  console.info('Connection Status:', info.connectionStatus);
  console.info('Last Error:', info.lastError);
  console.info('--- Logs ---');
  console.info(info.logs);
  console.info('=============================================');
}
