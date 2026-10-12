import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { HarmonyDeskNative } from '../native/HarmonyDeskNative';

const HARDWARE_KEY_CHAR: number = 1;
const HARDWARE_KEY_CONTROL: number = 2;

// Values are RustDesk's ControlKey enum values from hbb_common/protos/message.proto.
const CONTROL_ALT: number = 1;
const CONTROL_BACKSPACE: number = 2;
const CONTROL_CAPS_LOCK: number = 3;
const CONTROL_CONTROL: number = 4;
const CONTROL_DELETE: number = 5;
const CONTROL_DOWN: number = 6;
const CONTROL_END: number = 7;
const CONTROL_ESCAPE: number = 8;
const CONTROL_NUMPAD_ENTER: number = 72;
const CONTROL_F1: number = 9;
const CONTROL_F10: number = 10;
const CONTROL_F11: number = 11;
const CONTROL_F12: number = 12;
const CONTROL_F2: number = 13;
const CONTROL_F3: number = 14;
const CONTROL_F4: number = 15;
const CONTROL_F5: number = 16;
const CONTROL_F6: number = 17;
const CONTROL_F7: number = 18;
const CONTROL_F8: number = 19;
const CONTROL_F9: number = 20;
const CONTROL_HOME: number = 21;
const CONTROL_LEFT: number = 22;
const CONTROL_META: number = 23;
const CONTROL_PAGE_DOWN: number = 25;
const CONTROL_PAGE_UP: number = 26;
const CONTROL_RETURN: number = 27;
const CONTROL_RIGHT: number = 28;
const CONTROL_SHIFT: number = 29;
const CONTROL_SPACE: number = 30;
const CONTROL_TAB: number = 31;
const CONTROL_UP: number = 32;
const CONTROL_NUMPAD_0: number = 33;
const CONTROL_NUMPAD_SEPARATOR: number = 61;
const CONTROL_INSERT: number = 58;
const CONTROL_SCROLL_LOCK: number = 62;
const CONTROL_NUM_LOCK: number = 63;
const CONTROL_RWIN: number = 64;
const CONTROL_NUMPAD_MULTIPLY: number = 66;
const CONTROL_NUMPAD_ADD: number = 67;
const CONTROL_NUMPAD_SUBTRACT: number = 68;
const CONTROL_NUMPAD_DECIMAL: number = 69;
const CONTROL_NUMPAD_DIVIDE: number = 70;
const CONTROL_NUMPAD_EQUALS: number = 71;
const CONTROL_RSHIFT: number = 73;
const CONTROL_RCONTROL: number = 74;
const CONTROL_RALT: number = 75;

interface HardwareKeyBinding {
  kind: number;
  code: number;
  modifier: number;
}

/** Forwards physical keyboard events while leaving ordinary composition to the system IME. */
export class HardwareKeyboard {
  private native: HarmonyDeskNative;
  private pressed: Map<number, HardwareKeyBinding> = new Map<number, HardwareKeyBinding>();
  private capsLockOn: boolean = false;
  private numLockOn: boolean = false;
  private lastModifiers: number[] = [];

  constructor(native: HarmonyDeskNative) {
    this.native = native;
  }

  /** True for keys that should remain available to an attached IME when no shortcut is held. */
  shouldUseIme(code: number): boolean {
    if (this.hasShortcutModifier()) {
      return false;
    }
    return this.isImeCandidateKey(code);
  }

  /** True while a Ctrl, Alt, or Meta key handled by this service remains down. */
  hasShortcutModifier(): boolean {
    for (const binding of this.pressed.values()) {
      if (this.isShortcutModifier(binding.modifier)) {
        return true;
      }
    }
    return false;
  }

  /** True when this service accepted the matching key-down and still owes its key-up. */
  isPressed(code: number): boolean {
    return this.pressed.has(code);
  }

  isShiftKey(code: number): boolean {
    return code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT;
  }

