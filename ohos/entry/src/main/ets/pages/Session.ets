import router from '@ohos.router';
import type common from '@ohos.app.ability.common';
import { image } from '@kit.ImageKit';
import { isOfficialPlaceholderHost, isPlaceholderKey, isDirectIpId, RustDeskStore } from '../services/RustDeskStore';
import type { HarmonyDeskNative } from '../native/HarmonyDeskNative';
import { SessionKeepAlive } from '../services/SessionKeepAlive';

class TrackpadLogic {
  cursorX: number = 0;
  cursorY: number = 0;
  gestureStartX: number = 0;
  gestureStartY: number = 0;
  ignoreGesture: boolean = false;
  freezeMove: boolean = false;
}

class ViewBox {
  w: number = 0;
  h: number = 0;
  remoteW: number = 1920;
  remoteH: number = 1080;
  scale: number = 1;
  panX: number = 0;
  panY: number = 0;
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
      this.renderedW = this.w > 0 ? this.w : 0;
      this.renderedH = this.h > 0 ? this.h : 0;
      this.originX = this.panX;
      this.originY = this.panY;
      return;
    }

    const containScale = Math.min(this.w / this.remoteW, this.h / this.remoteH);
    this.renderedW = this.remoteW * containScale * this.scale;
    this.renderedH = this.remoteH * containScale * this.scale;

    this.constrainPan();

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

  private contain(): number {
    if (VIEW.remoteW <= 0 || VIEW.remoteH <= 0 || VIEW.w <= 0 || VIEW.h <= 0) {
      return 1;
    }
    return Math.min(VIEW.w / VIEW.remoteW, VIEW.h / VIEW.remoteH);
  }

  private imgW(): number {
    return VIEW.remoteW * this.contain() * VIEW.scale;
  }

  private imgH(): number {
    return VIEW.remoteH * this.contain() * VIEW.scale;
  }

  private screenX(): number {
    if (VIEW.w <= 0 || VIEW.h <= 0 || VIEW.remoteW <= 0) {
      return 0;
    }
    const ox = VIEW.renderedW > 0 ? VIEW.originX : (VIEW.w - this.imgW()) / 2 + VIEW.panX;
    const w = VIEW.renderedW > 0 ? VIEW.renderedW : this.imgW();
    return ox + TRACKPAD.cursorX / VIEW.remoteW * w;
  }

  private screenY(): number {
    if (VIEW.w <= 0 || VIEW.h <= 0 || VIEW.remoteH <= 0) {
      return 0;
    }
    const oy = VIEW.renderedH > 0 ? VIEW.originY : (VIEW.h - this.imgH()) / 2 + VIEW.panY;
    const h = VIEW.renderedH > 0 ? VIEW.renderedH : this.imgH();
    return oy + TRACKPAD.cursorY / VIEW.remoteH * h;
  }

  private syncPos(): void {
    const nx = this.screenX();
    const ny = this.screenY();
    if (nx !== this.drawX || ny !== this.drawY) {
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
      VIEW.remoteW = frame.width;
      VIEW.remoteH = frame.height;
      VIEW.updateGeometry(undefined, undefined, frame.width, frame.height);
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
        .objectFit(ImageFit.Contain)
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

@Component
struct TypeBar {
  onSend: (text: string) => void = (_text: string) => {};
  onControl: (code: number) => void = (_code: number) => {};
  onImeToggle: () => void = () => {};
  onCad: () => void = () => {};
  onAltF4: () => void = () => {};
  onShowDesktop: () => void = () => {};
  @State draft: string = '';
  @State passwordMode: boolean = false;

  private submitDraft(): void {
    if (this.draft.length === 0) {
      // 空框：真回车
      this.onControl(27);
      return;
    }
    // 有字：只发文字，不带真回车
    const text = this.draft;
    this.draft = '';
    this.onSend(text);
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Button('Ctrl+Alt+Del')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('rgba(255, 255, 255, 0.18)')
          .onClick(() => {
            this.onCad();
          })
        Button('Alt+F4')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('rgba(255, 255, 255, 0.18)')
          .onClick(() => {
            this.onAltF4();
          })
        Button('显示桌面')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('rgba(255, 255, 255, 0.18)')
          .onClick(() => {
            this.onShowDesktop();
          })
      }
      .width('100%')
      Row({ space: 6 }) {
        TextInput({
          text: this.draft,
          placeholder: this.passwordMode ? '有字点回车=发送，空框再点=回车' : '有字点回车=发送，空框再点=回车'
        })
          .layoutWeight(1)
          .height(40)
          .backgroundColor('#FF2A2A2A')
          .fontColor(Color.White)
          .placeholderColor('#88FFFFFF')
          .caretColor(Color.White)
          .type(this.passwordMode ? InputType.Password : InputType.Normal)
          .enterKeyType(EnterKeyType.Send)
          .onChange((value: string) => {
            this.draft = value;
          })
          .onSubmit(() => {
            this.submitDraft();
          })
        Button(this.passwordMode ? '密码' : '文本')
          .constraintSize({ minWidth: 72 })
          .height(40)
          .padding({ left: 10, right: 10 })
          .fontSize(14)
          .backgroundColor(this.passwordMode ? '#1E88E5' : 'rgba(255,255,255,0.18)')
          .fontColor(Color.White)
          .onClick(() => {
            this.passwordMode = !this.passwordMode;
          })
      }
      .width('100%')
      Row({ space: 4 }) {
        Button('中英')
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .padding({ left: 2, right: 2 })
          .onClick(() => {
            this.onImeToggle();
          })
        Button('空格')
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .padding({ left: 2, right: 2 })
          .onClick(() => {
            this.onControl(30);
          })
        Button('Tab')
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .padding({ left: 2, right: 2 })
          .onClick(() => {
            this.onControl(31);
          })
        Button('退格')
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .padding({ left: 2, right: 2 })
          .onClick(() => {
            this.onControl(2);
          })
        Button(this.draft.length > 0 ? '发送' : '回车')
          .layoutWeight(1)
          .height(40)
          .fontSize(12)
          .padding({ left: 2, right: 2 })
          .backgroundColor('#1E88E5')
          .fontColor(Color.White)
          .onClick(() => {
            this.submitDraft();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('rgba(0, 0, 0, 0.82)')
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
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(Color.White)
      .backgroundColor('rgba(255, 255, 255, 0.18)')
      .onTouch((event: TouchEvent) => {
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
    Button(this.held ? '左键按下' : '左键')
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontColor(Color.White)
      .backgroundColor(this.held ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
      .onTouch((event: TouchEvent) => {
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
  @State showToolbar: boolean = false;
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
  @State virtualMouse: boolean = true;
  @State leftHeld: boolean = false;
  @State actionHint: string = '';
  @State textSelectMode: boolean = false;
  @State wheelX: number = 300;
  @State wheelY: number = 120;
  @State wheelDragging: boolean = false;

  private videoTimer: number = -1;
  private logTimer: number = -1;
  private lastHint: string = '';
  private screenWidth: number = 0;
  private screenHeight: number = 0;
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
  private readonly maxReconnectAttempts: number = 5;
  private pinchStartScale: number = 1;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinching: boolean = false;
  private lastFingerX: number = 0;
  private lastFingerY: number = 0;
  private vmNeedAnchor: boolean = true;

  async aboutToAppear() {
    console.info('[Session] aboutToAppear called');

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

    VIEW.scale = 1;
    VIEW.panX = 0;
    VIEW.panY = 0;

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
    this.intentionalDisconnect = true;
    this.reconnectInFlight = false;
    this.connectSeq++;
    DESK.pageAlive = false;
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
      // 全屏远程画面
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          DesktopSurface()
          if (this.virtualMouse && this.isConnected) {
            CursorLayer()
          }

          // 选字条：画面底部内侧，落在底栏上方
          if (this.isConnected && this.textSelectMode && !this.viewOnly) {
            Row({ space: 6 }) {
              Button('全选')
                .height(34)
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor('rgba(40, 40, 44, 0.92)')
                .onClick(() => {
                  this.sendCtrlLetter('a');
                })
              Button('复制')
                .height(34)
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor('rgba(40, 40, 44, 0.92)')
                .onClick(() => {
                  this.sendCtrlLetter('c');
                })
              Button('粘贴')
                .height(34)
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor('rgba(40, 40, 44, 0.92)')
                .onClick(() => {
                  this.sendCtrlLetter('v');
                })
              Button('剪切')
                .height(34)
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor('rgba(40, 40, 44, 0.92)')
                .onClick(() => {
                  this.sendCtrlLetter('x');
                })
              Button('完成')
                .height(34)
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor('#1E88E5')
                .onClick(() => {
                  this.textSelectMode = false;
                })
            }
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(18)
            .backgroundColor('rgba(0, 0, 0, 0.55)')
            .margin({ left: 8, right: 48, bottom: 8 })
            .align(Alignment.BottomStart)
          }
        }
          .width('100%')
          .layoutWeight(1)
          .clip(true)
          .backgroundColor('#000000')
          .onAreaChange((_old: Area, area: Area) => {
            this.videoViewW = Number(area.width);
            this.videoViewH = Number(area.height);
            this.syncView();
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
                  this.pinchStartScale = VIEW.scale;
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

        if (this.showKeyboard && this.isConnected) {
          TypeBar({
            onSend: (text: string) => {
              DEBUG.note(`send text ${text.length}`);
              this.nativeRef?.sendText(text);
            },
            onControl: (code: number) => {
              this.nativeRef?.sendControlKey(code, true);
            },
            onImeToggle: () => {
              this.nativeRef?.sendChord(32, 4);
              DEBUG.note('中英 Ctrl+Space');
            },
            onCad: () => {
              this.nativeRef?.sendControlKey(100, true);
              DEBUG.note('Ctrl+Alt+Del');
            },
            onAltF4: () => {
              // Alt=1, F4=15 → chord uses 1000+ControlKey
              this.nativeRef?.sendChord(1015, 1);
              DEBUG.note('Alt+F4');
            },
            onShowDesktop: () => {
              // Meta/Win=23 + 'd'=100
              this.nativeRef?.sendChord(100, 23);
              DEBUG.note('Win+D 显示桌面');
            }
          })
        }

        if (this.virtualMouse && this.isConnected) {
            Row({ space: 8 }) {
              HoldLeftBtn({
                onDown: () => {
                  if (!this.nativeRef || this.viewOnly) {
                    return;
                  }
                  TRACKPAD.freezeMove = true;
                  this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
                  this.nativeRef.sendMouseClick(0, true);
                },
                onUp: () => {
                  if (!this.nativeRef) {
                    return;
                  }
                  this.nativeRef.sendMouseClick(0, false);
                  TRACKPAD.freezeMove = false;
                }
              })
              HoldRightBtn({
                onDown: () => {
                  if (!this.nativeRef || this.viewOnly) {
                    return;
                  }
                  this.touchMoved = false;
                  this.rightClicked = false;
                  this.sendRightButton(true);
                },
                onUp: () => {
                  this.sendRightButton(false);
                }
              })
              Button('键盘')
                .height(44)
                .fontSize(14)
                .fontColor(Color.White)
                .backgroundColor(this.showKeyboard ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                .onClick(() => {
                  this.showKeyboard = !this.showKeyboard;
                  if (this.showKeyboard) {
                    this.textSelectMode = false;
                  }
                })
              Button(this.textSelectMode ? '选字中' : '选字')
                .height(44)
                .fontSize(14)
                .fontColor(Color.White)
                .backgroundColor(this.textSelectMode ? '#1E88E5' : 'rgba(255, 255, 255, 0.18)')
                .onClick(() => {
                  this.toggleTextSelectMode();
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('rgba(0, 0, 0, 0.72)')
          }
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.screenWidth = Number(area.width) as number;
        this.screenHeight = Number(area.height) as number;
        if (!this.wheelInited && this.screenWidth > 0) {
          this.wheelX = this.screenWidth - this.wheelW - 8;
          this.wheelY = 96;
          this.wheelInited = true;
        }
        if (!this.wheelDragging) {
          this.constrainWheelPosition();
        }
      })

      // 顶部状态栏（连接后显示）
      if (this.isConnected && this.showToolbar) {
        Row({ space: 12 }) {
          Button()
            .type(ButtonType.Circle)
            .width(36)
            .height(36)
            .backgroundColor($r('app.color.card_background'))
            .onClick(() => {
              router.back();
            })
          .stateEffect(true)

          Column({ space: 2 }) {
            Text(this.deviceName || this.deskId)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('已连接')
              .fontSize(12)
              .fontColor($r('app.color.status_online'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button('断开')
            .type(ButtonType.Capsule)
            .fontSize(13)
            .height(32)
            .fontColor($r('app.color.text_on_accent'))
            .backgroundColor($r('app.color.accent'))
            .onClick(() => {
              this.disconnect();
              router.back();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.card_background'))
        .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.1)' })
      }

      // 滚轮悬浮条（RustDesk 风格：半透明一体、可拖拽）
      if (this.isConnected && !this.viewOnly && !this.showKeyboard) {
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
          .backgroundColor('rgba(40, 40, 44, 0.55)')
          .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.22)', offsetY: 2 })
          .opacity(this.wheelDragging ? 0.9 : 0.72)
          .margin({ left: this.wheelX, top: this.wheelY })
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
                // 短延迟后再清，避免拖完立刻误触 onClick
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

      if (!this.isConnected && !this.keepDesktop) {
        Stack() {
          Column({ space: 12 }) {
            Text(this.reconnectHint.length > 0 ? this.reconnectHint : '正在连接...')
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
            if (this.errorMessage) {
              Text(this.errorMessage)
                .fontSize(14)
                .fontColor($r('app.color.status_offline'))
              Button('返回')
                .type(ButtonType.Capsule)
                .onClick(() => {
                  router.back();
                })
            }
          }
          .padding(20)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .align(Alignment.Center)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 短线重连提示（保留最后一帧画面）
      if (this.reconnectHint.length > 0 && this.keepDesktop) {
        Row() {
          Text(this.reconnectHint)
            .fontSize(13)
            .fontColor(Color.White)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor('#CC1E88E5')
        .margin({ top: 48 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background_top'))
    .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
  }

  private constrainWheelPosition(): void {
    const margin = 4;
    if (this.wheelX < margin) {
      this.wheelX = margin;
    }
    if (this.wheelX > this.screenWidth - this.wheelW - margin) {
      this.wheelX = Math.max(margin, this.screenWidth - this.wheelW - margin);
    }
    if (this.wheelY < margin) {
      this.wheelY = margin;
    }
    // 底部留出底栏空间
    const bottomLimit = this.screenHeight - this.wheelH - 120;
    if (this.wheelY > bottomLimit) {
      this.wheelY = Math.max(margin, bottomLimit);
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
          try {
            const connectResult = native.connect(this.deskId, this.password ?? '');
            resolve(connectResult);
          } catch (error) {
            console.error('[Session] Connect error:', error);
            resolve(-1);
          }
        }, 100);
      });

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
                VIEW.updateGeometry(undefined, undefined, stats.width, stats.height);
                this.remoteW = stats.width;
                this.remoteH = stats.height;
                this.syncView();
              }
            } catch (_error) {
            }
            this.startLogPump();
            this.nativeRef = native;
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

  private armSessionKeepAlive(): void {
    SessionKeepAlive.setActive(true, () => {
      void this.disconnect();
    });
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
    this.intentionalDisconnect = true;
    this.reconnectInFlight = false;
    this.reconnectAttempt = 0;
    this.reconnectHint = '';
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

  private syncRemoteResolution(): void {
    if (VIEW.remoteW > 0 && VIEW.remoteH > 0) {
      this.remoteW = VIEW.remoteW;
      this.remoteH = VIEW.remoteH;
    }
  }

  private containScale(): number {
    this.syncRemoteResolution();
    if (this.remoteW <= 0 || this.remoteH <= 0 || this.videoViewW <= 0 || this.videoViewH <= 0) {
      return 1;
    }
    return Math.min(this.videoViewW / this.remoteW, this.videoViewH / this.remoteH);
  }

  private zoomedW(): number {
    return this.remoteW * this.containScale() * VIEW.scale;
  }

  private zoomedH(): number {
    return this.remoteH * this.containScale() * VIEW.scale;
  }

  private zoomedX(): number {
    return (this.videoViewW - this.zoomedW()) / 2 + VIEW.panX;
  }

  private zoomedY(): number {
    return (this.videoViewH - this.zoomedH()) / 2 + VIEW.panY;
  }

  private setViewScale(scale: number): void {
    if (scale < 1) {
      scale = 1;
    }
    if (scale > 5) {
      scale = 5;
    }
    VIEW.scale = scale;
    if (VIEW.scale <= 1.01) {
      VIEW.scale = 1;
      VIEW.panX = 0;
      VIEW.panY = 0;
    } else {
      this.constrainPan();
    }
    this.syncView();
  }

  private resetView(): void {
    VIEW.scale = 1;
    VIEW.panX = 0;
    VIEW.panY = 0;
    this.syncView();
  }

  private syncView(): void {
    this.syncRemoteResolution();
    VIEW.w = this.videoViewW;
    VIEW.h = this.videoViewH;
    VIEW.remoteW = this.remoteW;
    VIEW.remoteH = this.remoteH;
    VIEW.updateGeometry(this.videoViewW, this.videoViewH, this.remoteW, this.remoteH);
  }

  private constrainPan(): void {
    const imgW = this.zoomedW();
    const imgH = this.zoomedH();
    if (imgW > this.videoViewW) {
      const limit = (imgW - this.videoViewW) / 2;
      if (VIEW.panX > limit) {
        VIEW.panX = limit;
      }
      if (VIEW.panX < -limit) {
        VIEW.panX = -limit;
      }
    } else {
      VIEW.panX = 0;
    }
    if (imgH > this.videoViewH) {
      const limit = (imgH - this.videoViewH) / 2;
      if (VIEW.panY > limit) {
        VIEW.panY = limit;
      }
      if (VIEW.panY < -limit) {
        VIEW.panY = -limit;
      }
    } else {
      VIEW.panY = 0;
    }
    this.syncView();
  }

  private cursorScreenX(): number {
    if (this.remoteW <= 0) {
      return this.videoViewW / 2;
    }
    return this.zoomedX() + this.cursorX / this.remoteW * this.zoomedW();
  }

  private cursorScreenY(): number {
    if (this.remoteH <= 0) {
      return this.videoViewH / 2;
    }
    return this.zoomedY() + this.cursorY / this.remoteH * this.zoomedH();
  }

  private clampCursor(): void {
    this.syncRemoteResolution();
    if (this.cursorX < 0) {
      this.cursorX = 0;
    }
    if (this.cursorY < 0) {
      this.cursorY = 0;
    }
    if (this.cursorX >= this.remoteW) {
      this.cursorX = this.remoteW - 1;
    }
    if (this.cursorY >= this.remoteH) {
      this.cursorY = this.remoteH - 1;
    }
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
  }

  private isOnRemoteImage(localX: number, localY: number): boolean {
    const ox = this.zoomedX();
    const oy = this.zoomedY();
    const w = this.zoomedW();
    const h = this.zoomedH();
    return localX >= ox && localX <= ox + w && localY >= oy && localY <= oy + h;
  }

  private beginTrackpadGesture(event: GestureEvent): void {
    TRACKPAD.ignoreGesture = true;
    if (this.textSelectMode || !this.virtualMouse || TRACKPAD.freezeMove) {
      mouseTrace('pan-start-ignored');
      return;
    }
    TRACKPAD.ignoreGesture = false;
    TRACKPAD.gestureStartX = TRACKPAD.cursorX;
    TRACKPAD.gestureStartY = TRACKPAD.cursorY;
    mouseTrace(`pan-origin ${TRACKPAD.gestureStartX},${TRACKPAD.gestureStartY} off=${event.offsetX},${event.offsetY}`);
  }

  private moveTrackpadGesture(offsetX: number, offsetY: number): void {
    if (this.textSelectMode || TRACKPAD.ignoreGesture || TRACKPAD.freezeMove || !this.virtualMouse || !this.nativeRef || this.videoViewW <= 0) {
      return;
    }
    this.syncRemoteResolution();
    // 触摸板灵敏度：越小越慢（约 80%）
    const speed = 0.90;
    const scale = this.remoteW / this.videoViewW * speed;
    TRACKPAD.cursorX = Math.round(TRACKPAD.gestureStartX + offsetX * scale);
    TRACKPAD.cursorY = Math.round(TRACKPAD.gestureStartY + offsetY * scale);
    this.cursorX = TRACKPAD.cursorX;
    this.cursorY = TRACKPAD.cursorY;
    this.clampCursor();
    TRACKPAD.cursorX = this.cursorX;
    TRACKPAD.cursorY = this.cursorY;
    if (Math.abs(offsetX) + Math.abs(offsetY) > 10) {
      this.touchMoved = true;
      this.clearRightClickTimer();
    }
    mouseTrace(`pan-move off=${offsetX.toFixed(1)},${offsetY.toFixed(1)} scale=${scale.toFixed(3)} send=${this.cursorX},${this.cursorY}`);
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
  }

  private mapToRemote(localX: number, localY: number): number[] | null {
    const w = this.zoomedW();
    const h = this.zoomedH();
    if (w <= 0 || h <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return null;
    }
    if (!this.isOnRemoteImage(localX, localY)) {
      mouseTrace(`abs-outside ${localX},${localY}`);
      return null;
    }
    let x = Math.round((localX - this.zoomedX()) / w * this.remoteW);
    let y = Math.round((localY - this.zoomedY()) / h * this.remoteH);
    if (x < 0) {
      x = 0;
    }
    if (y < 0) {
      y = 0;
    }
    if (x >= this.remoteW) {
      x = this.remoteW - 1;
    }
    if (y >= this.remoteH) {
      y = this.remoteH - 1;
    }
    return [x, y];
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
    // 先同步当前光标，再发滚轮，对方会在光标位置滚动
    this.nativeRef.sendMouseMove(this.cursorX, this.cursorY);
    this.nativeRef.sendMouseWheel(deltaY);
    DEBUG.note(`scroll dy=${deltaY}`);
  }

  private sendRightButton(pressed: boolean): void {
    if (this.viewOnly || !this.isConnected || !this.nativeRef) {
      return;
    }
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
    if (VIEW.scale < 2.4) {
      VIEW.scale = 2.4;
    }
    const imgW = this.zoomedW();
    const imgH = this.zoomedH();
    VIEW.panX = imgW / 2 - this.cursorX / this.remoteW * imgW;
    VIEW.panY = imgH / 2 - this.cursorY / this.remoteH * imgH;
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
    if (this.videoViewW <= 0 || this.videoViewH <= 0) {
      return;
    }
    this.syncRemoteResolution();
    const speed = 0.90;
    this.cursorX = Math.round(this.cursorX + dx / this.videoViewW * this.remoteW * speed);
    this.cursorY = Math.round(this.cursorY + dy / this.videoViewH * this.remoteH * speed);
    this.clampCursor();
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
    const point = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
    if (!point) {
      return;
    }
    const mapped = this.mapToRemote(point.x, point.y);
    if (!mapped) {
      return;
    }
    const x = mapped[0];
    const y = mapped[1];
    if (!this.firstTouchLogged) {
      this.firstTouchLogged = true;
      this.addLog(`已发送鼠标 ${x},${y}`);
    }
    if (event.type === TouchType.Down) {
      this.touchDragging = false;
      this.touchMoved = false;
      this.rightClicked = false;
      this.touchStartX = x;
      this.touchStartY = y;
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
      this.nativeRef.sendMouseMove(x, y);
      if (this.rightClicked) {
        // already sent right click
      } else if (this.touchDragging) {
        this.nativeRef.sendMouseClick(0, false);
      } else {
        this.nativeRef.sendMouseClick(0, true);
        this.nativeRef.sendMouseClick(0, false);
      }
      this.touchDragging = false;
      this.touchMoved = false;
      this.rightClicked = false;
    }
  }

  private toggleTextSelectMode(): void {
    this.textSelectMode = !this.textSelectMode;
    if (this.textSelectMode) {
      this.showKeyboard = false;
      DEBUG.note('选字模式：拖选文字，用底部快捷条复制');
    }
  }

  private sendCtrlLetter(letter: string): void {
    if (!this.nativeRef || this.viewOnly || letter.length === 0) {
      return;
    }
    const ch = letter.toLowerCase().charCodeAt(0);
    // ControlKey::Control = 4
    this.nativeRef.sendChord(ch, 4);
    DEBUG.note(`chord Ctrl+${letter}`);
  }
}
