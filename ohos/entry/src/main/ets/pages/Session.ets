import router from '@ohos.router';
import type common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { display, window, KeyboardAvoidMode as UIKeyboardAvoidMode } from '@kit.ArkUI';
import inputMethod from '@ohos.inputMethod';
import { image } from '@kit.ImageKit';
import { isOfficialPlaceholderHost, isPlaceholderKey, isDirectIpId, RustDeskStore } from '../services/RustDeskStore';
import type { HarmonyDeskNative } from '../native/HarmonyDeskNative';
import { ClipboardSync } from '../services/ClipboardSync';
import { SessionKeepAlive } from '../services/SessionKeepAlive';

class TrackpadLogic {
  cursorX: number = 0;
  cursorY: number = 0;
  gestureStartX: number = 0;
  gestureStartY: number = 0;
  ignoreGesture: boolean = false;
  freezeMove: boolean = false;
}

export enum DisplayMode {
  FIT = 'fit',
  FILL = 'fill',
  ORIGINAL = '1:1'
}

export function mapScreenToRemote(
  sx: number,
  sy: number,
  originX: number,
  originY: number,
  renderedW: number,
  renderedH: number,
  remoteW: number,
  remoteH: number
): [number, number] | null {
  if (
    !Number.isFinite(sx) || !Number.isFinite(sy) ||
    !Number.isFinite(originX) || !Number.isFinite(originY) ||
    !Number.isFinite(renderedW) || !Number.isFinite(renderedH) ||
    !Number.isFinite(remoteW) || !Number.isFinite(remoteH) ||
    renderedW <= 0 || renderedH <= 0 ||
    remoteW <= 0 || remoteH <= 0
  ) {
    return null;
  }

  const rawRx = (sx - originX) / renderedW * remoteW;
  const rawRy = (sy - originY) / renderedH * remoteH;

  if (!Number.isFinite(rawRx) || !Number.isFinite(rawRy)) {
    return null;
  }

  // Touches outside the rendered remote rectangle (e.g. FIT letterbox/pillarbox) return null
  const EPSILON = 1e-4;
  if (rawRx < -EPSILON || rawRx > remoteW + EPSILON ||
      rawRy < -EPSILON || rawRy > remoteH + EPSILON) {
    return null;
  }

  let rx = Math.round(rawRx);
  let ry = Math.round(rawRy);

  const maxRx = Math.max(0, Math.floor(remoteW) - 1);
  const maxRy = Math.max(0, Math.floor(remoteH) - 1);

  if (rx < 0) {
    rx = 0;
  } else if (rx > maxRx) {
    rx = maxRx;
  }

  if (ry < 0) {
    ry = 0;
  } else if (ry > maxRy) {
    ry = maxRy;
  }

  return [rx, ry];
}

export function runGeometrySanityChecks(): boolean {
  // Check 1: FIT 1920x1080 inside representative tablet viewport 1280x800
  const vbFit = new ViewBox();
  vbFit.mode = DisplayMode.FIT;
  vbFit.updateGeometry(1280, 800, 1920, 1080);
  const center = vbFit.screenToRemote(640, 400);
  const cornerTL = vbFit.screenToRemote(vbFit.originX, vbFit.originY);
  const cornerBR = vbFit.screenToRemote(vbFit.originX + vbFit.renderedW, vbFit.originY + vbFit.renderedH);
  const lbTop = vbFit.screenToRemote(640, 10);
  const lbBtm = vbFit.screenToRemote(640, 790);

  // Check 2: FILL in 1280x800
  const vbFill = new ViewBox();
  vbFill.mode = DisplayMode.FILL;
  vbFill.updateGeometry(1280, 800, 1920, 1080);
  const fillCenter = vbFill.screenToRemote(640, 400);
  const fillLeft = vbFill.screenToRemote(0, 400);

  // Check 3: 1:1 with pan
  const vb11 = new ViewBox();
  vb11.mode = DisplayMode.ORIGINAL;
  vb11.panX = 100;
  vb11.panY = -50;
  vb11.updateGeometry(1280, 800, 1920, 1080);
  const p11 = vb11.screenToRemote(640, 400);

  // Check 4: Relative motion scales
  const sX = (1920 / 1280) * 0.90;
  const sY = (1080 / 800) * 0.90;

  const ok = (center !== null && center[0] === 960 && center[1] === 540)
    && (cornerTL !== null && cornerTL[0] === 0 && cornerTL[1] === 0)
    && (cornerBR !== null && cornerBR[0] === 1919 && cornerBR[1] === 1079)
    && (lbTop === null && lbBtm === null)
    && (fillCenter !== null && fillCenter[0] === 960 && fillCenter[1] === 540)
    && (fillLeft !== null && fillLeft[0] === 96 && fillLeft[1] === 540)
    && (p11 !== null && p11[0] === 860 && p11[1] === 590)
    && (Math.abs(sX - 1.35) < 0.001 && Math.abs(sY - 1.215) < 0.001);

  console.info(`[HdHud] [GeometrySanity] pass=${ok} center=${center} tl=${cornerTL} br=${cornerBR} lbTop=${lbTop} lbBtm=${lbBtm} fill=${fillCenter} 1:1=${p11} sX=${sX.toFixed(3)} sY=${sY.toFixed(3)}`);
  return ok;
}

export function mapRemoteToScreen(
  rx: number,
  ry: number,
  originX: number,
  originY: number,
  renderedW: number,
  renderedH: number,
  remoteW: number,
  remoteH: number,
  viewportW: number = 0,
  viewportH: number = 0
): [number, number] {
  if (
    !Number.isFinite(rx) || !Number.isFinite(ry) ||
    !Number.isFinite(originX) || !Number.isFinite(originY) ||
    !Number.isFinite(renderedW) || !Number.isFinite(renderedH) ||
    !Number.isFinite(remoteW) || !Number.isFinite(remoteH) ||
    remoteW <= 0 || remoteH <= 0
  ) {
    return [viewportW > 0 ? viewportW / 2 : 0, viewportH > 0 ? viewportH / 2 : 0];
  }

  const sx = originX + (rx / remoteW) * renderedW;
  const sy = originY + (ry / remoteH) * renderedH;

  if (!Number.isFinite(sx) || !Number.isFinite(sy)) {
    return [viewportW > 0 ? viewportW / 2 : 0, viewportH > 0 ? viewportH / 2 : 0];
  }

  return [sx, sy];
}

class ViewBox {
  w: number = 0;
  h: number = 0;
  remoteW: number = 1920;
  remoteH: number = 1080;
  mode: DisplayMode = DisplayMode.FIT;
  userZoom: number = 1;
  panX: number = 0;
  panY: number = 0;

  // Authoritative geometry calculation results
  baseScale: number = 1;
  scale: number = 1; // effectiveScale = baseScale * userZoom
  renderedW: number = 0;
  renderedH: number = 0;
  originX: number = 0;
  originY: number = 0;

  updateGeometry(w?: number, h?: number, remoteW?: number, remoteH?: number): void {
    if (w !== undefined && Number.isFinite(w) && w > 0) {
      this.w = w;
    }
    if (h !== undefined && Number.isFinite(h) && h > 0) {
      this.h = h;
    }
    if (remoteW !== undefined && Number.isFinite(remoteW) && remoteW > 0) {
      this.remoteW = remoteW;
    }
    if (remoteH !== undefined && Number.isFinite(remoteH) && remoteH > 0) {
      this.remoteH = remoteH;
    }

    if (this.remoteW <= 0 || this.remoteH <= 0 || this.w <= 0 || this.h <= 0) {
      this.baseScale = 1;
      this.scale = this.userZoom;
      this.renderedW = this.w > 0 ? this.w : 0;
      this.renderedH = this.h > 0 ? this.h : 0;
      this.originX = this.panX;
      this.originY = this.panY;
      return;
    }

    // 1. Calculate baseScale for selected aspect-preserving mode
    if (this.mode === DisplayMode.FIT) {
      this.baseScale = Math.min(this.w / this.remoteW, this.h / this.remoteH);
    } else if (this.mode === DisplayMode.FILL) {
      this.baseScale = Math.max(this.w / this.remoteW, this.h / this.remoteH);
    } else if (this.mode === DisplayMode.ORIGINAL) {
      this.baseScale = 1.0;
    } else {
      this.baseScale = Math.min(this.w / this.remoteW, this.h / this.remoteH);
    }

    // 2. Effective scale with user zoom
    this.scale = this.baseScale * this.userZoom;

    // 3. Rendered dimensions (strictly aspect-preserving)
    this.renderedW = this.remoteW * this.scale;
    this.renderedH = this.remoteH * this.scale;

    // 4. Constrain pan limits
    this.constrainPan();

    // 5. Origin coordinates
    this.originX = (this.w - this.renderedW) / 2 + this.panX;
    this.originY = (this.h - this.renderedH) / 2 + this.panY;
  }

  constrainPan(): void {
    if (this.renderedW > this.w) {
      const limitX = (this.renderedW - this.w) / 2;
      if (this.panX > limitX) {
        this.panX = limitX;
      }
      if (this.panX < -limitX) {
        this.panX = -limitX;
      }
    } else {
      this.panX = 0;
    }

    if (this.renderedH > this.h) {
      const limitY = (this.renderedH - this.h) / 2;
      if (this.panY > limitY) {
        this.panY = limitY;
      }
      if (this.panY < -limitY) {
        this.panY = -limitY;
      }
    } else {
      this.panY = 0;
    }
  }

  setMode(mode: DisplayMode): void {
    this.mode = mode;
    this.userZoom = 1;
    this.panX = 0;
    this.panY = 0;
    this.updateGeometry();
  }

  setUserZoom(zoom: number): void {
    if (!Number.isFinite(zoom) || zoom < 1) {
      zoom = 1;
    }
    if (zoom > 5) {
      zoom = 5;
    }
    this.userZoom = zoom;
    if (this.userZoom <= 1.01) {
      this.userZoom = 1;
      if (this.mode === DisplayMode.FIT) {
        this.panX = 0;
        this.panY = 0;
      }
    }
    this.updateGeometry();
  }

  reset(): void {
    this.userZoom = 1;
    this.panX = 0;
    this.panY = 0;
    this.updateGeometry();
  }

  screenToRemote(sx: number, sy: number): [number, number] | null {
    return mapScreenToRemote(
      sx,
      sy,
      this.originX,
      this.originY,
      this.renderedW,
      this.renderedH,
      this.remoteW,
      this.remoteH
    );
  }

  remoteToScreen(rx: number, ry: number): [number, number] {
    return mapRemoteToScreen(
      rx,
      ry,
      this.originX,
      this.originY,
      this.renderedW,
      this.renderedH,
      this.remoteW,
      this.remoteH,
      this.w,
      this.h
    );
  }

  clampRemoteX(rx: number): number {
    if (!Number.isFinite(rx) || this.remoteW <= 0) {
      return 0;
    }
    const max = Math.max(0, Math.floor(this.remoteW) - 1);
    if (rx < 0) {
      return 0;
    }
    if (rx > max) {
      return max;
    }
    return Math.round(rx);
  }

  clampRemoteY(ry: number): number {
    if (!Number.isFinite(ry) || this.remoteH <= 0) {
      return 0;
    }
    const max = Math.max(0, Math.floor(this.remoteH) - 1);
    if (ry < 0) {
      return 0;
    }
    if (ry > max) {
      return max;
    }
    return Math.round(ry);
  }
}

const TRACKPAD = new TrackpadLogic();
const VIEW = new ViewBox();

class DeskHold {
  pixelMap: image.PixelMap | null = null;
  mapW: number = 0;
  mapH: number = 0;
  paintCount: number = 0;
  bindGen: number = 0;
  pageAlive: boolean = false;
}

const DESK = new DeskHold();

class DebugBus {
  lines: string[] = [];
  seq: number = 0;
  paint: number = 0;
  decoded: number = 0;
  packets: number = 0;
  status: number = 0;
  width: number = 0;
  height: number = 0;
  verdict: string = '等待';
  lastNative: string = '';

  note(msg: string): void {
    const now = Date.now() % 100000;
    this.lines.push(`${now} ${msg}`);
    if (this.lines.length > 30) {
      this.lines.shift();
    }
    this.seq += 1;
    console.info('[HdHud] ' + msg);
  }

  text(): string {
    if (this.lines.length === 0) {
      return '(还没有事件)';
    }
    const start = this.lines.length > 16 ? this.lines.length - 16 : 0;
    return this.lines.slice(start).join('\n');
  }
}

const DEBUG = new DebugBus();

class VideoSurfaceBind {
  static boundId: string = '';

  static async bind(surfaceId: string): Promise<void> {
    try {
      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (!native) {
        return;
      }
      VideoSurfaceBind.boundId = surfaceId;
      const rc = native.bindVideoSurface(surfaceId);
      DEBUG.note(`bindVideoSurface rc=${rc}`);
    } catch (_e) {
      DEBUG.note('bindVideoSurface fail');
    }
  }

  static async unbind(): Promise<void> {
    try {
      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (native) {
        native.unbindVideoSurface();
      }
      VideoSurfaceBind.boundId = '';
    } catch (_e) {
    }
  }
}