  /**
   * Forward a key transition. `activeModifiers` contains RustDesk ControlKey values
   * observed from the current OHOS event; the locally tracked keys fill in transitions
   * that OHOS reports before or after the changed key.
   */
  handle(code: number, text: string, down: boolean, activeModifiers: number[] = [],
    capsLockOn: boolean = false, numLockOn: boolean = false): boolean {
    this.capsLockOn = capsLockOn;
    this.numLockOn = numLockOn;
    let binding = this.pressed.get(code);
    if (!down) {
      if (binding === undefined) {
        return false;
      }
      this.pressed.delete(code);
    } else {
      if (binding === undefined) {
        binding = this.mapKey(code, text, activeModifiers, capsLockOn);
        if (binding === undefined) {
          return false;
        }
        this.pressed.set(code, binding);
      } else if (binding.modifier !== 0) {
        // Modifier auto-repeat must not increase the RustDesk held-key count.
        return true;
      }
    }

    if (binding === undefined) {
      return false;
    }
    const modifiers = this.collectModifiers(activeModifiers, down ? 0 : binding.modifier, capsLockOn, numLockOn);
    this.lastModifiers = modifiers.slice();
    this.native.sendHardwareKey(binding.kind, binding.code, down, modifiers);
    return true;
  }

  /** Release every forwarded key, with ordinary keys released before modifiers. */
  releaseAll(): void {
    const keys: Array<[number, HardwareKeyBinding]> = Array.from(this.pressed.entries());
    keys.sort((left, right) => Number(left[1].modifier !== 0) - Number(right[1].modifier !== 0));
    const capsLockOn = this.capsLockOn;
    const numLockOn = this.numLockOn;
    const observed = this.lastModifiers.slice();
    for (const entry of keys) {
      this.handle(entry[0], '', false, [], capsLockOn, numLockOn);
    }
    // A modifier may already have been down before this surface gained focus.
    // Its snapshot still reached the peer even though we never saw its keydown.
    for (const modifier of observed) {
      if (modifier === CONTROL_CAPS_LOCK || modifier === CONTROL_NUM_LOCK) { continue; }
      if (!keys.some((entry: [number, HardwareKeyBinding]) => entry[1].code === modifier)) {
        this.native.sendHardwareKey(HARDWARE_KEY_CONTROL, modifier, false, []);
      }
    }
    this.lastModifiers = [];
  }

  private isImeCandidateKey(code: number): boolean {
    if (this.isShiftKey(code) || code === KeyCode.KEYCODE_CAPS_LOCK) {
      return true;
    }
    if (this.isPrintableKey(code)) {
      return true;
    }
    return code === KeyCode.KEYCODE_ENTER || code === KeyCode.KEYCODE_NUMPAD_ENTER ||
      code === KeyCode.KEYCODE_DEL || code === KeyCode.KEYCODE_FORWARD_DEL ||
      code === KeyCode.KEYCODE_DPAD_UP || code === KeyCode.KEYCODE_DPAD_DOWN ||
      code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_RIGHT ||
      code === KeyCode.KEYCODE_MOVE_HOME || code === KeyCode.KEYCODE_MOVE_END ||
      code === KeyCode.KEYCODE_PAGE_UP || code === KeyCode.KEYCODE_PAGE_DOWN ||
      code === KeyCode.KEYCODE_TAB || code === KeyCode.KEYCODE_ESCAPE;
  }

  private isPrintableKey(code: number): boolean {
    return (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) ||
      (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) ||
      (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_9) ||
      code === KeyCode.KEYCODE_NUMPAD_DIVIDE || code === KeyCode.KEYCODE_NUMPAD_MULTIPLY ||
      code === KeyCode.KEYCODE_NUMPAD_SUBTRACT || code === KeyCode.KEYCODE_NUMPAD_ADD ||
      code === KeyCode.KEYCODE_NUMPAD_DOT || code === KeyCode.KEYCODE_NUMPAD_COMMA ||
      code === KeyCode.KEYCODE_NUMPAD_EQUALS || code === KeyCode.KEYCODE_NUMPAD_PLUSMINUS ||
      code === KeyCode.KEYCODE_SPACE || code === KeyCode.KEYCODE_GRAVE ||
      code === KeyCode.KEYCODE_MINUS || code === KeyCode.KEYCODE_EQUALS ||
      code === KeyCode.KEYCODE_LEFT_BRACKET || code === KeyCode.KEYCODE_RIGHT_BRACKET ||
      code === KeyCode.KEYCODE_BACKSLASH || code === KeyCode.KEYCODE_SEMICOLON ||
      code === KeyCode.KEYCODE_APOSTROPHE || code === KeyCode.KEYCODE_COMMA ||
      code === KeyCode.KEYCODE_PERIOD || code === KeyCode.KEYCODE_SLASH ||
      code === KeyCode.KEYCODE_AT || code === KeyCode.KEYCODE_POUND ||
      code === KeyCode.KEYCODE_STAR || code === KeyCode.KEYCODE_PLUS ||
      code === KeyCode.KEYCODE_NUMPAD_LEFT_PAREN ||
      code === KeyCode.KEYCODE_NUMPAD_RIGHT_PAREN;
  }

