// Targeted physical-key forwarding tests. Device IME behavior still needs UAT.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./harmony-test-sdk.cjs').typescript();

const servicePath = path.join(__dirname,
  '../ohos/entry/src/main/ets/services/HardwareKeyboard.ets');
const source = fs.readFileSync(servicePath, 'utf8')
  .replace(/^import .*;$/mg, '')
  .replace('export class HardwareKeyboard', 'class HardwareKeyboard');
const js = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;

const sdkKeyCodesPath = require('./harmony-test-sdk.cjs').keyCodes();
const sdkKeyCodes = fs.readFileSync(sdkKeyCodesPath, 'utf8');
const testSource = fs.readFileSync(__filename, 'utf8');
const names = [...new Set([
  ...source.matchAll(/KeyCode\.(KEYCODE_[A-Z0-9_]+)/g),
  ...testSource.matchAll(/\b(?:K|KeyCode)\.(KEYCODE_[A-Z0-9_]+)/g)
].map(match => match[1]))];
const KeyCode = {};
for (const name of names) {
  const match = sdkKeyCodes.match(new RegExp(`^\\s*${name}\\s*=\\s*(\\d+),`, 'm'));
  assert.ok(match, `SDK KeyCode enum must define ${name}`);
  KeyCode[name] = Number(match[1]);
}

function fixture() {
  const state = { sent: [] };
  const native = {
    sendHardwareKey(kind, code, down, modifiers) {
      state.sent.push({ kind, code, down, modifiers: Array.from(modifiers) });
    }
  };
  const sandbox = { KeyCode };
  vm.runInNewContext(js + '; this.HardwareKeyboard = HardwareKeyboard;', sandbox);
  return { bridge: new sandbox.HardwareKeyboard(native), state };
}

const f = fixture();
const { bridge, state } = f;
const K = KeyCode;

for (const code of [K.KEYCODE_A, K.KEYCODE_0, K.KEYCODE_PERIOD, K.KEYCODE_SPACE,
  K.KEYCODE_ENTER, K.KEYCODE_DEL, K.KEYCODE_DPAD_LEFT, K.KEYCODE_ESCAPE,
  K.KEYCODE_SHIFT_LEFT, K.KEYCODE_CAPS_LOCK, K.KEYCODE_NUMPAD_1,
  K.KEYCODE_NUMPAD_DOT, K.KEYCODE_NUMPAD_ADD, K.KEYCODE_POUND,
  K.KEYCODE_STAR, K.KEYCODE_PLUS, K.KEYCODE_NUMPAD_PLUSMINUS]) {
  assert.equal(bridge.shouldUseIme(code), true, `IME candidate ${code}`);
}
assert.equal(bridge.shouldUseIme(K.KEYCODE_F1), false);
assert.equal(bridge.shouldUseIme(K.KEYCODE_CTRL_LEFT), false);
assert.equal(bridge.isShiftKey(K.KEYCODE_SHIFT_LEFT), true);
assert.equal(bridge.isShiftKey(K.KEYCODE_SHIFT_RIGHT), true);

// OS-provided keyText preserves the active layout and capitalization.
assert.equal(bridge.handle(K.KEYCODE_CTRL_LEFT, '', true, [4]), true);
assert.equal(bridge.hasShortcutModifier(), true);
assert.equal(bridge.shouldUseIme(K.KEYCODE_A), false, 'Ctrl routes text keys as shortcuts');
assert.equal(bridge.handle(K.KEYCODE_SHIFT_RIGHT, '', true, [4, 73]), true);
assert.equal(bridge.handle(K.KEYCODE_C, 'C', true, [4, 73]), true);
assert.deepEqual(state.sent.at(-1), { kind: 1, code: 67, down: true, modifiers: [4, 73] });
assert.equal(bridge.isPressed(K.KEYCODE_C), true);
const beforeRepeat = state.sent.length;
bridge.handle(K.KEYCODE_C, 'C', true, [4, 73]);
assert.equal(state.sent.length, beforeRepeat + 1, 'character repeat emits another down');
bridge.handle(K.KEYCODE_C, '', false, [4, 73]);
assert.deepEqual(state.sent.at(-1), { kind: 1, code: 67, down: false, modifiers: [4, 73] },
  'keyup reuses the down mapping when OS keyText is empty');
bridge.handle(K.KEYCODE_SHIFT_RIGHT, '', false, [4, 73]);
assert.deepEqual(state.sent.at(-1).modifiers, [4], 'released Shift is removed from a stale snapshot');
bridge.handle(K.KEYCODE_CTRL_LEFT, '', false, [4]);
assert.deepEqual(state.sent.at(-1).modifiers, [], 'released Ctrl is removed from a stale snapshot');
assert.equal(bridge.hasShortcutModifier(), false);

// Modifier repeats must not add duplicate native downs; held keys release on blur.
const modifierBeforeRepeat = state.sent.length;
bridge.handle(K.KEYCODE_CTRL_LEFT, '', true, [4]);
bridge.handle(K.KEYCODE_CTRL_LEFT, '', true, [4]);
assert.equal(state.sent.length, modifierBeforeRepeat + 1);
bridge.handle(K.KEYCODE_SHIFT_LEFT, '', true, [4, 29]);
bridge.handle(K.KEYCODE_A, 'a', true, [4, 29]);
assert.equal(bridge.isPressed(K.KEYCODE_A), true);
bridge.releaseAll();
assert.equal(bridge.isPressed(K.KEYCODE_A), false);
assert.equal(bridge.isPressed(K.KEYCODE_CTRL_LEFT), false);
assert.equal(bridge.hasShortcutModifier(), false);
assert.deepEqual(state.sent.at(-1).modifiers, [], 'blur releases modifiers completely');