class VideoXController extends XComponentController {
  onSurfaceCreated(surfaceId: string): void {
    DEBUG.note(`surface created ${surfaceId}`);
    VideoSurfaceBind.bind(surfaceId);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    DEBUG.note(`surface destroyed ${surfaceId}`);
    VideoSurfaceBind.unbind();
  }
}

@Component
struct CursorLayer {
  @State drawX: number = 0;
  @State drawY: number = 0;
  private timer: number = -1;

  aboutToAppear() {
    this.syncPos();
    this.timer = setInterval(() => {
      this.syncPos();
    }, 16);
  }

  aboutToDisappear() {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private syncPos(): void {
    const screen = VIEW.remoteToScreen(TRACKPAD.cursorX, TRACKPAD.cursorY);
    const nx = screen[0];
    const ny = screen[1];
    if (Math.abs(nx - this.drawX) > 0.5 || Math.abs(ny - this.drawY) > 0.5) {
      this.drawX = nx;
      this.drawY = ny;
    }
  }

  build() {
    Image($r('app.media.win_cursor'))
      .width(10)
      .height(16)
      .objectFit(ImageFit.Contain)
      .interpolation(ImageInterpolation.High)
      .position({ x: this.drawX, y: this.drawY })
      .hitTestBehavior(HitTestMode.None)
  }
}

@Component
struct DesktopPixels {
  @State pixelMap: image.PixelMap | null = null;
  private pullTimer: number = -1;
  private fetching: boolean = false;
  private fetchAt: number = 0;
  private mapW: number = 0;
  private mapH: number = 0;
  private nativeRef: HarmonyDeskNative | null = null;

  aboutToAppear() {
    DESK.pageAlive = true;
    DEBUG.note('pixels appear');
    if (DESK.pixelMap) {
      this.pixelMap = DESK.pixelMap;
      this.mapW = DESK.mapW;
      this.mapH = DESK.mapH;
    }
    this.pullTimer = setInterval(() => {
      this.pullFrame();
    }, 33);
  }

  aboutToDisappear() {
    DEBUG.note('pixels disappear');
    if (this.pullTimer !== -1) {
      clearInterval(this.pullTimer);
      this.pullTimer = -1;
    }
  }

  private async pullFrame(): Promise<void> {
    if (!DESK.pageAlive) {
      return;
    }
    if (this.fetching) {
      if (Date.now() - this.fetchAt < 400) {
        return;
      }
      this.fetching = false;
    }
    this.fetching = true;
    this.fetchAt = Date.now();
    try {
      if (!this.nativeRef) {
        const nativeMod = await import('../native/HarmonyDeskNative');
        this.nativeRef = await nativeMod.getNativeModule();
      }
      if (!this.nativeRef || !DESK.pageAlive) {
        return;
      }
      const frame = this.nativeRef.getVideoFrame();
      if (!frame || !frame.data || frame.width <= 0 || frame.height <= 0) {
        return;
      }
      if (this.pixelMap && this.mapW === frame.width && this.mapH === frame.height) {
        try {
          this.pixelMap.writeBufferToPixelsSync(frame.data);
          DESK.paintCount += 1;
          return;
        } catch (_writeError) {
          DEBUG.note(`pixel write fail ${frame.width}x${frame.height}`);
          this.pixelMap = null;
          this.mapW = 0;
          this.mapH = 0;
        }
      }
      const opts: image.InitializationOptions = {
        size: { width: frame.width, height: frame.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true,
        alphaType: image.AlphaType.OPAQUE
      };
      const next = await image.createPixelMap(frame.data, opts);
      if (!DESK.pageAlive) {
        next.release();
        return;
      }
      const old = this.pixelMap;
      this.pixelMap = next;
      this.mapW = frame.width;
      this.mapH = frame.height;
      DESK.pixelMap = next;
      DESK.mapW = frame.width;
      DESK.mapH = frame.height;
      if (VIEW.remoteW !== frame.width || VIEW.remoteH !== frame.height) {
        VIEW.updateGeometry(undefined, undefined, frame.width, frame.height);
      }
      DESK.paintCount += 1;
      DEBUG.note(`pixel create ${frame.width}x${frame.height}`);
      if (old && old !== next) {
        old.release();
      }
    } catch (_pullError) {
    } finally {
      this.fetching = false;
    }
  }

  build() {
    if (this.pixelMap) {
      Image(this.pixelMap)
        .objectFit(ImageFit.Fill)
        .width('100%')
        .height('100%')
        .interpolation(ImageInterpolation.Low)
        .hitTestBehavior(HitTestMode.None)
    }
  }
}

@Component
struct DesktopSurface {
  @State renderedW: number = 0;
  @State renderedH: number = 0;
  @State originX: number = 0;
  @State originY: number = 0;
  @State showPixelFallback: boolean = false;
  private syncTimer: number = -1;
  private fallbackTimer: number = -1;
  private xCtrl: VideoXController = new VideoXController();

  aboutToAppear() {
    DEBUG.note('surface layer appear');
    this.initViewportFromDisplay();
    this.syncGeometry();
    this.syncTimer = setInterval(() => {
      this.syncGeometry();
    }, 16);
    // If surface render never becomes active, fall back to PixelMap path.
    this.fallbackTimer = setInterval(() => {
      this.checkSurfaceFallback();
    }, 1000);
  }

  aboutToDisappear() {
    DEBUG.note('surface layer disappear');
    if (this.syncTimer !== -1) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    if (this.fallbackTimer !== -1) {
      clearInterval(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
  }

  private initViewportFromDisplay(): void {
    try {
      const disp = display.getDefaultDisplaySync();
      if (disp && disp.width > 0 && disp.height > 0 && disp.densityPixels > 0) {
        const dw = disp.width / disp.densityPixels;
        const dh = disp.height / disp.densityPixels;
        if (dw > 0 && dh > 0 && (VIEW.w <= 0 || VIEW.h <= 0)) {
          VIEW.updateGeometry(dw, dh);
        }
      }
    } catch (_e) {
    }
  }

  private updateParentViewport(w: number, h: number): void {
    if (w > 0 && h > 0) {
      VIEW.updateGeometry(w, h);
      this.syncGeometry();
    }
  }

  private async checkSurfaceFallback(): Promise<void> {
    try {
      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (!native) {
        return;
      }
      const stats = native.getVideoStats();
      if (stats.surface === 1) {
        if (this.showPixelFallback) {
          this.showPixelFallback = false;
          DEBUG.note('surface active, hide pixel fallback');
        }
        if (stats.width > 0 && stats.height > 0) {
          if (VIEW.remoteW !== stats.width || VIEW.remoteH !== stats.height) {
            VIEW.updateGeometry(undefined, undefined, stats.width, stats.height);
          }
        }
        DESK.paintCount = stats.decoded;
        return;
      }
      if (stats.packets > 5 && stats.decoded > 0 && !this.showPixelFallback) {
        this.showPixelFallback = true;
        DEBUG.note('surface inactive, pixel fallback on');
      }
    } catch (_e) {
    }
  }

  private syncGeometry(): void {
    if (Math.abs(this.renderedW - VIEW.renderedW) > 0.5 ||
        Math.abs(this.renderedH - VIEW.renderedH) > 0.5 ||
        Math.abs(this.originX - VIEW.originX) > 0.5 ||
        Math.abs(this.originY - VIEW.originY) > 0.5) {
      this.renderedW = VIEW.renderedW;
      this.renderedH = VIEW.renderedH;
      this.originX = VIEW.originX;
      this.originY = VIEW.originY;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        // RustDesk Texture analog: hardware decoder renders into this surface.
        XComponent({
          id: 'hd_video_surface',
          type: XComponentType.SURFACE,
          controller: this.xCtrl
        })
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
          .onLoad(() => {
            const sid = this.xCtrl.getXComponentSurfaceId();
            if (sid && sid.length > 0) {
              DEBUG.note(`surface onLoad ${sid}`);
              VideoSurfaceBind.bind(sid);
            }
          })

        if (this.showPixelFallback) {
          DesktopPixels()
        }
      }
      .width(this.renderedW > 0 ? this.renderedW : '100%')
      .height(this.renderedH > 0 ? this.renderedH : '100%')
      .position({ x: this.originX, y: this.originY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_old: Area, area: Area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      if (w > 0 && h > 0) {
        this.updateParentViewport(w, h);
      }
    })
  }
}

// Serialize the shared IME controller across quick open/close/open transitions.
let remoteImeQueue: Promise<void> = Promise.resolve();

@Component
struct TypeBar {
  onSend: (text: string) => void = (_text: string) => {};
  onControl: (code: number) => void = (_code: number) => {};
  onClose: () => void = () => {};
  private controller: inputMethod.InputMethodController = inputMethod.getController();
  private active: boolean = false;
  private attached: boolean = false;
  private keyboardShown: boolean = false;
  private keyboardStatus: (status: inputMethod.KeyboardStatus) => void = (status: inputMethod.KeyboardStatus) => {
    if (status === inputMethod.KeyboardStatus.SHOW) { this.keyboardShown = true; }
    if (status === inputMethod.KeyboardStatus.HIDE && this.active && this.keyboardShown) {
      this.onClose();
    }
  };
  private insert: (text: string) => void = (text: string) => {
    if (this.active) {
      this.onSend(text);
      console.info(`[SessionUI] IME commit length=${text.length}`);
    }
  };
  private deleteLeft: (length: number) => void = (length: number) => {
    if (this.active) {
      for (let i = 0; i < length; i++) { this.onControl(2); }
      console.info(`[SessionUI] IME backspace count=${length}`);
    }
  };
  private deleteRight: (length: number) => void = (length: number) => {
    if (this.active) {
      for (let i = 0; i < length; i++) { this.onControl(5); }
      console.info(`[SessionUI] IME delete count=${length}`);
    }
  };
  private enter: (key: inputMethod.FunctionKey) => void = (_key: inputMethod.FunctionKey) => {
    if (this.active) { this.onControl(27); }
  };
  private leftText: (length: number) => string = (_length: number) => '';
  private rightText: (length: number) => string = (_length: number) => '';
  private cursorIndex: () => number = () => 0;

  aboutToAppear() {
    this.active = true;
    remoteImeQueue = remoteImeQueue.catch(() => {}).then(async () => {
      if (!this.active) { return; }
      try {
        const win = await window.getLastWindow(getContext(this));
        await this.controller.attach(false, {
          inputAttribute: { textInputType: inputMethod.TextInputType.TEXT,
            enterKeyType: inputMethod.EnterKeyType.NEWLINE },
          windowId: win.getWindowProperties().id
        });
        this.attached = true;
        if (!this.active) { return; }
      this.controller.on('sendKeyboardStatus', this.keyboardStatus);
      this.controller.on('insertText', this.insert);
      this.controller.on('deleteLeft', this.deleteLeft);
      this.controller.on('deleteRight', this.deleteRight);
      this.controller.on('sendFunctionKey', this.enter);
      this.controller.on('getLeftTextOfCursor', this.leftText);
      this.controller.on('getRightTextOfCursor', this.rightText);
      this.controller.on('getTextIndexAtCursor', this.cursorIndex);
        await this.controller.showTextInput();
        console.info('[SessionUI] direct IME attached');
      } catch (_error) {
        console.error('[SessionUI] direct IME attach failed');
        if (this.active) { this.onClose(); }
      }
    });
  }

  aboutToDisappear() {
    this.active = false;
    remoteImeQueue = remoteImeQueue.catch(() => {}).then(async () => {
      this.controller.off('sendKeyboardStatus', this.keyboardStatus);
      this.controller.off('insertText', this.insert);
      this.controller.off('deleteLeft', this.deleteLeft);
      this.controller.off('deleteRight', this.deleteRight);
      this.controller.off('sendFunctionKey', this.enter);
      this.controller.off('getLeftTextOfCursor', this.leftText);
      this.controller.off('getRightTextOfCursor', this.rightText);
      this.controller.off('getTextIndexAtCursor', this.cursorIndex);
      if (this.attached) {
        try { await this.controller.detach(); } catch (_error) {}
        this.attached = false;
      }
    });
  }

  build() {
    Row({ space: 8 }) {
      Text('直接输入远端').fontSize(12).fontColor(Color.White).layoutWeight(1)
      Button('Tab').focusOnTouch(false).onClick(() => this.onControl(31))
      Button('退格').focusOnTouch(false).onClick(() => this.onControl(2))
      Button('回车').focusOnTouch(false).onClick(() => this.onControl(27))
      Button('收键盘').focusOnTouch(false).onClick(() => this.onClose())
    }
    .padding(10).width('100%').backgroundColor('rgba(22,22,26,0.94)')
    .hitTestBehavior(HitTestMode.Default)
  }
}

// Angles wrap at +/- PI; accumulated fractional motion avoids jitter and lost steps.
class CircularScroll {
  private angle: number = 0;
  private carry: number = 0;
  private anchored: boolean = false;
  reset(): void { this.anchored = false; this.carry = 0; }
  move(x: number, y: number): number {
    if (x * x + y * y < 100) { this.anchored = false; return 0; }
    const angle = Math.atan2(y, x);
    if (!this.anchored) { this.angle = angle; this.anchored = true; return 0; }
    let delta = angle - this.angle;
    this.angle = angle;
    if (delta > Math.PI) { delta -= 2 * Math.PI; }
    if (delta < -Math.PI) { delta += 2 * Math.PI; }
    this.carry += delta / (Math.PI / 12);
    const steps = Math.trunc(this.carry);
    this.carry -= steps;
    return -steps;
  }
}

@Component
struct FloatingMouse {
  onMove: (dx: number, dy: number) => void = (_dx: number, _dy: number) => {};
  onButton: (button: number, down: boolean) => void = (_button: number, _down: boolean) => {};
  onScroll: (delta: number) => void = (_delta: number) => {};
  onRelease: () => void = () => {};
  @Prop @Watch('constrain') viewportW: number = 0;
  @Prop @Watch('constrain') viewportH: number = 0;
  @Prop @Watch('constrain') keyboardInset: number = 0;
  @State x: number = 100;
  @State y: number = 200;
  @State minimized: boolean = false;
  @State held: number = 0;
  private lastX: number = 0;
  private lastY: number = 0;
  private moved: number = 0;
  private lastTap: number = 0;
  private centerId: number = -1;
  private leftDragId: number = -1;
  private leftLastX: number = 0;
  private leftLastY: number = 0;
  @State ringHeld: boolean = false;
  @State ringAngle: number = Math.PI / 2;
  private ringId: number = -1;
  private ringCenterX: number = 0;
  private ringCenterY: number = 0;
  private followTimer: number = -1;
  private scroll: CircularScroll = new CircularScroll();

  aboutToAppear() {
    this.constrain();
    this.followTimer = setInterval(() => this.constrain(), 16);
  }
  aboutToDisappear() {
    if (this.followTimer !== -1) { clearInterval(this.followTimer); this.followTimer = -1; }
    this.onRelease();
  }
  private constrain(): void {
    if (this.ringId !== -1) { return; }
    // Keep the cursor exposed above and to the left of the left button,
    // matching the reference layout. Near the right edge, put the controls
    // on the other side of the cursor instead of clamping them over its tip.
    const target = VIEW.remoteToScreen(TRACKPAD.cursorX, TRACKPAD.cursorY);
    this.x = target[0] - (this.minimized ? 24 : 8);
    this.y = target[1] - (this.minimized ? -20 : 112);
    if (!this.minimized && this.x + 176 > this.viewportW - 8) {
      this.x = target[0] - 168;
    }
    this.x = Math.max(8, Math.min(this.x, this.viewportW - (this.minimized ? 48 : 176) - 8));
    this.y = Math.max(8, Math.min(this.y, this.viewportH - this.keyboardInset - (this.minimized ? 48 : 248) - 8));
  }
  private ringTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Cancel) {
      this.ringId = -1; this.ringHeld = false; this.scroll.reset();
      console.info('[SessionUI] ring cancel');
      return;
    }
    for (let i = 0; i < event.changedTouches.length; i++) {
      const touch = event.changedTouches[i];
      if (event.type === TouchType.Down && this.ringId === -1) {
        this.ringId = touch.id;
        this.ringHeld = true;
        // Lock the window-space center for this finger, including when the
        // gesture starts on the lower solid knob instead of the dotted ring.
        this.ringCenterX = touch.windowX - touch.x + 46;
        this.ringCenterY = touch.windowY - touch.y + 46;
        this.scroll.reset();
        console.info('[SessionUI] ring down');
      }
      if (touch.id !== this.ringId) { continue; }
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        const dx = touch.windowX - this.ringCenterX;
        const dy = touch.windowY - this.ringCenterY;
        this.ringAngle = Math.atan2(dy, dx);
        const delta = this.scroll.move(dx, dy);
        if (delta !== 0) {
          this.onScroll(delta);
          console.info(`[SessionUI] ring wheel=${delta}`);
        }
      } else if (event.type === TouchType.Up) {
        this.ringId = -1; this.ringHeld = false; this.scroll.reset();
        console.info('[SessionUI] ring up');
      }
    }
  }