  private mapKey(code: number, text: string, activeModifiers: number[], capsLockOn: boolean): HardwareKeyBinding | undefined {
    const control = this.mapControlKey(code);
    if (control !== 0) {
      return { kind: HARDWARE_KEY_CONTROL, code: control, modifier: this.asModifier(control) };
    }
    if (!this.isPrintableKey(code)) {
      return undefined;
    }
    const value = this.resolveCharacter(code, text, activeModifiers, capsLockOn);
    if (value === 0) {
      return undefined;
    }
    return { kind: HARDWARE_KEY_CHAR, code: value, modifier: 0 };
  }

  private mapControlKey(code: number): number {
    if (code === KeyCode.KEYCODE_CTRL_LEFT) return CONTROL_CONTROL;
    if (code === KeyCode.KEYCODE_CTRL_RIGHT) return CONTROL_RCONTROL;
    if (code === KeyCode.KEYCODE_ALT_LEFT) return CONTROL_ALT;
    if (code === KeyCode.KEYCODE_ALT_RIGHT) return CONTROL_RALT;
    if (code === KeyCode.KEYCODE_SHIFT_LEFT) return CONTROL_SHIFT;
    if (code === KeyCode.KEYCODE_SHIFT_RIGHT) return CONTROL_RSHIFT;
    if (code === KeyCode.KEYCODE_META_LEFT) return CONTROL_META;
    if (code === KeyCode.KEYCODE_META_RIGHT) return CONTROL_RWIN;
    if (code === KeyCode.KEYCODE_CAPS_LOCK) return CONTROL_CAPS_LOCK;
    if (code === KeyCode.KEYCODE_DEL) return CONTROL_BACKSPACE;
    if (code === KeyCode.KEYCODE_FORWARD_DEL) return CONTROL_DELETE;
    if (code === KeyCode.KEYCODE_DPAD_DOWN) return CONTROL_DOWN;
    if (code === KeyCode.KEYCODE_DPAD_UP) return CONTROL_UP;
    if (code === KeyCode.KEYCODE_DPAD_LEFT) return CONTROL_LEFT;
    if (code === KeyCode.KEYCODE_DPAD_RIGHT) return CONTROL_RIGHT;
    if (code === KeyCode.KEYCODE_MOVE_HOME) return CONTROL_HOME;
    if (code === KeyCode.KEYCODE_MOVE_END) return CONTROL_END;
    if (code === KeyCode.KEYCODE_PAGE_DOWN) return CONTROL_PAGE_DOWN;
    if (code === KeyCode.KEYCODE_PAGE_UP) return CONTROL_PAGE_UP;
    if (code === KeyCode.KEYCODE_ENTER) return CONTROL_RETURN;
    if (code === KeyCode.KEYCODE_NUMPAD_ENTER) return CONTROL_NUMPAD_ENTER;
    if (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_9) {
      return CONTROL_NUMPAD_0 + code - KeyCode.KEYCODE_NUMPAD_0;
    }
    if (code === KeyCode.KEYCODE_NUMPAD_DIVIDE) return CONTROL_NUMPAD_DIVIDE;
    if (code === KeyCode.KEYCODE_NUMPAD_MULTIPLY) return CONTROL_NUMPAD_MULTIPLY;
    if (code === KeyCode.KEYCODE_NUMPAD_SUBTRACT) return CONTROL_NUMPAD_SUBTRACT;
    if (code === KeyCode.KEYCODE_NUMPAD_ADD) return CONTROL_NUMPAD_ADD;
    if (code === KeyCode.KEYCODE_NUMPAD_DOT) return CONTROL_NUMPAD_DECIMAL;
    if (code === KeyCode.KEYCODE_NUMPAD_COMMA) return CONTROL_NUMPAD_SEPARATOR;
    if (code === KeyCode.KEYCODE_NUMPAD_EQUALS) return CONTROL_NUMPAD_EQUALS;
    if (code === KeyCode.KEYCODE_SPACE) return CONTROL_SPACE;
    if (code === KeyCode.KEYCODE_TAB) return CONTROL_TAB;
    if (code === KeyCode.KEYCODE_ESCAPE) return CONTROL_ESCAPE;
    if (code === KeyCode.KEYCODE_F1) return CONTROL_F1;
    if (code === KeyCode.KEYCODE_F2) return CONTROL_F2;
    if (code === KeyCode.KEYCODE_F3) return CONTROL_F3;
    if (code === KeyCode.KEYCODE_F4) return CONTROL_F4;
    if (code === KeyCode.KEYCODE_F5) return CONTROL_F5;
    if (code === KeyCode.KEYCODE_F6) return CONTROL_F6;
    if (code === KeyCode.KEYCODE_F7) return CONTROL_F7;
    if (code === KeyCode.KEYCODE_F8) return CONTROL_F8;
    if (code === KeyCode.KEYCODE_F9) return CONTROL_F9;
    if (code === KeyCode.KEYCODE_F10) return CONTROL_F10;
    if (code === KeyCode.KEYCODE_F11) return CONTROL_F11;
    if (code === KeyCode.KEYCODE_F12) return CONTROL_F12;
    if (code === KeyCode.KEYCODE_INSERT) return CONTROL_INSERT;
    if (code === KeyCode.KEYCODE_NUM_LOCK) return CONTROL_NUM_LOCK;
    if (code === KeyCode.KEYCODE_SCROLL_LOCK) return CONTROL_SCROLL_LOCK;
    return 0;
  }