// OHOS keyText handles keyboard layouts; the fallback covers physical US symbols and Caps/Shift.
assert.equal(bridge.handle(K.KEYCODE_A, 'é', true), true);
assert.equal(state.sent.at(-1).code, 0xE9);
bridge.handle(K.KEYCODE_A, '', false);
assert.equal(bridge.handle(K.KEYCODE_0, '', true, [29]), true);
assert.equal(state.sent.at(-1).code, ')'.charCodeAt(0), 'Shift+0 maps to )');
bridge.handle(K.KEYCODE_0, '', false, [29]);
assert.equal(bridge.handle(K.KEYCODE_SLASH, '', true, [29]), true);
assert.equal(state.sent.at(-1).code, '?'.charCodeAt(0));
bridge.handle(K.KEYCODE_SLASH, '', false, [29]);
assert.equal(bridge.handle(K.KEYCODE_A, '', true, [], true), true);
assert.equal(state.sent.at(-1).code, 'A'.charCodeAt(0), 'Caps Lock transforms fallback letter');
assert.ok(state.sent.at(-1).modifiers.includes(3), 'Caps Lock state is in the key modifier list');
bridge.handle(K.KEYCODE_A, '', false, [], true);
for (const [osCode, text] of [[K.KEYCODE_POUND, '#'], [K.KEYCODE_STAR, '*'],
  [K.KEYCODE_PLUS, '+'], [K.KEYCODE_NUMPAD_LEFT_PAREN, '('],
  [K.KEYCODE_NUMPAD_RIGHT_PAREN, ')'], [K.KEYCODE_NUMPAD_PLUSMINUS, '±']]) {
  assert.equal(bridge.handle(osCode, '', true), true);
  assert.equal(state.sent.at(-1).code, text.codePointAt(0), `fallback for ${text}`);
  bridge.handle(osCode, '', false);
}

// Common control keys map through the verified RustDesk ControlKey enum.
const controls = [
  [K.KEYCODE_DEL, 2], [K.KEYCODE_FORWARD_DEL, 5], [K.KEYCODE_DPAD_UP, 32],
  [K.KEYCODE_DPAD_RIGHT, 28], [K.KEYCODE_MOVE_HOME, 21], [K.KEYCODE_MOVE_END, 7],
  [K.KEYCODE_ENTER, 27], [K.KEYCODE_NUMPAD_ENTER, 72], [K.KEYCODE_NUMPAD_0, 33],
  [K.KEYCODE_NUMPAD_9, 42], [K.KEYCODE_NUMPAD_DIVIDE, 70], [K.KEYCODE_NUMPAD_MULTIPLY, 66],
  [K.KEYCODE_NUMPAD_SUBTRACT, 68], [K.KEYCODE_NUMPAD_ADD, 67], [K.KEYCODE_NUMPAD_DOT, 69],
  [K.KEYCODE_NUMPAD_COMMA, 61], [K.KEYCODE_NUMPAD_EQUALS, 71], [K.KEYCODE_F1, 9],
  [K.KEYCODE_F10, 10], [K.KEYCODE_F12, 12], [K.KEYCODE_META_RIGHT, 64]
];
for (const [osCode, rustDeskCode] of controls) {
  const before = state.sent.length;
  assert.equal(bridge.handle(osCode, '', true), true);
  assert.deepEqual(state.sent[before], {
    kind: 2, code: rustDeskCode, down: true, modifiers: rustDeskCode === 64 ? [64] : []
  });
  assert.equal(bridge.handle(osCode, '', false), true);
}

assert.equal(bridge.handle(K.KEYCODE_NUM_LOCK, '', true, [], false, true), true);
assert.deepEqual(state.sent.at(-1), { kind: 2, code: 63, down: true, modifiers: [63] },
  'NumLock is forwarded as a lock state, not a mouse/shortcut modifier');
bridge.handle(K.KEYCODE_NUM_LOCK, '', false, [], false, true);
assert.deepEqual(state.sent.at(-1).modifiers, [63]);

assert.equal(bridge.handle(999999, '', true), false, 'unknown key codes are left unhandled');
// Focus can be gained while Ctrl is already down: no Ctrl keydown was delivered
// to this surface, but its observed modifier must still be released on blur.
const observedOnly = fixture();
observedOnly.bridge.handle(K.KEYCODE_C, 'c', true, [4]);
observedOnly.bridge.handle(K.KEYCODE_C, 'c', false, [4]);
observedOnly.bridge.releaseAll();
assert.deepEqual(observedOnly.state.sent.at(-1), { kind: 2, code: 4, down: false, modifiers: [] });
const releasedCount = observedOnly.state.sent.length;
observedOnly.bridge.releaseAll();
assert.equal(observedOnly.state.sent.length, releasedCount, 'repeated blur is idempotent');
console.log('PASS: IME routing, layout text, modifiers/repeats, focus release, controls, keypad and function keys');