  private buttonTouch(event: TouchEvent, button: number): void {
    event.stopPropagation();
    if (button === 0) {
      // Left button also drags the remote pointer while the same finger stays down,
      // enabling drag-select on the remote desktop.
      this.leftButtonTouch(event);
      return;
    }
    const mask = 1 << button;
    if (event.type === TouchType.Down && (this.held & mask) === 0) {
      this.held |= mask;
      this.onButton(button, true);
    } else if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && (this.held & mask) !== 0) {
      this.held &= ~mask;
      this.onButton(button, false);
    }
  }

  private leftButtonTouch(event: TouchEvent): void {
    const mask = 1;
    if (event.type === TouchType.Down) {
      if ((this.held & mask) !== 0) {
        // Already pressed by another finger; ignore extra Down to avoid duplicate down events.
        return;
      }
      const touch = event.changedTouches[0];
      if (!touch) {
        return;
      }
      this.leftDragId = touch.id;
      this.leftLastX = touch.windowX;
      this.leftLastY = touch.windowY;
      this.held |= mask;
      this.onButton(0, true);
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.leftDragId === -1) {
        return;
      }
      for (let i = 0; i < event.changedTouches.length; i++) {
        const touch = event.changedTouches[i];
        if (touch.id !== this.leftDragId) {
          continue;
        }
        const dx = touch.windowX - this.leftLastX;
        const dy = touch.windowY - this.leftLastY;
        this.leftLastX = touch.windowX;
        this.leftLastY = touch.windowY;
        this.onMove(dx, dy);
        return;
      }
      return;
    }
    if (event.type === TouchType.Cancel) {
      if ((this.held & mask) !== 0) {
        this.held &= ~mask;
        this.onButton(0, false);
      }
      this.leftDragId = -1;
      return;
    }
    if (event.type === TouchType.Up) {
      if (this.leftDragId !== -1) {
        const matched = event.changedTouches.find((t: TouchObject) => t.id === this.leftDragId) !== undefined;
        if (!matched) {
          return;
        }
      }
      if ((this.held & mask) !== 0) {
        this.held &= ~mask;
        this.onButton(0, false);
      }
      this.leftDragId = -1;
      return;
    }
  }
  private centerTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Cancel) { this.centerId = -1; this.lastTap = 0; return; }
    const touch = event.changedTouches[0];
    if (!touch) { return; }
    if (event.type === TouchType.Down && this.centerId === -1) {
      this.centerId = touch.id; this.lastX = touch.windowX; this.lastY = touch.windowY; this.moved = 0;
    } else if (touch.id === this.centerId && event.type === TouchType.Move) {
      const dx = touch.windowX - this.lastX;
      const dy = touch.windowY - this.lastY;
      this.lastX = touch.windowX; this.lastY = touch.windowY;
      this.moved += Math.abs(dx) + Math.abs(dy);
      this.onMove(dx, dy);
      this.constrain();
    } else if (touch.id === this.centerId && event.type === TouchType.Up) {
      this.centerId = -1;
      if (this.moved < 8) {
        const now = Date.now();
        if (now - this.lastTap < 350) {
          this.onRelease(); this.held = 0; this.minimized = true; this.constrain();
          console.info('[SessionUI] floating mouse minimized');
          this.lastTap = 0;
        } else { this.lastTap = now; }
      } else { this.lastTap = 0; }
    }
  }

  private mousePath(commands: string): string {
    // Path command coordinates are physical pixels; the surrounding layout uses vp.
    return commands.replace(/-?\d+(?:\.\d+)?/g, (value: string) => String(vp2px(Number(value))));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.minimized) {
        Button('鼠标').focusOnTouch(false).width(48).height(48).fontSize(12)
          .focusOnTouch(false)
          .onClick(() => { this.minimized = false; this.constrain(); })
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          Circle().width(88).height(88).fill(Color.Transparent)
            .stroke(this.ringHeld ? '#E6AC73' : '#8D9297').strokeWidth(1.5)
            .strokeDashArray([1.5, 5]).position({ x: 2, y: 2 })
            .hitTestBehavior(HitTestMode.None)
          Circle().width(20).height(20).fill(this.ringHeld ? '#F0B67F' : '#D3D5D6')
            .stroke('#767C80').strokeWidth(2)
            .shadow({ radius: this.ringHeld ? 10 : 2, color: this.ringHeld ? '#BFE6A56B' : '#40000000' })
            .position({
              x: this.ringHeld ? 36 + 42 * Math.cos(this.ringAngle) : 36,
              y: this.ringHeld ? 36 + 42 * Math.sin(this.ringAngle) : 98
            }).hitTestBehavior(HitTestMode.None)
        }
        .width(92).height(120).position({ x: 42, y: 0 })
        .id('floatingMouseScroll').hitTestBehavior(HitTestMode.Default)
        .onTouch((event: TouchEvent) => this.ringTouch(event))
        Stack() {
          Path().width(36).height(78)
            .commands(this.mousePath('M29 3 C23 -1 18 2 14 8 C-2 27 -2 51 14 70 C18 77 24 80 30 75 C35 71 35 66 31 61 C21 46 21 32 31 17 C35 12 35 7 29 3 Z'))
            .fill((this.held & 1) !== 0 ? '#F0B67F' : '#D3D5D6')
            .stroke('#767C80').strokeWidth(2).hitTestBehavior(HitTestMode.None)
        }
          .width(36).height(78).position({ x: 22, y: 126 }).id('floatingMouseLeft')
          .accessibilityText('鼠标左键').hitTestBehavior(HitTestMode.Default)
          .onTouch((event: TouchEvent) => this.buttonTouch(event, 0))
        Stack() {
          Path().width(36).height(78)
            .commands(this.mousePath('M7 3 C13 -1 18 2 22 8 C38 27 38 51 22 70 C18 77 12 80 6 75 C1 71 1 66 5 61 C15 46 15 32 5 17 C1 12 1 7 7 3 Z'))
            .fill((this.held & 4) !== 0 ? '#F0B67F' : '#D3D5D6')
            .stroke('#767C80').strokeWidth(2).hitTestBehavior(HitTestMode.None)
        }
          .width(36).height(78).position({ x: 118, y: 126 }).id('floatingMouseRight')
          .accessibilityText('鼠标右键').hitTestBehavior(HitTestMode.Default)
          .onTouch((event: TouchEvent) => this.buttonTouch(event, 2))
        Circle().width(52).height(52).fill('#D3D5D6')
          .stroke('#767C80').strokeWidth(3)
          .shadow({ radius: 2, color: '#50000000' }).position({ x: 62, y: 139 })
          .accessibilityText('拖动移动光标，双击收起')
          .id('floatingMouseMove').onTouch((event: TouchEvent) => this.centerTouch(event))
        Stack() {
          Circle().width(24).height(24)
            .fill((this.held & 2) !== 0 ? '#F0B67F' : '#D3D5D6')
            .stroke('#767C80').strokeWidth(1.5).hitTestBehavior(HitTestMode.None)
          Path().width(24).height(24)
            .commands(this.mousePath('M8 5 L16 5 M6 8 L18 8 M5 11 L19 11 M5 14 L19 14 M6 17 L18 17 M8 20 L16 20'))
            .stroke('#858A8E').strokeWidth(1).fill(Color.Transparent).hitTestBehavior(HitTestMode.None)
        }
          .width(32).height(32).position({ x: 72, y: 210 }).id('floatingMouseMiddle')
          .accessibilityText('鼠标中键').hitTestBehavior(HitTestMode.Default)
          .onTouch((event: TouchEvent) => this.buttonTouch(event, 1))
      }
    }
    .width(this.minimized ? 48 : 176).height(this.minimized ? 48 : 248)
    .position({ x: this.x, y: this.y }).hitTestBehavior(HitTestMode.Default)
    .onTouch((event: TouchEvent) => event.stopPropagation())
  }
}

function mouseTrace(msg: string): void {
  if (msg.startsWith('pan-move') || msg.startsWith('touch type=2')) {
    return;
  }
  console.info('[MOUSE_TRACE] ' + msg);
}

@Component
struct HoldRightBtn {
  onDown: () => void = () => {};
  onUp: () => void = () => {};

  build() {
    Button('右键')
      .focusOnTouch(false)
      .layoutWeight(1)
      .height(42)
      .fontSize(12)
      .padding({ left: 2, right: 2 })
      .fontColor(Color.White)
      .backgroundColor('rgba(255, 255, 255, 0.18)')
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (event.type === TouchType.Down) {
          this.onDown();
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onUp();
        }
      })
  }
}

@Component
struct HoldLeftBtn {
  @State held: boolean = false;
  onDown: () => void = () => {};
  onUp: () => void = () => {};

  build() {
    Button(this.held ? '左键按' : '左键')
      .focusOnTouch(false)
      .layoutWeight(1)
      .height(42)
      .fontSize(12)
      .padding({ left: 2, right: 2 })
      .fontColor(Color.White)
      .backgroundColor(this.held ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
        if (event.type === TouchType.Down) {
          this.held = true;
          this.onDown();
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.held = false;
          this.onUp();
        }
      })
  }
}

