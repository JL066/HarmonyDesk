package io.github.jl066.harmonydesk;

/** Narrow boundary between Android input handling and the remote session bridge. */
public interface InputSink {
    int KEY_CHARACTER = 1;
    int KEY_CONTROL = 2;

    int MOUSE_MOVE = 0;
    int MOUSE_BUTTON_DOWN = 1;
    int MOUSE_BUTTON_UP = 2;
    int MOUSE_WHEEL = 3;

    int BUTTON_LEFT = 1;
    int BUTTON_RIGHT = 2;
    int BUTTON_MIDDLE = 4;

    void mouse(int mask, int x, int y);

    void key(int kind, int code, boolean down, int[] modifiers);

    void text(String text);

    void control(int code);

    /** Tracks one IME composition so commitText and finishComposingText cannot forward it twice. */
    final class CompositionGate {
        private boolean composing;
        private boolean committing;
        private boolean discarding;
        private boolean finalized;

        public void beginComposing() {
            if (!discarding && !committing) {
                composing = true;
                finalized = false;
            }
        }

        public void beginCommit() {
            committing = true;
        }

        public void endCommit() {
            committing = false;
            composing = false;
            finalized = false;
        }

        public boolean isCommitting() {
            return committing;
        }

        public boolean isDiscarding() {
            return discarding;
        }

        /** Returns pending text only for the first explicit finish of a live composition. */
        public String finish(String pendingText) {
            if (discarding || committing || !composing || finalized) {
                return null;
            }
            finalized = true;
            composing = false;
            return pendingText == null || pendingText.isEmpty() ? null : pendingText;
        }

        public void beginDiscard() {
            discarding = true;
            composing = false;
            finalized = true;
        }

        public void endDiscard() {
            discarding = false;
            composing = false;
            finalized = false;
        }
    }

    /** RustDesk MouseEvent packs the type in the low three bits and button in bits 3+. */
    static int mouseMask(int event, int button) {
        if (event == MOUSE_MOVE || event == MOUSE_WHEEL) {
            if (button != 0) {
                throw new IllegalArgumentException("move and wheel events have no button");
            }
            return event;
        }
        if (event != MOUSE_BUTTON_DOWN && event != MOUSE_BUTTON_UP) {
            throw new IllegalArgumentException("unknown mouse event type");
        }
        if (button != BUTTON_LEFT && button != BUTTON_RIGHT && button != BUTTON_MIDDLE) {
            throw new IllegalArgumentException("unknown mouse button");
        }
        return event | (button << 3);
    }

    /** Maps Android KeyEvent key codes to the RustDesk ControlKey values used by key(). */
    static int controlCodeForAndroidKeyCode(int keyCode) {
        switch (keyCode) {
            case 57: return 1;  // ALT_LEFT -> Alt
            case 58: return 75; // ALT_RIGHT -> Right Alt
            case 59: return 29; // SHIFT_LEFT -> Shift
            case 60: return 73; // SHIFT_RIGHT -> Right Shift
            case 61: return 31; // TAB
            case 62: return 30; // SPACE
            case 66: return 27; // ENTER
            case 67: return 2;  // DEL
            case 19: return 32; // DPAD_UP
            case 20: return 6;  // DPAD_DOWN
            case 21: return 22; // DPAD_LEFT
            case 22: return 28; // DPAD_RIGHT
            case 92: return 26; // PAGE_UP
            case 93: return 25; // PAGE_DOWN
            case 111: return 8; // ESCAPE
            case 112: return 5; // FORWARD_DEL
            case 113: return 4; // CTRL_LEFT
            case 114: return 74; // CTRL_RIGHT
            case 115: return 3; // CAPS_LOCK
            case 116: return 62; // SCROLL_LOCK
            case 117: return 23; // META_LEFT
            case 118: return 64; // META_RIGHT
            case 122: return 21; // MOVE_HOME
            case 123: return 7;  // MOVE_END
            case 124: return 58; // INSERT
            case 131: return 9;  // F1
            case 140: return 10; // F10
            case 141: return 11; // F11
            case 142: return 12; // F12
            case 143: return 63; // NUM_LOCK
            case 154: return 70; // NUMPAD_DIVIDE
            case 155: return 66; // NUMPAD_MULTIPLY
            case 156: return 68; // NUMPAD_SUBTRACT
            case 157: return 67; // NUMPAD_ADD
            case 158: return 69; // NUMPAD_DOT
            case 159: return 61; // NUMPAD_COMMA
            case 160: return 72; // NUMPAD_ENTER
            case 161: return 71; // NUMPAD_EQUALS
            default:
                if (keyCode >= 132 && keyCode <= 139) {
                    return keyCode - 119; // F2..F9 map to ControlKey 13..20.
                }
                if (keyCode >= 144 && keyCode <= 153) {
                    return 33 + keyCode - 144; // NUMPAD_0..NUMPAD_9.
                }
                return 0;
        }
    }

    static boolean isModifierControlCode(int code) {
        return code == 1 || code == 3 || code == 4 || code == 23 || code == 29 || code == 63 ||
                code == 64 || code == 73 || code == 74 || code == 75;
    }

    static int modifierGroup(int code) {
        if (code == 4 || code == 74) return 1;
        if (code == 29 || code == 73) return 2;
        if (code == 1 || code == 75) return 3;
        if (code == 23 || code == 64) return 4;
        return code;
    }
}
