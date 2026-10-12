// Execute the production TypeBar IME lifecycle without ArkUI rendering.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./harmony-test-sdk.cjs').typescript();
const source = fs.readFileSync(path.join(__dirname, '../ohos/entry/src/main/ets/pages/Session.ets'), 'utf8');
const start = source.indexOf('struct TypeBar {');
const end = source.indexOf('  build() {', start);
const code = 'let remoteImeQueue: Promise<void> = Promise.resolve();\n' +
  source.slice(start, end).replace('struct TypeBar', 'class TypeBar')
    .replace(/@Prop\s+@Watch\('[^']+'\)\s+/g, '') + '}\nthis.Bar = TypeBar;';
const calls = [], handlers = new Map();
const controller = {
  attach: async (show, config) => { calls.push(['attach', show, config.windowId]); },
  detach: async () => { calls.push(['detach']); },
  on: (event, handler) => handlers.set(event, handler),
  off: (event, handler) => { if (handlers.get(event) === handler) handlers.delete(event); },
  showTextInput: async () => { calls.push(['show']); },
  hideTextInput: async () => { calls.push(['hide']); }
};
const sandbox = { console, getContext: () => ({}), window: {
  getLastWindow: async () => ({ getWindowProperties: () => ({ id: 42 }) })
}, inputMethod: {
  getController: () => controller, TextInputType: { TEXT: 0 }, EnterKeyType: { NEWLINE: 0 },
  KeyboardStatus: { SHOW: 1, HIDE: 0 }
}};
vm.runInNewContext(ts.transpileModule(code,
  { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  const text = [], control = [], readiness = [];
  const bar = new sandbox.Bar();
  bar.onSend = value => text.push(value); bar.onControl = value => control.push(value);
  bar.onReady = value => readiness.push(value);
  bar.aboutToAppear(); await flush();
  assert.deepEqual(calls, [['attach', false, 42]]); // hardware typing needs no soft panel
  assert.deepEqual(readiness, [true]);
  handlers.get('insertText')('中文 abc');
  handlers.get('deleteLeft')(2); handlers.get('moveCursor')(3); handlers.get('sendFunctionKey')({});
  assert.deepEqual(text, ['中文 abc']);
  assert.deepEqual(control, [2, 2, 22, 27]);
  bar.showSoftKeyboard = true; bar.updateSoftKeyboard(); await flush();
  bar.showSoftKeyboard = false; bar.updateSoftKeyboard(); await flush();
  assert.deepEqual(calls.slice(1), [['show'], ['hide']]); // hide must not detach hardware IME
  const lateInsert = handlers.get('insertText');
  bar.aboutToDisappear(); lateInsert('must not reach remote');
  const next = new sandbox.Bar(); next.aboutToAppear(); await flush();
  assert.deepEqual(text, ['中文 abc']);
  assert.deepEqual(calls.slice(-2), [['detach'], ['attach', false, 42]]);
  assert.equal(handlers.size, 9);
  next.aboutToDisappear(); await flush(); assert.equal(handlers.size, 0);
  console.log('PASS: hidden IME, text/control routing, soft-panel toggle, stale callbacks and serialized reattach');
})().catch(error => { console.error(error); process.exitCode = 1; });