@Entry
@Component
struct Session {
  @State viewOnly: boolean = false;
  @State chromeVisible: boolean = true;
  @State displayMode: DisplayMode = DisplayMode.FIT;
  @State deskId: string = '';
  @State password: string = '';
  @State isConnected: boolean = false;
  @State keepDesktop: boolean = false;
  @State connectionStatus: string = '未连接';
  @State connectionStep: string = '';
  @State connectionLogs: string[] = [];
  @State errorMessage: string = '';
  @State reconnectHint: string = '';
  @State frameRate: number = 30;
  @State demoHint: string = '演示画面 · 非真实远程桌面';
  @State deviceName: string = '';
  @State showKeyboard: boolean = false;
  @State remoteW: number = 1920;
  @State remoteH: number = 1080;
  @State viewScale: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State virtualMouse: boolean = false;
  @State leftHeld: boolean = false;
  @State actionHint: string = '';
  @State textSelectMode: boolean = false;
  @State wheelX: number = 300;
  @State wheelY: number = 120;
  @State wheelDragging: boolean = false;

  private autoHideTimer: number = -1;
  private videoTimer: number = -1;
  private logTimer: number = -1;
  private lastHint: string = '';
  @State screenWidth: number = 0;
  @State screenHeight: number = 0;
  private wheelW: number = 44;
  private wheelH: number = 100;
  private wheelOffsetX: number = 0;
  private wheelOffsetY: number = 0;
  private wheelMoved: boolean = false;
  private wheelInited: boolean = false;
  private fetchingFrame: boolean = false;
  private pixelMapW: number = 0;
  private pixelMapH: number = 0;
  private skipVideoUntil: number = 0;
  private rightDown: boolean = false;
  private firstFrameLogged: boolean = false;
  private firstTouchLogged: boolean = false;
  private nativeRef: HarmonyDeskNative | null = null;
  private videoViewW: number = 0;
  private videoViewH: number = 0;
  private touchDragging: boolean = false;
  private touchMoved: boolean = false;
  private rightClicked: boolean = false;
  private longPressTimer: number = -1;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private cursorX: number = 0;
  private cursorY: number = 0;
  private connectSeq: number = 0;
  private intentionalDisconnect: boolean = false;
  private everLoggedIn: boolean = false;
  private reconnectAttempt: number = 0;
  private reconnectInFlight: boolean = false;
  private backgroundReleaseInFlight: Promise<void> = Promise.resolve();
  private readonly maxReconnectAttempts: number = 5;
  private clipboard: ClipboardSync = new ClipboardSync();
  @State clipboardSync: boolean = true;
  @State clipboardStatus: string = '剪贴板同步准备中';
  @State bottomControlsHeight: number = 72;
  private previousKeyboardAvoidMode: UIKeyboardAvoidMode = UIKeyboardAvoidMode.OFFSET;
  private pinchStartScale: number = 1;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinching: boolean = false;
  private lastFingerX: number = 0;
  private lastFingerY: number = 0;
  private vmNeedAnchor: boolean = true;
  @State keyboardInset: number = 0;
  private sessionWindow: window.Window | null = null;
  private floatingButtons: number = 0;
  private keyboardHeight: (height: number) => void = (height: number) => {
    this.keyboardInset = px2vp(height);
    this.constrainWheelPosition();
  };

  private releaseFloatingButtons(): void {
    for (let button = 0; button < 3; button++) {
      if ((this.floatingButtons & (1 << button)) !== 0) {
        this.nativeRef?.sendMouseClick(button, false);
      }
    }
    this.floatingButtons = 0;
    this.leftHeld = false;
    TRACKPAD.freezeMove = false;
  }

  private floatingButton(button: number, down: boolean): void {
    if (!this.isConnected || this.viewOnly || !this.nativeRef) { return; }
    const mask = 1 << button;
    if (((this.floatingButtons & mask) !== 0) === down) { return; }
    this.clampCursor();
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
    this.nativeRef.sendMouseClick(button, down);
    this.floatingButtons = down ? this.floatingButtons | mask : this.floatingButtons & ~mask;
    this.leftHeld = (this.floatingButtons & 1) !== 0;
    // Allow single-finger drag-select while only left is held: freeze only when a non-left button is down.
    TRACKPAD.freezeMove = (this.floatingButtons & ~1) !== 0;
    console.info(`[SessionUI] floating button=${button} down=${down}`);
  }

  private moveFloatingPointer(dx: number, dy: number): void {
    if (!this.isConnected || this.viewOnly || !this.nativeRef) { return; }
    // Floating controls move in displayed desktop pixels, not full viewport
    // pixels (which include FIT letterboxing). Keep a 1:1 on-screen movement.
    if (VIEW.renderedW <= 0 || VIEW.renderedH <= 0) { return; }
    this.cursorX += dx * this.remoteW / VIEW.renderedW;
    this.cursorY += dy * this.remoteH / VIEW.renderedH;
    this.clampCursor();
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
  }

