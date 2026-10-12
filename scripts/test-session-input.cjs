// Targeted event-routing tests. Execute production handlers with mocked OS/native
// boundaries; device event dispatch and IME behavior still need device acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./harmony-test-sdk.cjs').typescript();
const root = path.join(__dirname, '../ohos/entry/src/main/ets');
const session = fs.readFileSync(path.join(root, 'pages/Session.ets'), 'utf8');
const pointer = fs.readFileSync(path.join(root, 'services/HardwarePointer.ets'), 'utf8')
  .replace(/^import .*;\r?\n/mg, '').replace(/export class /g, 'class ');
const geometry = session.slice(session.indexOf('class TrackpadLogic {'), session.indexOf('const TRACKPAD ='))
  .replace(/export /g, '');
const names = ['inputReady', 'cancelDirectTouch', 'releaseFloatingButtons', 'releaseRemoteInput',
  'handleHardwareMouse', 'handleHardwareWheel', 'handleFloatingWheel', 'handleHardwareKey', 'handleRemoteTouch', 'touchPoint'];
// All selected handlers are regular ArkTS methods (no declarative UI DSL).
const methods = names.map(name => {
  const start = session.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  let end = session.indexOf('\n  private ', start + 1);
  return session.slice(start, end);
}).join('\n');
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const MouseAction = { Press: 1, Release: 2, Move: 3 };
const MouseButton = { Left: 1, Right: 2, Middle: 4, None: 0 };
const SourceType = { TouchScreen: 1, Mouse: 2 };
const sandbox = { console, TouchType, MouseAction, MouseButton, SourceType,
  KeyCode: { KEYCODE_SHIFT_LEFT: 2047, KEYCODE_SHIFT_RIGHT: 2048 },
  KeyType: { Down: 0, Up: 1 }, AxisAction: { CANCEL: 4 },
  TRACKPAD: {}, DEBUG: { note() {} }, mouseTrace() {},
  setTimeout: () => 1, clearTimeout() {} };