  private resolveCharacter(code: number, text: string, activeModifiers: number[], capsLockOn: boolean): number {
    const fromText = this.singleCodePoint(text);
    if (fromText !== 0 && fromText >= 0x20 && fromText !== 0x7F) {
      return fromText;
    }

    const modifiers = this.collectModifiers(activeModifiers, 0, capsLockOn, this.numLockOn);
    const shifted = modifiers.indexOf(CONTROL_SHIFT) >= 0 || modifiers.indexOf(CONTROL_RSHIFT) >= 0;
    const caps = capsLockOn || modifiers.indexOf(CONTROL_CAPS_LOCK) >= 0;
    if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
      const lower = 97 + code - KeyCode.KEYCODE_A;
      return shifted !== caps ? lower - 32 : lower;
    }
    if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
      const digit = 48 + code - KeyCode.KEYCODE_0;
      if (!shifted) return digit;
      return ')!@#$%^&*('.charCodeAt(code - KeyCode.KEYCODE_0);
    }
    const plain = this.punctuation(code);
    if (plain === '') return 0;
    if (!shifted) return plain.charCodeAt(0);
    const shiftedValue = this.shiftedPunctuation(code);
    return shiftedValue === '' ? plain.charCodeAt(0) : shiftedValue.charCodeAt(0);
  }

  private singleCodePoint(text: string): number {
    if (text.length === 0 || Array.from(text).length !== 1) {
      return 0;
    }
    const point = text.codePointAt(0);
    return point === undefined || point > 0x10FFFF ? 0 : point;
  }

  private punctuation(code: number): string {
    if (code === KeyCode.KEYCODE_POUND) return '#';
    if (code === KeyCode.KEYCODE_STAR) return '*';
    if (code === KeyCode.KEYCODE_PLUS) return '+';
    if (code === KeyCode.KEYCODE_NUMPAD_PLUSMINUS) return '±';
    if (code === KeyCode.KEYCODE_NUMPAD_LEFT_PAREN) return '(';
    if (code === KeyCode.KEYCODE_NUMPAD_RIGHT_PAREN) return ')';
    if (code === KeyCode.KEYCODE_SPACE) return ' ';
    if (code === KeyCode.KEYCODE_GRAVE) return '`';
    if (code === KeyCode.KEYCODE_MINUS) return '-';
    if (code === KeyCode.KEYCODE_EQUALS) return '=';
    if (code === KeyCode.KEYCODE_LEFT_BRACKET) return '[';
    if (code === KeyCode.KEYCODE_RIGHT_BRACKET) return ']';
    if (code === KeyCode.KEYCODE_BACKSLASH) return '\\';
    if (code === KeyCode.KEYCODE_SEMICOLON) return ';';
    if (code === KeyCode.KEYCODE_APOSTROPHE) return "'";
    if (code === KeyCode.KEYCODE_COMMA) return ',';
    if (code === KeyCode.KEYCODE_PERIOD) return '.';
    if (code === KeyCode.KEYCODE_SLASH) return '/';
    if (code === KeyCode.KEYCODE_AT) return '@';
    return '';
  }

  private shiftedPunctuation(code: number): string {
    if (code === KeyCode.KEYCODE_GRAVE) return '~';
    if (code === KeyCode.KEYCODE_MINUS) return '_';
    if (code === KeyCode.KEYCODE_EQUALS) return '+';
    if (code === KeyCode.KEYCODE_LEFT_BRACKET) return '{';
    if (code === KeyCode.KEYCODE_RIGHT_BRACKET) return '}';
    if (code === KeyCode.KEYCODE_BACKSLASH) return '|';
    if (code === KeyCode.KEYCODE_SEMICOLON) return ':';
    if (code === KeyCode.KEYCODE_APOSTROPHE) return '"';
    if (code === KeyCode.KEYCODE_COMMA) return '<';
    if (code === KeyCode.KEYCODE_PERIOD) return '>';
    if (code === KeyCode.KEYCODE_SLASH) return '?';
    return '';
  }

  private collectModifiers(activeModifiers: number[], releasedModifier: number = 0,
    capsLockOn: boolean = false, numLockOn: boolean = false): number[] {
    const local: number[] = [];
    for (const binding of this.pressed.values()) {
      if (binding.modifier !== 0 && local.indexOf(binding.modifier) < 0) {
        local.push(binding.modifier);
      }
    }

    const external: number[] = [];
    const releasedGroup = this.modifierGroup(releasedModifier);
    for (const modifier of activeModifiers) {
      if (this.isProtocolModifier(modifier) && external.indexOf(modifier) < 0) {
        if (releasedModifier !== 0 && this.modifierGroup(modifier) === releasedGroup) {
          continue;
        }
        external.push(modifier);
      }
    }

    const result: number[] = local.slice();
    const representedGroups: number[] = [];
    for (const modifier of local) {
      const group = this.modifierGroup(modifier);
      if (representedGroups.indexOf(group) < 0) representedGroups.push(group);
    }
    for (const modifier of external) {
      const group = this.modifierGroup(modifier);
      if (representedGroups.indexOf(group) < 0) {
        result.push(modifier);
        representedGroups.push(group);
      }
    }
    if (capsLockOn && result.indexOf(CONTROL_CAPS_LOCK) < 0) {
      result.push(CONTROL_CAPS_LOCK);
    }
    if (numLockOn && result.indexOf(CONTROL_NUM_LOCK) < 0) {
      result.push(CONTROL_NUM_LOCK);
    }
    const order: number[] = [CONTROL_CONTROL, CONTROL_RCONTROL, CONTROL_SHIFT, CONTROL_RSHIFT,
      CONTROL_ALT, CONTROL_RALT, CONTROL_META, CONTROL_RWIN, CONTROL_CAPS_LOCK, CONTROL_NUM_LOCK];
    result.sort((left, right) => order.indexOf(left) - order.indexOf(right));
    return result;
  }

  private asModifier(code: number): number {
    return this.isProtocolModifier(code) ? code : 0;
  }

  private isProtocolModifier(code: number): boolean {
    return code === CONTROL_ALT || code === CONTROL_CAPS_LOCK || code === CONTROL_CONTROL ||
      code === CONTROL_META || code === CONTROL_SHIFT || code === CONTROL_NUM_LOCK || code === CONTROL_RWIN ||
      code === CONTROL_RSHIFT || code === CONTROL_RCONTROL || code === CONTROL_RALT;
  }

  private modifierGroup(code: number): number {
    if (code === CONTROL_CONTROL || code === CONTROL_RCONTROL) return 1;
    if (code === CONTROL_SHIFT || code === CONTROL_RSHIFT) return 2;
    if (code === CONTROL_ALT || code === CONTROL_RALT) return 3;
    if (code === CONTROL_META || code === CONTROL_RWIN) return 4;
    return code;
  }

  private isShortcutModifier(code: number): boolean {
    return code === CONTROL_CONTROL || code === CONTROL_RCONTROL || code === CONTROL_ALT ||
      code === CONTROL_RALT || code === CONTROL_META || code === CONTROL_RWIN;
  }
}