  private resetAutoHideTimer(): void {
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }
    if (!this.isConnected || this.textSelectMode) {
      return;
    }
    this.autoHideTimer = setTimeout(() => {
      if (this.isConnected && !this.textSelectMode) {
        this.chromeVisible = false;
      }
    }, 7000);
  }

  private showChromeWithTimer(): void {
    this.chromeVisible = true;
    this.resetAutoHideTimer();
  }

  private clearAutoHideTimer(): void {
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }
  }

  private toggleKeyboard(): void {
    if (this.viewOnly) { return; }
    this.showKeyboard = !this.showKeyboard;
    this.resetAutoHideTimer();
  }

  async aboutToAppear() {
    console.info('[Session] aboutToAppear called');
    this.previousKeyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.NONE);
    try {
      this.sessionWindow = await window.getLastWindow(getContext(this));
      this.sessionWindow.on('keyboardHeightChange', this.keyboardHeight);
    } catch (_error) { console.error('[SessionUI] keyboard height listener unavailable'); }

    // 获取路由参数 - 尝试多种方式
    let params: Record<string, Object> | null = null;

    try {
      params = router.getParams() as Record<string, Object> | null;
      console.info('[Session] router.getParams() id:', params ? String(params.id || '') : 'null');
    } catch (error) {
      console.error('[Session] router.getParams() error:', error);
    }

    // 如果 getParams 返回 null，尝试延迟获取
    if (!params) {
      console.warn('[Session] Params is null, waiting 100ms and retry...');
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 100);
      });
      try {
        params = router.getParams() as Record<string, Object> | null;
        console.info('[Session] Retry getParams() id:', params ? String(params.id || '') : 'null');
      } catch (error) {
        console.error('[Session] Retry getParams() error:', error);
      }
    }

    if (params) {
      // 安全地获取参数值
      this.deskId = String(params.id || params['id'] || '').trim();
      this.password = String(params.password || params['password'] || '').trim();
      this.deviceName = String(params.name || params['name'] || '').trim();
      this.viewOnly = String(params.viewOnly || params['viewOnly'] || '0') === '1' || params.viewOnly === true;

      console.info('[Session] Parsed params - deskId:', this.deskId, 'password:', this.password ? '***' : '(empty)', 'name:', this.deviceName);
    } else {
      console.warn('[Session] No params received from router');
      this.errorMessage = '缺少设备 ID 参数';
      this.connectionStatus = '参数错误';
    }

    try {
      const disp = display.getDefaultDisplaySync();
      if (disp && disp.width > 0 && disp.height > 0 && disp.densityPixels > 0) {
        const dw = disp.width / disp.densityPixels;
        const dh = disp.height / disp.densityPixels;
        if (dw > 0 && dh > 0) {
          this.screenWidth = dw;
          this.screenHeight = dh;
          this.videoViewW = dw;
          this.videoViewH = dh;
        }
      }
    } catch (_e) {
    }

    let isTablet = false;
    try {
      const dType = deviceInfo.deviceType;
      if (dType === 'tablet' || dType === '2in1') {
        isTablet = true;
      }
    } catch (_e) {
    }
    if (!isTablet && (Math.min(this.screenWidth, this.screenHeight) >= 600 || Math.max(this.screenWidth, this.screenHeight) >= 960)) {
      isTablet = true;
    }
    this.virtualMouse = !isTablet;
    DEBUG.note(`deviceType=${deviceInfo.deviceType || 'unknown'} tablet=${isTablet} vmDefault=${this.virtualMouse}`);

    runGeometrySanityChecks();

    VIEW.reset();
    this.syncView();

    if (this.deskId && this.deskId.trim().length > 0) {
      const isDemo = this.deskId.startsWith('DEMO') || this.deskId.startsWith('TEST');
      if (isDemo || this.password.length > 0) {
        console.info('[Session] Starting connection to:', this.deskId);
        await new Promise<void>((resolve) => {
          setTimeout(() => resolve(), 200);
        });
        this.connect();
      } else {
        this.connectionStatus = '等待密码';
        this.connectionStep = '请填写远程密码';
        this.errorMessage = '对方要求密码。请填写后点连接。';
      }
    } else {
      console.warn('[Session] No deskId provided, cannot connect. Current deskId:', this.deskId);
      this.errorMessage = '设备 ID 为空，无法连接';
      this.connectionStatus = '参数错误';
    }

    console.info('[Session] aboutToAppear completed');
  }

  async aboutToDisappear() {
    this.clipboard.stop();
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardAvoidMode);
    this.sessionWindow?.off('keyboardHeightChange', this.keyboardHeight);
    this.releaseFloatingButtons();
    this.intentionalDisconnect = true;
    this.reconnectInFlight = false;
    this.connectSeq++;
    DESK.pageAlive = false;
    this.clearAutoHideTimer();
    SessionKeepAlive.setActive(false);
    if (DESK.pixelMap) {
      DESK.pixelMap.release();
      DESK.pixelMap = null;
    }
    DESK.mapW = 0;
    DESK.mapH = 0;
    if (this.videoTimer !== -1) {
      clearInterval(this.videoTimer);
      this.videoTimer = -1;
    }
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
    await this.disconnect();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1. 全屏远程画面（主视口）及手势层：作为 Session 的最底层，铺满整个屏幕
      Stack({ alignContent: Alignment.TopStart }) {
        DesktopSurface()
        if (this.virtualMouse && this.isConnected) {
          CursorLayer()
        }
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .backgroundColor('#000000')
      .onAreaChange((_old: Area, area: Area) => {
        const w = Number(area.width);
        const h = Number(area.height);
        if (w > 0 && h > 0) {
          this.videoViewW = w;
          this.videoViewH = h;
          this.syncView();
        }
      })
      .onTouch((event: TouchEvent) => {
        const point = event.changedTouches.length > 0 ? event.changedTouches[0] :
          (event.touches.length > 0 ? event.touches[0] : null);
        const px = point !== null ? point.x : -1;
        const py = point !== null ? point.y : -1;
        const wx = point !== null ? point.windowX : -1;
        const wy = point !== null ? point.windowY : -1;
        mouseTrace(`touch type=${event.type} vm=${this.virtualMouse ? 1 : 0} x=${px},${py} win=${wx},${wy} cur=${this.cursorX},${this.cursorY}`);
        // 选字模式：手指直接拖选（绝对坐标），避免触摸板拖选太难
        if (this.textSelectMode) {
          this.handleRemoteTouch(event);
          return;
        }
        if (this.virtualMouse) {
          this.handleTrackpadPress(event, px, py);
          return;
        }
        this.handleRemoteTouch(event);
      })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.pinchStartScale = VIEW.userZoom;
              this.pinching = true;
              this.touchMoved = true;
              this.clearRightClickTimer();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.setViewScale(this.pinchStartScale * event.scale);
            })
            .onActionEnd(() => {
              this.pinching = false;
            }),
          PanGesture({ fingers: 2, direction: PanDirection.All })
            .onActionStart(() => {
              this.panStartX = VIEW.panX;
              this.panStartY = VIEW.panY;
              this.pinching = true;
            })
            .onActionUpdate((event: GestureEvent) => {
              VIEW.panX = this.panStartX + event.offsetX;
              VIEW.panY = this.panStartY + event.offsetY;
              this.constrainPan();
            })
            .onActionEnd(() => {
              this.pinching = false;
            }),
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 10 })
            .onActionStart((event: GestureEvent) => {
              this.beginTrackpadGesture(event);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.moveTrackpadGesture(event.offsetX, event.offsetY);
            })
            .onActionEnd((event: GestureEvent) => {
              mouseTrace(`pan-end vm=${this.virtualMouse ? 1 : 0} off=${event.offsetX},${event.offsetY} cur=${TRACKPAD.cursorX},${TRACKPAD.cursorY}`);
            })
        )
      )
      .hitTestBehavior(HitTestMode.Default)

      // 2. 选字快捷浮动条（悬浮居中，独立透明层）
      if (this.isConnected && this.textSelectMode && !this.viewOnly) {
        Stack({ alignContent: Alignment.Bottom }) {
          Row({ space: 8 }) {
            Button('全选')
              .focusOnTouch(false)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('rgba(255, 255, 255, 0.20)')
              .onClick(() => {
                this.sendCtrlLetter('a');
              })
            Button('复制')
              .focusOnTouch(false)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('rgba(255, 255, 255, 0.20)')
              .onClick(() => {
                this.sendCtrlLetter('c');
              })
            Button('粘贴')
              .focusOnTouch(false)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('rgba(255, 255, 255, 0.20)')
              .onClick(() => {
                this.sendCtrlLetter('v');
              })
            Button('剪切')
              .focusOnTouch(false)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('rgba(255, 255, 255, 0.20)')
              .onClick(() => {
                this.sendCtrlLetter('x');
              })
            Button('完成')
              .focusOnTouch(false)
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor('#1E88E5')
              .onClick(() => {
                this.toggleTextSelectMode();
              })
          }
          .constraintSize({ maxWidth: 440 })
          .width('92%')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(20)
          .backgroundColor('rgba(20, 20, 24, 0.90)')
          .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.35)' })
          .margin({ bottom: this.keyboardInset + this.bottomControlsHeight + 8 })
          .hitTestBehavior(HitTestMode.Default)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.isConnected && this.virtualMouse && !this.viewOnly) {
        FloatingMouse({
          viewportW: this.screenWidth, viewportH: this.screenHeight, keyboardInset: this.keyboardInset + this.bottomControlsHeight,
          onMove: (dx: number, dy: number) => this.moveFloatingPointer(dx, dy),
          onButton: (button: number, down: boolean) => this.floatingButton(button, down),
          onScroll: (delta: number) => this.sendScroll(delta),
          onRelease: () => this.releaseFloatingButtons()
        })
      }

      // 3. 底部悬浮控制条与软键盘输入条（大屏居中悬浮、支持安全收起/展开）
      if (this.isConnected) {
        Column() {
            // 软键盘输入条
            if (this.showKeyboard) {
              TypeBar({
                onSend: (text: string) => {
                  DEBUG.note(`send text ${text.length}`);
                  if (!this.viewOnly && this.isConnected) { this.nativeRef?.sendText(text); }
                },
                onControl: (code: number) => {
                  if (!this.viewOnly && this.isConnected) { this.nativeRef?.sendControlKey(code, true); }
                },
                onClose: () => {
                  this.showKeyboard = false;
                  this.resetAutoHideTimer();
                }
              })
                .constraintSize({ maxWidth: 680 })
                .width('94%')
                .margin({ bottom: 8 })
                .borderRadius(14)
                .clip(true)
                .hitTestBehavior(HitTestMode.Default)
            }

            // 展开状态的底部控制条
            if (this.chromeVisible) {
              if (this.virtualMouse) {
                Row({ space: 6 }) {
                  Button('切触控')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] touch click');
                      this.releaseFloatingButtons();
                      this.virtualMouse = false;
                      this.resetAutoHideTimer();
                      DEBUG.note('切为直接触控模式');
                    })
                  Button('键盘')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.showKeyboard ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] keyboard click');
                      this.toggleKeyboard();
                    })
                  Button(this.textSelectMode ? '选字中' : '选字')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.textSelectMode ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      this.toggleTextSelectMode();
                    })
                  Button(this.displayModeLabel)
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.displayMode === DisplayMode.FIT ? 'rgba(255, 255, 255, 0.18)' : '#1E88E5')
                    .onClick(() => {
                      this.cycleDisplayMode();
                      this.resetAutoHideTimer();
                    })
                  Button('断开')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('rgba(229, 57, 53, 0.85)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] disconnect click');
                      this.disconnect();
                      router.back();
                    })
                  Button('收起')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] collapse click');
                      this.chromeVisible = false;
                      this.clearAutoHideTimer();
                    })
                }
                .constraintSize({ maxWidth: 660 })
                .width('94%')
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(18)
                .backgroundColor('rgba(20, 20, 24, 0.82)')
                .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.35)' })
                .hitTestBehavior(HitTestMode.Default)
              } else {
                Row({ space: 6 }) {
                  Button('切鼠标')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('#1E88E5')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] mouse click');
                      this.virtualMouse = true;
                      this.vmNeedAnchor = true;
                      this.clampCursor();
                      this.resetAutoHideTimer();
                      DEBUG.note('切为虚拟鼠标模式');
                    })
                  Button('键盘')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.showKeyboard ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] keyboard click');
                      this.toggleKeyboard();
                    })
                  Button(this.textSelectMode ? '选字中' : '选字')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.textSelectMode ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      this.toggleTextSelectMode();
                    })
                  Button(this.displayModeLabel)
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor(this.displayMode === DisplayMode.FIT ? 'rgba(255, 255, 255, 0.18)' : '#1E88E5')
                    .onClick(() => {
                      this.cycleDisplayMode();
                      this.resetAutoHideTimer();
                    })
                  Button('断开')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('rgba(229, 57, 53, 0.85)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] disconnect click');
                      this.disconnect();
                      router.back();
                    })
                  Button('收起')
                    .focusOnTouch(false)
                    .layoutWeight(1)
                    .height(42)
                    .fontSize(12)
                    .padding({ left: 2, right: 2 })
                    .fontColor(Color.White)
                    .backgroundColor('rgba(255, 255, 255, 0.18)')
                    .onClick(() => {
                      DEBUG.note('[SessionUI] collapse click');
                      this.chromeVisible = false;
                      this.clearAutoHideTimer();
                    })
                }
                .constraintSize({ maxWidth: 540 })
                .width('94%')
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(18)
                .backgroundColor('rgba(20, 20, 24, 0.82)')
                .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.35)' })
                .hitTestBehavior(HitTestMode.Default)
              }
            }

            // 收起状态的极简浮动恢复胶囊
            if (!this.chromeVisible) {
              Row({ space: 8 }) {
                Circle({ width: 7, height: 7 })
                  .fill('#4CAF50')
                Text(this.deviceName || this.deskId)
                  .fontSize(12)
                  .fontColor(Color.White)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 140 })
                Text(this.virtualMouse ? '已连·鼠标' : '已连·触控')
                  .fontSize(11)
                  .fontColor('rgba(255, 255, 255, 0.70)')
                Button('展开')
                  .focusOnTouch(false)
                  .type(ButtonType.Capsule)
                  .height(32)
                  .fontSize(12)
                  .padding({ left: 12, right: 12 })
                  .fontColor(Color.White)
                  .backgroundColor('#1E88E5')
                  .onClick(() => {
                    DEBUG.note('[SessionUI] expand click');
                    this.showChromeWithTimer();
                  })
                Button('断开')
                  .focusOnTouch(false)
                  .type(ButtonType.Capsule)
                  .height(32)
                  .fontSize(12)
                  .padding({ left: 12, right: 12 })
                  .fontColor(Color.White)
                  .backgroundColor('rgba(229, 57, 53, 0.85)')
                  .onClick(() => {
                    DEBUG.note('[SessionUI] disconnect click');
                    this.disconnect();
                    router.back();
                  })
              }
              .padding({ left: 12, right: 8, top: 4, bottom: 4 })
              .borderRadius(18)
              .backgroundColor('rgba(20, 20, 24, 0.75)')
              .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.3)' })
              .hitTestBehavior(HitTestMode.Default)
            }
          }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 10 })
        .alignItems(HorizontalAlign.Center)
        .position({ left: 0, bottom: this.keyboardInset })
        .id('sessionBottomControls')
        .onAreaChange((_old: Area, area: Area) => {
          this.bottomControlsHeight = Number(area.height);
          this.constrainWheelPosition();
        })
        .hitTestBehavior(HitTestMode.Transparent)
        .onTouch((event: TouchEvent) => {
          event.stopPropagation();
          if (event.type === TouchType.Down) { this.clearAutoHideTimer(); }
          if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.resetAutoHideTimer(); }
        })
      }

      // 4. 顶部悬浮状态栏（大屏胶囊式悬浮，非全宽遮挡，chromeVisible 时显示）
      if (this.isConnected && this.chromeVisible) {
        Stack({ alignContent: Alignment.Top }) {
          Row({ space: 10 }) {
            Button() {
              Text('‹')
                .fontSize(22)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Bold)
                .margin({ bottom: 2 })
            }
            .type(ButtonType.Circle)
            .width(36)
            .height(36)
            .responseRegion({ x: -6, y: -6, width: 48, height: 48 })
            .backgroundColor('rgba(255, 255, 255, 0.16)')
            .onTouch((event: TouchEvent) => {
              event.stopPropagation();
            })
            .onClick(() => {
              this.disconnect();
              router.back();
            })

            Column({ space: 2 }) {
              Row({ space: 6 }) {
                Circle({ width: 7, height: 7 })
                  .fill('#4CAF50')
                Text(this.deviceName || this.deskId)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 220 })
              }
              Text(this.remoteW > 0 && this.remoteH > 0
                ? `${this.remoteW}×${this.remoteH} · ${this.virtualMouse ? '鼠标模式' : '直接触控'}`
                : (this.virtualMouse ? '鼠标模式' : '直接触控'))
                .fontSize(11)
                .fontColor('rgba(255, 255, 255, 0.65)')
              if (!this.viewOnly) {
                Text(this.clipboardSync ? this.clipboardStatus : '剪贴板同步已关闭 · 点此开启')
                  .fontSize(11).fontColor('#B8D9FF')
                  .id('clipboardSyncToggle')
                  .onClick(() => {
                    this.clipboardSync = !this.clipboardSync;
                    if (this.clipboardSync) { this.startClipboardSync(); }
                    else { this.clipboard.stop(); }
                  })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Button('收起')
              .focusOnTouch(false)
              .type(ButtonType.Capsule)
              .fontSize(12)
              .height(34)
              .padding({ left: 12, right: 12 })
              .fontColor(Color.White)
              .backgroundColor('rgba(255, 255, 255, 0.16)')
              .onTouch((event: TouchEvent) => {
                event.stopPropagation();
              })
              .onClick(() => {
                this.chromeVisible = false;
                this.clearAutoHideTimer();
              })

            Button('断开')
              .focusOnTouch(false)
              .type(ButtonType.Capsule)
              .fontSize(13)
              .height(34)
              .padding({ left: 14, right: 14 })
              .fontColor(Color.White)
              .backgroundColor('#E53935')
              .onTouch((event: TouchEvent) => {
                event.stopPropagation();
              })
              .onClick(() => {
                this.disconnect();
                router.back();
              })
          }
          .constraintSize({ maxWidth: 580 })
          .width('94%')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(20)
          .backgroundColor('rgba(20, 20, 24, 0.78)')
          .shadow({ radius: 10, color: 'rgba(0, 0, 0, 0.35)', offsetY: 2 })
          .margin({ top: 12 })
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => {
            event.stopPropagation();
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 5. 滚轮悬浮条（RustDesk 风格：半透明一体、可拖拽）
      if (this.isConnected && !this.viewOnly && !this.virtualMouse) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            Column() {
              Text('▲')
                .fontSize(13)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              if (!this.wheelMoved) {
                this.sendScroll(3);
              }
            })

            Divider()
              .color('rgba(255, 255, 255, 0.28)')
              .strokeWidth(1)
              .margin({ left: 8, right: 8 })

            Column() {
              Text('▼')
                .fontSize(13)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              if (!this.wheelMoved) {
                this.sendScroll(-3);
              }
            })
          }
          .width(this.wheelW)
          .height(this.wheelH)
          .borderRadius(22)
          .clip(true)
          .backgroundColor('rgba(30, 30, 36, 0.65)')
          .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.25)', offsetY: 2 })
          .opacity(this.wheelDragging ? 0.95 : 0.75)
          .margin({ left: this.wheelX, top: this.wheelY })
          .hitTestBehavior(HitTestMode.Block)
          .gesture(
            PanGesture({ direction: PanDirection.All, distance: 6 })
              .onActionStart((event: GestureEvent) => {
                const fx = event.fingerList[0].displayX;
                const fy = event.fingerList[0].displayY;
                this.wheelOffsetX = fx - this.wheelX;
                this.wheelOffsetY = fy - this.wheelY;
                this.wheelDragging = true;
                this.wheelMoved = false;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.wheelMoved = true;
                this.wheelX = event.fingerList[0].displayX - this.wheelOffsetX;
                this.wheelY = event.fingerList[0].displayY - this.wheelOffsetY;
                this.constrainWheelPosition();
              })
              .onActionEnd(() => {
                this.wheelDragging = false;
                setTimeout(() => {
                  this.wheelMoved = false;
                }, 80);
              })
          )
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 6. 未连接状态对话框
      if (!this.isConnected && !this.keepDesktop) {
        Stack({ alignContent: Alignment.Center }) {
          Column({ space: 14 }) {
            if (!this.errorMessage) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color($r('app.color.accent'))
            }
            Text(this.reconnectHint.length > 0 ? this.reconnectHint : (this.connectionStatus || '正在连接...'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (this.connectionStep.length > 0 && !this.errorMessage) {
              Text(this.connectionStep)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            if (this.errorMessage) {
              Text(this.errorMessage)
                .fontSize(14)
                .fontColor($r('app.color.status_offline'))
                .textAlign(TextAlign.Center)
              Button('返回')
                .focusOnTouch(false)
                .type(ButtonType.Capsule)
                .height(36)
                .fontSize(14)
                .padding({ left: 24, right: 24 })
                .backgroundColor($r('app.color.accent'))
                .fontColor(Color.White)
                .onClick(() => {
                  router.back();
                })
            }
          }
          .constraintSize({ maxWidth: 400 })
          .width('85%')
          .padding(24)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 16, color: 'rgba(0, 0, 0, 0.25)' })
          .hitTestBehavior(HitTestMode.Block)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 7. 短线重连提示（保留最后一帧画面）
      if (this.reconnectHint.length > 0 && this.keepDesktop) {
        Stack({ alignContent: Alignment.Top }) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(Color.White)
            Text(this.reconnectHint)
              .fontSize(13)
              .fontColor(Color.White)
              .layoutWeight(1)
          }
          .constraintSize({ maxWidth: 480 })
          .width('90%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor('rgba(30, 136, 229, 0.90)')
          .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.25)' })
          .margin({ top: 60 })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background_top'))
    .expandSafeArea([SafeAreaType.KEYBOARD, SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      const w = Number(area.width);
      const h = Number(area.height);
      if (w > 0 && h > 0) {
        this.screenWidth = w;
        this.screenHeight = h;
        if (!this.wheelInited) {
          this.wheelX = this.screenWidth - this.wheelW - 12;
          this.wheelY = 96;
          this.wheelInited = true;
        }
        if (!this.wheelDragging) {
          this.constrainWheelPosition();
        }
      }
    })
  }

  private constrainWheelPosition(): void {
    const margin = 8;
    if (this.wheelX < margin) {
      this.wheelX = margin;
    }
    if (this.wheelX > this.screenWidth - this.wheelW - margin) {
      this.wheelX = Math.max(margin, this.screenWidth - this.wheelW - margin);
    }
    const topLimit = 64;
    if (this.wheelY < topLimit) {
      this.wheelY = topLimit;
    }
    // 底部留出底栏空间
    const bottomLimit = this.screenHeight - this.keyboardInset - this.bottomControlsHeight - this.wheelH - 8;
    if (this.wheelY > bottomLimit) {
      this.wheelY = Math.max(topLimit, bottomLimit);
    }
  }

  private addLog(message: string): void {
    DEBUG.note(message);
    console.log(`[Session] ${message}`);
    if (this.keepDesktop) {
      return;
    }
    const timestamp = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    this.connectionLogs.push(`[${timestamp}] ${message}`);
  }

  private async connect(isReconnect: boolean = false): Promise<void> {
    // 先检查设备 ID
    if (!this.deskId || this.deskId.trim().length === 0) {
      this.errorMessage = '缺少设备 ID';
      this.connectionStatus = '参数错误';
      console.error('[Session] Cannot connect: deskId is empty');
      return;
    }

    if (!isReconnect) {
      this.intentionalDisconnect = false;
      this.reconnectAttempt = 0;
      this.everLoggedIn = false;
      this.reconnectHint = '';
    }

    this.clipboard.stop();
    const seq = ++this.connectSeq;
    if (!isReconnect) {
      this.connectionLogs = [];
    }
    this.connectionStep = '';
    this.errorMessage = '';
    this.firstFrameLogged = false;

    try {
      this.addLog(isReconnect
        ? `短线重连 ${this.reconnectAttempt}/${this.maxReconnectAttempts}: ${this.deskId}`
        : `开始连接到: ${this.deskId}`);
      this.connectionStatus = isReconnect
        ? `重连中 ${this.reconnectAttempt}/${this.maxReconnectAttempts}`
        : '正在连接...';
      this.connectionStep = '初始化原生模块';
      this.reconnectHint = isReconnect
        ? `网络中断，正在重连（${this.reconnectAttempt}/${this.maxReconnectAttempts}）…`
        : '';

      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (seq !== this.connectSeq || this.intentionalDisconnect) { return; }
      if (!native) {
        throw new Error('原生模块不可用');
      }
      native.disconnect();
      this.isConnected = false;
      if (!isReconnect && DESK.pixelMap) {
        DESK.pixelMap.release();
        DESK.pixelMap = null;
        DESK.mapW = 0;
        DESK.mapH = 0;
        DESK.paintCount = 0;
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), isReconnect ? 200 : 350);
      });
      if (seq !== this.connectSeq) {
        return;
      }

      try {
        const context = getContext(this) as common.UIAbilityContext;
        const store = new RustDeskStore();
        await store.init(context);
        const relay = await store.loadRelay();
        if (seq !== this.connectSeq || this.intentionalDisconnect) { return; }
        const idServer = relay.apiHost.trim();
        const key = isPlaceholderKey(relay.key) ? '' : relay.key.trim();
        const ipDirect = isDirectIpId(this.deskId);
        if (!ipDirect && isOfficialPlaceholderHost(idServer)) {
          this.isConnected = false;
          this.connectionStatus = '未配置服务器';
          this.connectionStep = '请先填写自建服务器';
          this.errorMessage = '这是自建服务器。请到设置填写 ID 服务器（hbbs 的 IP 或域名，端口 21116）和密钥（id_ed25519.pub）。IP 直连可直接填对方电脑 IP，无需 hbbs。';
          this.addLog('✗ 还没填写自建 ID 服务器，上次误连了官方节点');
          return;
        }
        if (!ipDirect) {
          native.setServerConfig(
            idServer,
            relay.relayEnabled ? relay.relayHost.trim() : '',
            !relay.directEnabled,
            key
          );
          this.addLog(`已应用自建服务器: ${idServer}`);
          if (key.length === 0) {
            this.addLog('密钥为空。自建 hbbs 需要 id_ed25519.pub 里那串公钥（大约 44 个字符，一般以 = 结尾）');
          } else {
            this.addLog(`已带上密钥，长度 ${key.length}`);
          }
        } else {
          this.addLog(`IP 直连模式: ${this.deskId}（默认端口 21118，被控端需开启「IP 直接访问」）`);
        }
      } catch (configError) {
        console.warn('[Session] apply server config skipped:', configError);
      }

      this.addLog('原生模块已就绪');
      this.connectionStep = '正在连接到远程桌面';

      // 再次确保UI更新
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 50);
      });

      // 调用原生连接方法（在后台执行，避免阻塞UI）
      this.addLog('调用原生连接接口...');

      // 使用 Promise 包装同步调用，避免阻塞UI线程
      const result = await new Promise<number>((resolve) => {
        // 使用 setTimeout 将同步调用移到下一个事件循环，让UI有时间更新
        setTimeout(() => {
          if (seq !== this.connectSeq || this.intentionalDisconnect) { resolve(-1); return; }
          try {
            const connectResult = native.connect(this.deskId, this.password ?? '');
            resolve(connectResult);
          } catch (error) {
            console.error('[Session] Connect error:', error);
            resolve(-1);
          }
        }, 100);
      });

      if (seq !== this.connectSeq || this.intentionalDisconnect) { return; }
      this.addLog(`连接返回结果: ${result}`);

      const isDemo = this.deskId.startsWith('DEMO') || this.deskId.startsWith('TEST');
      const ipDirect = isDirectIpId(this.deskId);
      if (result === 0 && !isDemo) {
        this.connectionStep = ipDirect ? '正在 IP 直连' : '正在探测 ID 服务器';
        this.addLog(ipDirect ? '正在直连对方 21118 端口...' : '正在探测 RustDesk ID 服务器...');
        let status = native.getConnectionStatus();
        for (let i = 0; i < 90 && (status === 0 || status === 2); i++) {
          await new Promise<void>((resolve) => {
            setTimeout(() => resolve(), 500);
          });
          if (seq !== this.connectSeq) {
            return;
          }
          status = native.getConnectionStatus();
          const logs = native.getLogs();
          if (logs.length > 0) {
            const lines = logs.split('\n');
            const last = lines[lines.length - 1].length > 0 ? lines[lines.length - 1] : lines[lines.length - 2];
            if (last) {
              this.addLog(last);
            }
          }
        }
        if (status === 1) {
          const logs = native.getLogs();
          this.isConnected = false;
          if (logs.includes('RESULT: LOGIN_OK')) {
            this.isConnected = true;
            this.keepDesktop = true;
            this.everLoggedIn = true;
            this.reconnectAttempt = 0;
            this.reconnectInFlight = false;
            this.reconnectHint = '';
            this.connectionStatus = isReconnect ? '重连成功' : '已登录';
            this.connectionStep = '登录成功，正在收画面';
            this.demoHint = '已登录，正在等待视频帧';
            this.addLog(isReconnect ? '✓ 短线重连成功' : '✓ 登录成功，保持会话并等待画面');
            this.armSessionKeepAlive();
            this.showChromeWithTimer();
            this.addLog(isDirectIpId(this.deskId)
              ? 'IP 直连：统一画质 custom 100/60fps'
              : '中继：统一画质 custom 100/60fps');
            try {
              if (this.password.length > 0 && this.deskId.length > 0) {
                const context = getContext(this) as common.UIAbilityContext;
                const store = new RustDeskStore();
                await store.init(context);
                await store.upsertDevice(this.deskId, this.deviceName, this.password);
                await store.setDeviceStatus(this.deskId, 'Online', '当前在线');
              }
            } catch (_savePw) {
            }
            try {
              const stats = native.getVideoStats();
              if (stats.width > 0 && stats.height > 0) {
                this.remoteW = stats.width;
                this.remoteH = stats.height;
                this.syncView();
              }
            } catch (_error) {
            }
            if (seq !== this.connectSeq || this.intentionalDisconnect) { return; }
            this.startLogPump();
            this.nativeRef = native;
            this.startClipboardSync();
            return;
          } else if (logs.includes('RESULT: LOGIN_ERROR')) {
            this.connectionStatus = '登录失败';
            this.connectionStep = '对方拒绝登录';
            const errLine = logs.split('\n').find((line: string) => line.includes('RESULT: LOGIN_ERROR'));
            this.errorMessage = this.password.length === 0
              ? '对方要求密码，但这次密码是空的。请在下面填入远程密码后点重试。'
              : '密码不对。请改成对方 RustDesk 里设置的密码后再点重试。';
            this.addLog('✓ 中继已通，但登录被拒绝');
            this.reconnectInFlight = false;
            // 密码错误不自动重连
          } else if (logs.includes('RESULT: LOGIN_SENT')) {
            this.connectionStatus = '已发送登录';
            this.connectionStep = '等待登录结果';
            this.demoHint = '已向对方发送登录请求，还没收到结果';
            this.addLog('✓ 已发送 LoginRequest');
            if (isReconnect) {
              this.reconnectInFlight = false;
              void this.scheduleAutoReconnect('登录无响应');
            }
          } else if (logs.includes('RESULT: RELAY_PAIRED')) {
            this.connectionStatus = '中继已配对';
            this.connectionStep = '中继通道已建立';
            this.demoHint = '中继已接通 · 还没完成登录';
            this.addLog('✓ 设备在线，中继已配对');
          } else if (logs.includes('RESULT: RELAY_WAITING')) {
            this.connectionStatus = '等待对方上中继';
            this.connectionStep = '已连上 hbbr，等待被控端';
            this.demoHint = '已连中继，对方还没配对。请在被控电脑上点接受。';
            this.addLog('✓ 已连上 hbbr，正在等对方加入');
          } else if (logs.includes('RESULT: RELAY_CLOSED')) {
            this.connectionStatus = '中继断开';
            this.connectionStep = 'hbbr 连接被关闭';
            this.errorMessage = '中继连上后又断开。请确认 hbbr 已启动，被控端在线并接受连接。';
            this.addLog('✓ 已连 hbbr，但连接被关闭');
          } else if (logs.includes('RELAY_FAIL')) {
            this.connectionStatus = '设备在线';
            this.connectionStep = '中继未接通';
            this.errorMessage = '设备在线，但中继还没接通。请确认设置里的 hbbr 地址和 21117 端口。';
            this.addLog('✓ 设备在线，中继失败');
          } else if (logs.includes('RESULT: ONLINE')) {
            this.connectionStatus = '设备在线';
            this.connectionStep = 'ID 查询成功';
            this.demoHint = '设备在线 · 完整远程桌面协议尚未接入';
            this.addLog('✓ 设备在线');
            await this.persistDeviceStatus('Online');
          } else if (logs.includes('RESULT: OFFLINE')) {
            this.connectionStatus = '设备离线';
            this.connectionStep = 'ID 查询成功';
            this.addLog('✓ 服务器认识这个 ID，但设备当前离线');
            await this.persistDeviceStatus('Offline');
          } else if (logs.includes('RESULT: NOT_EXIST')) {
            this.connectionStatus = 'ID 不存在';
            this.connectionStep = 'ID 查询成功';
            this.addLog('✓ 服务器返回：这个 ID 不存在');
          } else if (logs.includes('RESULT: LICENSE_MISMATCH')) {
            this.connectionStatus = '密钥不匹配';
            this.connectionStep = 'ID 服务器拒绝';
            if (logs.includes('key=empty')) {
              this.errorMessage = '协议已通，但没带密钥。请到设置粘贴 id_ed25519.pub 全文，或 hbbs 日志里 Key: 后面那一串。';
              this.addLog('✓ 已连上你的 hbbs，但密钥是空的');
            } else {
              this.errorMessage = '协议已通，但密钥和 hbbs 不一致。请复制 id_ed25519.pub（约 44 字符）或 hbbs 启动日志里的 Key:，不要用私钥文件。';
              this.addLog('✓ 已连上你的 hbbs，密钥已发送但仍不匹配');
            }
          } else if (logs.includes('RESULT: LICENSE_OVERUSE')) {
            this.connectionStatus = '密钥超额';
            this.connectionStep = 'ID 服务器拒绝';
            this.errorMessage = '这个密钥的连接数已满，请检查自建服务器许可。';
            this.addLog('✓ 协议已通，但服务器许可超额');
          } else {
            this.connectionStatus = '服务器可达';
            this.connectionStep = 'ID 查询完成';
            this.addLog('✓ ID 服务器已响应');
          }
          this.addLog('完整远程桌面协议还没接上，还不能看到对方画面');
          if (isReconnect && !logs.includes('RESULT: LOGIN_ERROR')) {
            this.reconnectInFlight = false;
            void this.scheduleAutoReconnect('未完成登录');
          }
          return;
        }
        const lastError = native.getLastError();
        this.isConnected = false;
        this.connectionStatus = '连接失败';
        this.connectionStep = '服务器探测失败';
        this.errorMessage = lastError ?? 'ID 服务器不可达或超时';
        this.addLog(`✗ 探测失败: ${this.errorMessage}`);
        if (isReconnect) {
          this.reconnectInFlight = false;
          void this.scheduleAutoReconnect('探测失败');
        }
        return;
      }

      if (result === 0) {
        this.isConnected = true;
        this.connectionStatus = '已连接';
        this.connectionStep = '连接成功';
        this.addLog('✓ 连接成功');
        this.armSessionKeepAlive();
        this.showChromeWithTimer();
      } else {
        this.isConnected = false;
        this.connectionStatus = '连接失败';
        this.connectionStep = '连接失败';
        this.errorMessage = `连接失败 (错误码: ${result})`;
        this.addLog(`✗ 连接失败，错误码: ${result}`);
        this.addLog('请检查：');
        this.addLog('1. 设备 ID 是否正确');
        this.addLog('2. 远程设备是否在线');
        this.addLog('3. 网络连接是否正常');
        this.addLog('4. 密码是否正确（如果需要）');
        if (isReconnect) {
          this.reconnectInFlight = false;
          void this.scheduleAutoReconnect('连接失败');
        }
      }
    } catch (error) {
      if (seq !== this.connectSeq || this.intentionalDisconnect) { return; }
      this.isConnected = false;
      this.connectionStatus = '连接错误';
      this.connectionStep = '发生错误';
      const errorMsg = error instanceof Error ? error.message : String(error);
      this.errorMessage = `连接错误: ${errorMsg}`;
      this.addLog(`✗ 连接异常: ${errorMsg}`);
      if (isReconnect) {
        this.reconnectInFlight = false;
        void this.scheduleAutoReconnect('连接异常');
      }
    }
  }

  private scheduleAutoReconnect(reason: string): void {
    if (this.intentionalDisconnect || !this.everLoggedIn) {
      this.reconnectInFlight = false;
      return;
    }
    if (this.reconnectInFlight) {
      return;
    }
    if (this.reconnectAttempt >= this.maxReconnectAttempts) {
      this.reconnectInFlight = false;
      this.connectionStatus = '会话中断';
      this.reconnectHint = '';
      this.errorMessage = `多次重连失败（${reason}）。请检查网络后返回重连。`;
      this.addLog(`✗ 已达最大重连次数 ${this.maxReconnectAttempts}，停止`);
      this.keepDesktop = false;
      return;
    }
    this.reconnectInFlight = true;
    this.reconnectAttempt += 1;
    const attempt = this.reconnectAttempt;
    const delayMs = Math.min(8000, 1000 * attempt);
    this.connectionStatus = `重连中 ${attempt}/${this.maxReconnectAttempts}`;
    this.reconnectHint = `网络中断（${reason}），${Math.ceil(delayMs / 1000)} 秒后重连…`;
    this.addLog(`… ${delayMs}ms 后第 ${attempt} 次短线重连`);
    setTimeout(() => {
      if (this.intentionalDisconnect) {
        this.reconnectInFlight = false;
        return;
      }
      if (attempt !== this.reconnectAttempt) {
        return;
      }
      void this.connect(true);
    }, delayMs);
  }

  private startClipboardSync(): void {
    if (!this.nativeRef || !this.isConnected || this.viewOnly || !this.clipboardSync) { return; }
    const seq = this.connectSeq;
    this.clipboard.start(this.nativeRef, getContext(this) as common.UIAbilityContext,
      () => this.isConnected && !this.viewOnly && this.clipboardSync && this.connectSeq === seq,
      (status: string) => { this.clipboardStatus = status; });
  }

  private armSessionKeepAlive(): void {
    // Two distinct callbacks:
    //   - onBackgroundTimeout: fires after the bounded background hold
    //     expires. Used to tear down the native session and mark the page
    //     state as "resumable" (not user-intentional). Must NOT set
    //     intentionalDisconnect=true — the next foreground should trigger
    //     the reconnect path automatically.
    //   - onForegroundResume: fires from EntryAbility.onForeground only
    //     when a background-timeout teardown latched; re-establishes the
    //     prior remote session via connect(true) (existing reconnect path).
    // The user-explicit 断开 button and aboutToDisappear still go through
    // this.disconnect() directly, which sets intentionalDisconnect=true
    // and calls SessionKeepAlive.setActive(false) to suppress any resume.
    SessionKeepAlive.setActive(
      true,
      () => { this.backgroundReleaseInFlight = this.releaseForBackgroundTimeout(); },
      () => { void this.resumeFromBackground(); },
      (foreground: boolean) => this.clipboard.setForeground(foreground)
    );
  }

  /**
   * Background-hold timeout fired: tear down the native session + UI
   * timers but leave the Session page "resumable" so the next foreground
   * can re-establish the prior remote connection without a user tap.
   *
   * Deliberately does NOT:
   *   - set intentionalDisconnect=true (that flags a final user disconnect)
   *   - reset reconnectAttempt (preserves existing reconnect bookkeeping)
   *   - call SessionKeepAlive.setActive(false) (the latch + remaining
   *     handlers must stay armed so onForeground can fire the resume
   *     callback on this same teardown)
   */
  private async releaseForBackgroundTimeout(): Promise<void> {
    this.clipboard.stop();
    DEBUG.note('[Session] releaseForBackgroundTimeout (resumable)');
    this.clearAutoHideTimer();
    this.showKeyboard = false;
    this.releaseFloatingButtons();
    if (this.videoTimer !== -1) {
      clearInterval(this.videoTimer);
      this.videoTimer = -1;
    }
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
      this.logTimer = -1;
    }
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    // Invalidate any in-flight clipboard / pointer ops for the prior
    // generation; this does not affect reconnect because connect() bumps
    // connectSeq itself.
    this.connectSeq++;
    try {
      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (native) {
        native.disconnect();
      }
    } catch (_e) {
    }
    this.isConnected = false;
    this.connectionStatus = '后台已暂停';
    this.errorMessage = '';
    this.demoHint = '从后台返回后会自动重连';
  }

  /**
   * EntryAbility.onForeground dispatched this via SessionKeepAlive. If
   * the page is still alive (no user-explicit disconnect, page still on
   * the router stack, no concurrent reconnect in flight), call the
   * existing reconnect path to re-establish the prior remote session.
   * Honors all existing safety semantics: intentionalDisconnect gates
   * reconnect, viewOnly is allowed only after a prior successful login,
   * reconnectInFlight dedupe, pageAlive gate, etc.
   */
  private async resumeFromBackground(): Promise<void> {
    if (this.intentionalDisconnect) {
      DEBUG.note('resumeFromBackground: skipped (intentionalDisconnect)');
      return;
    }
    if (!DESK.pageAlive) {
      DEBUG.note('resumeFromBackground: skipped (pageAlive=false)');
      return;
    }
    if (!this.deskId || this.deskId.trim().length === 0) {
      DEBUG.note('resumeFromBackground: skipped (no deskId)');
      return;
    }
    if (this.reconnectInFlight) {
      DEBUG.note('resumeFromBackground: skipped (reconnectInFlight)');
      return;
    }
    if (this.viewOnly && !this.everLoggedIn) {
      DEBUG.note('resumeFromBackground: skipped (viewOnly, never logged in)');
      return;
    }
    if (!SessionKeepAlive.isActive() && !SessionKeepAlive.isPendingResume()) {
      DEBUG.note('resumeFromBackground: skipped (no pending resume)');
      return;
    }
    const backgroundRelease = this.backgroundReleaseInFlight;
    SessionKeepAlive.consumePendingResume();
    await backgroundRelease;
    if (this.intentionalDisconnect || !DESK.pageAlive || this.reconnectInFlight ||
        (this.viewOnly && !this.everLoggedIn)) {
      DEBUG.note('resumeFromBackground: skipped (gate changed during background release)');
      return;
    }
    DEBUG.note('[Session] resumeFromBackground: auto reconnect');
    this.reconnectAttempt = 0;
    this.connectionStatus = '后台返回，正在重连';
    this.reconnectHint = '从后台返回，正在重连…';
    void this.connect(true);
  }

  private async persistDeviceStatus(status: string): Promise<void> {
    if (this.deskId.length === 0) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const store = new RustDeskStore();
      await store.init(context);
      await store.setDeviceStatus(this.deskId, status, status === 'Online' ? '当前在线' : '离线');
    } catch (_e) {
    }
  }

  private async disconnect(): Promise<void> {
    this.clipboard.stop();
    this.connectSeq++;
    this.releaseFloatingButtons();
    this.showKeyboard = false;
    this.intentionalDisconnect = true;
    this.reconnectInFlight = false;
    this.reconnectAttempt = 0;
    this.reconnectHint = '';
    this.clearAutoHideTimer();
    SessionKeepAlive.setActive(false);
    try {
      if (this.videoTimer !== -1) {
        clearInterval(this.videoTimer);
        this.videoTimer = -1;
      }
      if (this.logTimer !== -1) {
        clearInterval(this.logTimer);
        this.logTimer = -1;
      }
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      const nativeMod = await import('../native/HarmonyDeskNative');
      const native = await nativeMod.getNativeModule();
      if (native) {
        native.disconnect();
      }
      this.isConnected = false;
      this.connectionStatus = '未连接';
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = `断开连接错误: ${error}`;
    }
  }

  private startLogPump(): void {
    if (this.logTimer !== -1) {
      clearInterval(this.logTimer);
    }
    this.logTimer = setInterval(async () => {
      try {
        const nativeMod = await import('../native/HarmonyDeskNative');
        const native = await nativeMod.getNativeModule();
        if (!native) {
          return;
        }
        this.applyNativeHint(native.getLogs());
        const status = native.getConnectionStatus();
        // 3 = FAILED：链路断了。已登录过且非主动断开 → 短线重连
        if (status === 3 && this.isConnected && !this.intentionalDisconnect) {
          DEBUG.note('session status=3 -> auto reconnect');
          this.clipboard.stop();
          SessionKeepAlive.setActive(false);
          this.isConnected = false;
          this.connectionStatus = '会话中断';
          this.errorMessage = '';
          this.reconnectHint = '检测到断线，准备重连…';
          this.addLog('✗ 会话中断，启动短线重连');
          void this.scheduleAutoReconnect('会话中断');
        }
      } catch (_error) {
      }
    }, 800);
  }

  private applyNativeHint(logs: string): void {
    if (!logs) {
      return;
    }
    const lines = logs.split('\n').filter((line: string) => {
      return line.startsWith('video ')
        || line.startsWith('decoder ')
        || line.startsWith('session msg ')
        || line.startsWith('peer display ')
        || line.startsWith('switch display ')
        || line.startsWith('permission ')
        || line.startsWith('peer close')
        || line.startsWith('message box ')
        || line.startsWith('session loop')
        || line.startsWith('session read');
    });
    if (lines.length === 0) {
      return;
    }
    const last = lines[lines.length - 1];
    if (last && last !== this.lastHint) {
      this.lastHint = last;
      DEBUG.note(last);
      if (this.keepDesktop) {
        return;
      }
      this.demoHint = last.startsWith('video ') ? '远程桌面' : last;
      if (last.startsWith('video ')) {
        this.connectionStatus = '正在收画面';
      }
    }
  }

  private get displayModeLabel(): string {
    if (this.displayMode === DisplayMode.FIT) {
      return '适应';
    } else if (this.displayMode === DisplayMode.FILL) {
      return '填充';
    } else {
      return '1:1';
    }
  }

  private cycleDisplayMode(): void {
    if (this.displayMode === DisplayMode.FIT) {
      this.setDisplayMode(DisplayMode.FILL);
    } else if (this.displayMode === DisplayMode.FILL) {
      this.setDisplayMode(DisplayMode.ORIGINAL);
    } else {
      this.setDisplayMode(DisplayMode.FIT);
    }
  }

  private setDisplayMode(mode: DisplayMode): void {
    this.displayMode = mode;
    VIEW.setMode(mode);
    this.syncView();
    DEBUG.note(`mode switched: ${mode}`);
  }

  private containScale(): number {
    return VIEW.baseScale;
  }

  private zoomedW(): number {
    return VIEW.renderedW;
  }

  private zoomedH(): number {
    return VIEW.renderedH;
  }

  private zoomedX(): number {
    return VIEW.originX;
  }

  private zoomedY(): number {
    return VIEW.originY;
  }

  private setViewScale(scale: number): void {
    VIEW.setUserZoom(scale);
    this.syncView();
  }

  private resetView(): void {
    VIEW.reset();
    this.syncView();
  }

  private syncView(): void {
    VIEW.updateGeometry(this.videoViewW, this.videoViewH, this.remoteW, this.remoteH);
    this.viewScale = VIEW.scale;
    this.panX = VIEW.panX;
    this.panY = VIEW.panY;
  }

  private constrainPan(): void {
    VIEW.constrainPan();
    VIEW.originX = (VIEW.w - VIEW.renderedW) / 2 + VIEW.panX;
    VIEW.originY = (VIEW.h - VIEW.renderedH) / 2 + VIEW.panY;
    this.syncView();
  }

  private cursorScreenX(): number {
    return VIEW.remoteToScreen(this.cursorX, this.cursorY)[0];
  }

  private cursorScreenY(): number {
    return VIEW.remoteToScreen(this.cursorX, this.cursorY)[1];
  }

  private clampCursor(): void {
    this.cursorX = VIEW.clampRemoteX(this.cursorX);
    this.cursorY = VIEW.clampRemoteY(this.cursorY);
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
  }

  private beginTrackpadGesture(event: GestureEvent): void {
    TRACKPAD.ignoreGesture = true;
    if (this.textSelectMode || !this.virtualMouse || TRACKPAD.freezeMove) {
      mouseTrace('pan-start-ignored');
      return;
    }
    TRACKPAD.ignoreGesture = false;
    this.clampCursor();
    TRACKPAD.gestureStartX = this.cursorX;
    TRACKPAD.gestureStartY = this.cursorY;
    mouseTrace(`pan-origin ${TRACKPAD.gestureStartX},${TRACKPAD.gestureStartY} off=${event.offsetX},${event.offsetY}`);
  }

  private moveTrackpadGesture(offsetX: number, offsetY: number): void {
    if (this.textSelectMode || TRACKPAD.ignoreGesture || TRACKPAD.freezeMove || !this.virtualMouse || !this.nativeRef) {
      return;
    }
    if (this.videoViewW <= 0 || this.videoViewH <= 0 || this.remoteW <= 0 || this.remoteH <= 0 ||
        !Number.isFinite(offsetX) || !Number.isFinite(offsetY)) {
      return;
    }
    // 触摸板灵敏度：越小越慢（约 90%），独立 X/Y 轴缩放，避免非匹配长宽比在 Y 轴过度缩放
    const speed = 0.90;
    const scaleX = (this.remoteW / this.videoViewW) * speed;
    const scaleY = (this.remoteH / this.videoViewH) * speed;
    this.cursorX = VIEW.clampRemoteX(TRACKPAD.gestureStartX + offsetX * scaleX);
    this.cursorY = VIEW.clampRemoteY(TRACKPAD.gestureStartY + offsetY * scaleY);
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
    if (Math.abs(offsetX) + Math.abs(offsetY) > 10) {
      this.touchMoved = true;
      this.clearRightClickTimer();
    }
    mouseTrace(`pan-move off=${offsetX.toFixed(1)},${offsetY.toFixed(1)} scale=${scaleX.toFixed(3)},${scaleY.toFixed(3)} send=${this.cursorX},${this.cursorY}`);
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
  }

  private mapToRemote(localX: number, localY: number): [number, number] | null {
    return VIEW.screenToRemote(localX, localY);
  }

  private clearRightClickTimer(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private sendScroll(deltaY: number): void {
    if (this.viewOnly || !this.isConnected || !this.nativeRef) {
      return;
    }
    this.clampCursor();
    // 先同步当前光标，再发滚轮，对方会在光标位置滚动
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
    this.nativeRef.sendMouseWheel(deltaY);
    DEBUG.note(`scroll dy=${deltaY}`);
  }

  private sendRightButton(pressed: boolean): void {
    if (this.viewOnly || !this.isConnected || !this.nativeRef) {
      return;
    }
    this.clampCursor();
    if (pressed) {
      if (this.rightDown) {
        return;
      }
      this.rightDown = true;
      this.rightClicked = true;
      TRACKPAD.freezeMove = true;
      this.clearRightClickTimer();
      this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
      this.nativeRef.sendMouseClick(2, true);
      DEBUG.note(`right down ${this.cursorX},${this.cursorY}`);
      mouseTrace(`right-down ${this.cursorX},${this.cursorY}`);
      return;
    }
    if (!this.rightDown) {
      return;
    }
    this.nativeRef.sendMouseClick(2, false);
    this.rightDown = false;
    TRACKPAD.freezeMove = false;
    DEBUG.note(`right up ${this.cursorX},${this.cursorY}`);
    mouseTrace(`right-up ${this.cursorX},${this.cursorY}`);
  }

  private sendRightClickAtCursor(): void {
    if (this.viewOnly || !this.isConnected || !this.nativeRef || this.touchMoved || this.rightClicked) {
      return;
    }
    this.sendRightButton(true);
    this.sendRightButton(false);
  }

  private focusCursorForMenu(): void {
    if (this.remoteW <= 0 || this.remoteH <= 0 || this.videoViewW <= 0 || this.videoViewH <= 0) {
      return;
    }
    if (VIEW.userZoom < 2.4) {
      VIEW.userZoom = 2.4;
      VIEW.updateGeometry();
    }
    const imgW = VIEW.renderedW;
    const imgH = VIEW.renderedH;
    VIEW.panX = imgW / 2 - (this.cursorX / this.remoteW) * imgW;
    VIEW.panY = imgH / 2 - (this.cursorY / this.remoteH) * imgH;
    this.constrainPan();
  }

  private handleTrackpadPress(event: TouchEvent, px: number, py: number): void {
    if (this.viewOnly || !this.isConnected) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.touchMoved = false;
      this.rightClicked = false;
      this.touchStartX = px;
      this.touchStartY = py;
      this.clearRightClickTimer();
      // 按住底部「左键」拖动时，不触发长按右键
      if (!TRACKPAD.freezeMove && !this.leftHeld) {
        this.longPressTimer = setTimeout(() => {
          this.sendRightClickAtCursor();
        }, 500);
      }
    } else if (event.type === TouchType.Move) {
      if (Math.abs(px - this.touchStartX) + Math.abs(py - this.touchStartY) > 10) {
        this.touchMoved = true;
        this.clearRightClickTimer();
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.clearRightClickTimer();
      // 轻点屏幕 = 当前光标位置左键单击（触摸板 tap-to-click）
      if (!this.touchMoved && !this.rightClicked && !this.leftHeld && !TRACKPAD.freezeMove &&
        this.nativeRef && event.type === TouchType.Up) {
        this.clampCursor();
        this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
        this.nativeRef.sendMouseClick(0, true);
        this.nativeRef.sendMouseClick(0, false);
        mouseTrace(`tap-click ${this.cursorX},${this.cursorY}`);
        DEBUG.note(`左键单击 ${this.cursorX},${this.cursorY}`);
      }
      TRACKPAD.freezeMove = false;
    }
  }

  private touchPoint(event: TouchEvent): TouchObject | null {
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    if (event.touches.length > 0) {
      return event.touches[0];
    }
    return null;
  }

  private handleVirtualMouseTouch(event: TouchEvent): void {
    if (!this.nativeRef) {
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.vmNeedAnchor = true;
      return;
    }
    const point = this.touchPoint(event);
    if (!point) {
      return;
    }
    const fx = point.windowX;
    const fy = point.windowY;
    if (event.type === TouchType.Down) {
      this.lastFingerX = fx;
      this.lastFingerY = fy;
      this.vmNeedAnchor = true;
      return;
    }
    if (event.type !== TouchType.Move) {
      return;
    }
    if (this.vmNeedAnchor) {
      this.lastFingerX = fx;
      this.lastFingerY = fy;
      this.vmNeedAnchor = false;
      return;
    }
    const dx = fx - this.lastFingerX;
    const dy = fy - this.lastFingerY;
    this.lastFingerX = fx;
    this.lastFingerY = fy;
    if (this.videoViewW <= 0 || this.videoViewH <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    const speed = 0.90;
    const scaleX = (this.remoteW / this.videoViewW) * speed;
    const scaleY = (this.remoteH / this.videoViewH) * speed;
    this.cursorX = VIEW.clampRemoteX(this.cursorX + dx * scaleX);
    this.cursorY = VIEW.clampRemoteY(this.cursorY + dy * scaleY);
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
  }

  private handleRemoteTouch(event: TouchEvent): void {
    if (this.pinching || event.touches.length >= 2) {
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      return;
    }
    if (this.viewOnly || !this.isConnected || !this.nativeRef) {
      if (!this.firstTouchLogged) {
        this.firstTouchLogged = true;
        this.addLog(this.viewOnly ? '当前是只读，触摸不会发给对方' : '触摸到了，但原生还没就绪');
      }
      return;
    }
    if (this.virtualMouse && !this.textSelectMode) {
      return;
    }
    const point = this.touchPoint(event);
    if (!point) {
      return;
    }
    const mapped = this.mapToRemote(point.x, point.y);
    if (event.type === TouchType.Down) {
      if (!mapped) {
        // Black-bar / letterbox touch: do not register
        return;
      }
      const x = mapped[0];
      const y = mapped[1];
      this.cursorX = x;
      this.cursorY = y;
      TRACKPAD.cursorX = x;
      TRACKPAD.cursorY = y;
      this.touchDragging = false;
      this.touchMoved = false;
      this.rightClicked = false;
      this.touchStartX = x;
      this.touchStartY = y;
      if (!this.firstTouchLogged) {
        this.firstTouchLogged = true;
        this.addLog(`已发送直接触控 ${x},${y}`);
      }
      mouseTrace(`abs-down mapped=${x},${y} local=${point.x},${point.y}`);
      this.nativeRef.sendMouseMove(x, y);
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
      }
      // 选字模式不做长按右键，避免打断拖选
      if (!this.textSelectMode) {
        this.longPressTimer = setTimeout(() => {
          if (!this.touchMoved && this.nativeRef) {
            this.nativeRef.sendMouseClick(2, true);
            this.nativeRef.sendMouseClick(2, false);
            this.rightClicked = true;
          }
        }, 480);
      }
    } else if (event.type === TouchType.Move) {
      if (!mapped) {
        return;
      }
      const x = mapped[0];
      const y = mapped[1];
      this.cursorX = x;
      this.cursorY = y;
      TRACKPAD.cursorX = x;
      TRACKPAD.cursorY = y;
      // 选字模式：更小位移就进入拖选
      const dragThreshold = this.textSelectMode ? 4 : 8;
      if (Math.abs(x - this.touchStartX) + Math.abs(y - this.touchStartY) > dragThreshold) {
        this.touchMoved = true;
        if (this.longPressTimer !== -1) {
          clearTimeout(this.longPressTimer);
          this.longPressTimer = -1;
        }
        if (!this.touchDragging) {
          this.nativeRef.sendMouseClick(0, true);
          this.touchDragging = true;
        }
      }
      this.nativeRef.sendMouseMove(x, y);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      if (this.touchDragging) {
        // Drag in progress: always release left mouse button reliably
        this.nativeRef.sendMouseClick(0, false);
      } else if (mapped && event.type === TouchType.Up && !this.touchMoved && !this.rightClicked) {
        // Clean single tap inside rendered frame: send move and left click
        const x = mapped[0];
        const y = mapped[1];
        this.cursorX = x;
        this.cursorY = y;
        TRACKPAD.cursorX = x;
        TRACKPAD.cursorY = y;
        this.nativeRef.sendMouseMove(x, y);
        this.nativeRef.sendMouseClick(0, true);
        this.nativeRef.sendMouseClick(0, false);
        mouseTrace(`abs-tap-click mapped=${x},${y}`);
      }
      this.touchDragging = false;
      this.touchMoved = false;
      this.rightClicked = false;
    }
  }

  private toggleTextSelectMode(): void {
    this.textSelectMode = !this.textSelectMode;
    if (this.textSelectMode) {
      this.chromeVisible = true;
      this.clearAutoHideTimer();
      DEBUG.note('选字模式：拖选文字，用底部快捷条复制');
    } else {
      this.resetAutoHideTimer();
    }
  }

  private sendCtrlLetter(letter: string): void {
    if (!this.isConnected || !this.nativeRef || this.viewOnly || letter.length === 0) {
      return;
    }
    const ch = letter.toLowerCase().charCodeAt(0);
    // ControlKey::Control = 4
    this.nativeRef.sendChord(ch, 4);
    DEBUG.note(`chord Ctrl+${letter}`);
  }

}