vm.runInNewContext(ts.transpileModule(geometry + pointer + '\nclass SessionHandlers {\n' + methods +
  '\n}\nthis.Pointer = HardwarePointer; this.Wheel = WheelAccumulator; this.Handlers = SessionHandlers;' +
  '\nthis.Geometry = ViewBox; this.geometrySanity = runGeometrySanityChecks;',
  { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);

function fixture() {
  const calls = [];
  const native = {
    sendMouseMove: (...args) => calls.push(['move', ...args]),
    sendMouseClick: (...args) => calls.push(['button', ...args]),
    sendMouseWheel: (...args) => calls.push(['wheel', ...args])
  };
  const ctx = Object.assign(new sandbox.Handlers(), {
    nativeRef: native, isConnected: true, viewOnly: false, windowInputActive: true,
    remoteInputFocused: true, hardwarePointer: null, hardwareKeyboard: null,
    floatingButtons: 0, rightDown: false, touchActive: false, touchDragging: false,
    touchMoved: false, rightClicked: false, pinching: false, firstTouchLogged: true,
    longPressTimer: -1, virtualMouse: true, textSelectMode: false,
    cursorX: 0, cursorY: 0,
    mapToRemote: (x, y) => x < 0 || y < 0 ? null : [x * 2, y * 2],
    clearRightClickTimer() { this.longPressTimer = -1; },
    focusRemoteInput() { this.remoteInputFocused = true; }, addLog() {}
  });
  return { calls, ctx, native };
}
function touch(type, x = 20, y = 30, extra = {}) {
  return { type, source: SourceType.TouchScreen,
    changedTouches: [{ x, y }], touches: [{ x, y }], ...extra };
}
function mouse(action, button = MouseButton.Left, x = 20, y = 30) {
  return { action, button, x, y, stopPropagation() {} };
}
assert.equal(sandbox.geometrySanity(), true);
{
  const { ctx, calls } = fixture();
  const view = new sandbox.Geometry(); view.updateGeometry(1280, 800, 1920, 1080);
  ctx.mapToRemote = (x, y) => view.screenToRemote(x, y);
  ctx.handleHardwareMouse(mouse(MouseAction.Press, MouseButton.Left, 640, 20));
  assert.deepEqual(calls, []); // FIT letterbox, tested against the real geometry implementation.
  ctx.handleHardwareMouse(mouse(MouseAction.Press, MouseButton.Left, 640, 400));
  assert.deepEqual(calls, [['move', 960, 540], ['button', 0, true]]);
}
{
  const w = new sandbox.Wheel();
  assert.equal(w.move(5), 0); assert.equal(w.move(5), 0); assert.equal(w.move(5), -1);
  assert.equal(w.move(-30), 2); assert.equal(w.move(NaN), 0);
  w.move(5); w.reset(); assert.equal(w.move(10), 0);
}
{
  const { ctx, calls } = fixture();
  ctx.handleHardwareMouse(mouse(MouseAction.Move, MouseButton.None));
  ctx.handleHardwareMouse(mouse(MouseAction.Press));
  ctx.handleRemoteTouch(touch(TouchType.Down, 20, 30, { source: SourceType.Mouse }));
  ctx.handleRemoteTouch(touch(TouchType.Up, 20, 30, { source: SourceType.Mouse }));
  ctx.handleHardwareMouse(mouse(MouseAction.Release, MouseButton.Left, -1, -1));
  assert.deepEqual(calls.filter(c => c[0] === 'button'), [['button', 0, true], ['button', 0, false]]);
  assert.equal(ctx.cursorX, 40); assert.equal(ctx.cursorY, 60);
}
for (const virtualMouse of [false, true]) {
  const { ctx, calls } = fixture(); ctx.virtualMouse = virtualMouse;
  ctx.handleRemoteTouch(touch(TouchType.Down)); ctx.handleRemoteTouch(touch(TouchType.Up));
  assert.deepEqual(calls.filter(c => c[0] === 'button'), [['button', 0, true], ['button', 0, false]]);
}
{
  const { ctx, calls } = fixture();
  ctx.handleRemoteTouch(touch(TouchType.Down)); ctx.handleRemoteTouch(touch(TouchType.Move, 50, 50));
  ctx.handleRemoteTouch(touch(TouchType.Cancel, 0, 0, { changedTouches: [], touches: [] }));
  assert.deepEqual(calls.filter(c => c[0] === 'button'), [['button', 0, true], ['button', 0, false]]);
  assert.equal(ctx.touchActive, false);
}
{
  const { ctx, calls } = fixture();
  ctx.handleRemoteTouch(touch(TouchType.Down)); ctx.handleRemoteTouch(touch(TouchType.Move, 50, 50));
  ctx.handleRemoteTouch(touch(TouchType.Move, 50, 50, { touches: [{}, {}] }));
  ctx.handleRemoteTouch(touch(TouchType.Up));
  assert.deepEqual(calls.filter(c => c[0] === 'button'), [['button', 0, true], ['button', 0, false]]);
}
{
  const { ctx, calls } = fixture();
  ctx.handleRemoteTouch(touch(TouchType.Down, -1, -1)); ctx.handleRemoteTouch(touch(TouchType.Up));
  assert.deepEqual(calls, []); // A contact starting in a black bar cannot become a click.
  ctx.viewOnly = true;
  ctx.handleHardwareMouse(mouse(MouseAction.Press));
  ctx.handleHardwareWheel({ action: 2, x: 20, y: 30, getVerticalAxisValue: () => 15 });
  ctx.handleRemoteTouch(touch(TouchType.Down)); assert.deepEqual(calls, []);
}
{
  const { ctx, calls } = fixture();
  ctx.handleHardwareWheel({ action: 2, x: 20, y: 30, getVerticalAxisValue: () => 15 });
  assert.deepEqual(calls, [['move', 40, 60], ['wheel', -1]]);
  ctx.handleFloatingWheel(-30);
  assert.deepEqual(calls.slice(-2), [['move', 40, 60], ['wheel', 2]]);
  ctx.handleHardwareMouse(mouse(MouseAction.Press, MouseButton.Right));
  ctx.releaseRemoteInput(); ctx.releaseRemoteInput();
  assert.deepEqual(calls.filter(c => c[0] === 'button'), [['button', 2, true], ['button', 2, false]]);
}
{
  const { ctx, calls } = fixture();
  ctx.handleRemoteTouch(touch(TouchType.Down)); ctx.handleRemoteTouch(touch(TouchType.Move, 50, 50));
  ctx.handleHardwareMouse(mouse(MouseAction.Press, MouseButton.Right));
  ctx.handleRemoteTouch(touch(TouchType.Up)); ctx.releaseRemoteInput();
  assert.deepEqual(calls.filter(c => c[0] === 'button'),
    [['button', 0, true], ['button', 0, false], ['button', 2, true], ['button', 2, false]]);
}
{
  const { ctx } = fixture(); const routed = [];
  ctx.imeAttached = true;
  ctx.hardwareKeyboard = { isPressed: code => code === 2017, hasShortcutModifier: () => false,
    shouldUseIme: () => true, handle: (...args) => { routed.push(args); return true; } };
  assert.equal(ctx.handleHardwareKey({ type: 0, keyCode: 2018, keyText: 'b' }), false);
  assert.equal(ctx.handleHardwareKey({ type: 0, keyCode: 2018, keyText: 'b' }, true), true);
  assert.equal(ctx.handleHardwareKey({ type: 1, keyCode: 2017, keyText: 'a' }), true);
  assert.equal(routed.length, 2); // unconsumed IME key and keyup of a forwarded chord.
  ctx.handleHardwareKey({ type: 0, keyCode: 2047, keyText: 'Shift' });
  ctx.handleHardwareKey({ type: 0, keyCode: 2047, keyText: 'Shift' }, true);
  assert.equal(routed.length, 3); // Shift is mirrored once, but allowed into the IME.
  ctx.remoteInputFocused = false;
  assert.equal(ctx.handleHardwareKey({ type: 0, keyCode: 2017, keyText: 'a' }), false);
}
assert.ok(session.includes(".onAxisEvent((event: AxisEvent) => this.handleHardwareWheel(event))"));
assert.ok(!session.includes('this.handleTrackpadPress(event'));
assert.ok(session.includes('if (this.remoteInputFocused && !this.viewOnly)'));
console.log('PASS: pointer, wheel, input routing, touch/panel coexistence, cancel, readonly, focus and IME ownership');
