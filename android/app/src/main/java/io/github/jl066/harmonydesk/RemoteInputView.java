package io.github.jl066.harmonydesk;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PointF;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.Selection;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Transparent input surface placed above the remote TextureView. */
public final class RemoteInputView extends View {
    private static final int CONTROL_ALT = 1;
    private static final int CONTROL_BACKSPACE = 2;
    private static final int CONTROL_CAPS_LOCK = 3;
    private static final int CONTROL_CONTROL = 4;
    private static final int CONTROL_DELETE = 5;
    private static final int CONTROL_META = 23;
    private static final int CONTROL_SHIFT = 29;
    private static final int CONTROL_NUM_LOCK = 63;
    private static final int CONTROL_RWIN = 64;
    private static final int CONTROL_RSHIFT = 73;
    private static final int CONTROL_RCONTROL = 74;
    private static final int CONTROL_RALT = 75;

    private static final int[] MODIFIER_ORDER = {
            CONTROL_CONTROL, CONTROL_RCONTROL, CONTROL_SHIFT, CONTROL_RSHIFT,
            CONTROL_ALT, CONTROL_RALT, CONTROL_META, CONTROL_RWIN,
            CONTROL_CAPS_LOCK, CONTROL_NUM_LOCK
    };
    private static final int[] MOUSE_BUTTONS = {
            InputSink.BUTTON_LEFT, InputSink.BUTTON_RIGHT, InputSink.BUTTON_MIDDLE
    };

    public final Viewport viewport = new Viewport();
    /** Called whenever the TextureView and input surface should adopt a new transform. */
    public Runnable onViewportChanged;

    private final InputSink inputSink;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Map<Integer, KeyBinding> heldKeys = new LinkedHashMap<>();
    private final ScaleGestureDetector scaleDetector;
    private final int touchSlop;
    private final float longPressTimeoutMs;
    private final float wheelPixelsPerStep;
    private final Paint cursorFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cursorOutline = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Runnable longPressRunnable = this::fireLongPress;

    private boolean viewOnly;
    private boolean touchActive;
    private boolean touchDragging;
    private boolean touchMoved;
    private boolean rightClicked;
    private boolean multiTouch;
    private boolean multiTouchValid;
    private boolean pinchGesture;
    private int touchPointerId = -1;
    private float touchDownX;
    private float touchDownY;
    private float lastCentroidX;
    private float lastCentroidY;
    private float lastSpan;
    private float touchWheelRemainderX;
    private float touchWheelRemainderY;
    private float mouseWheelRemainderX;
    private float mouseWheelRemainderY;
    private int heldMouseButtons;
    private int remoteCursorX;
    private int remoteCursorY;
    private boolean cursorInitialized;
    private boolean cursorVisible;
    private int pendingDeadAccent;
    private int[] lastSentModifiers = new int[0];
    private RemoteInputConnection inputConnection;

    public RemoteInputView(Context context, InputSink sink) {
        super(context);
        if (sink == null) {
            throw new IllegalArgumentException("InputSink is required");
        }
        inputSink = sink;
        setBackgroundColor(0x00000000);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setClickable(true);
        setLongClickable(false);
        setSaveEnabled(false);
        cursorFill.setColor(0xFFF8F8F8);
        cursorFill.setStyle(Paint.Style.FILL);
        cursorOutline.setColor(0xFF111111);
        cursorOutline.setStyle(Paint.Style.STROKE);
        cursorOutline.setStrokeWidth(Math.max(1.0f,
                getResources().getDisplayMetrics().density * 1.5f));
        touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        longPressTimeoutMs = ViewConfiguration.getLongPressTimeout();
        wheelPixelsPerStep = Math.max(24.0f, 40.0f * getResources().getDisplayMetrics().density);
        scaleDetector = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override
            public boolean onScale(ScaleGestureDetector detector) {
                if (viewOnly || !multiTouch || !multiTouchValid || !pinchGesture) {
                    return false;
                }
                viewport.zoomAround(detector.getScaleFactor(), detector.getFocusX(), detector.getFocusY());
                notifyViewportChanged();
                return true;
            }
        });
    }

    public void setRemoteSize(int width, int height) {
        int oldWidth = viewport.remoteWidth();
        int oldHeight = viewport.remoteHeight();
        if (oldWidth == width && oldHeight == height) {
            return;
        }
        if (oldWidth > 0 && oldHeight > 0) {
            cancelPointerGesture();
        }
        viewport.setRemoteSize(width, height);
        if (!cursorInitialized && width > 0 && height > 0) {
            setCursorPosition(width / 2, height / 2);
            cursorInitialized = true;
        } else {
            clampCursor();
        }
        notifyViewportChanged();
    }

    public void setViewOnly(boolean readOnly) {
        if (viewOnly == readOnly) {
            return;
        }
        viewOnly = readOnly;
        if (readOnly) {
            releaseAll();
        }
    }

    public boolean isViewOnly() {
        return viewOnly;
    }

    public void setDisplayMode(Viewport.Mode mode) {
        viewport.setMode(mode);
        notifyViewportChanged();
    }

    /** Shows a local cursor over the remote frame when the server video has no cursor. */
    public void setCursorVisible(boolean visible) {
        if (cursorVisible != visible) {
            cursorVisible = visible;
            invalidate();
        }
    }

    public void showKeyboard() {
        if (viewOnly) {
            return;
        }
        requestFocus();
        InputMethodManager manager = (InputMethodManager) getContext()
                .getSystemService(Context.INPUT_METHOD_SERVICE);
        if (manager != null) {
            manager.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
        }
    }

    public void hideKeyboard() {
        InputMethodManager manager = (InputMethodManager) getContext()
                .getSystemService(Context.INPUT_METHOD_SERVICE);
        if (manager != null) {
            manager.hideSoftInputFromWindow(getWindowToken(), 0);
        }
    }

    /** Releases all held remote keys/buttons and cancels incomplete gestures. */
    public void releaseAll() {
        cancelPointerGesture();
        releaseKeys();
        if (inputConnection != null) {
            inputConnection.discardComposingText();
        }
        for (int button : MOUSE_BUTTONS) {
            if ((heldMouseButtons & button) != 0) {
                inputSink.mouse(InputSink.mouseMask(InputSink.MOUSE_BUTTON_UP, button),
                        remoteCursorX, remoteCursorY);
                heldMouseButtons &= ~button;
            }
        }
        mouseWheelRemainderX = 0.0f;
        mouseWheelRemainderY = 0.0f;
        pendingDeadAccent = 0;
    }

    /** Moves the remote cursor by relative remote pixels, for the floating touchpad. */
    public void moveCursorBy(float dx, float dy) {
        if (viewOnly || viewport.remoteWidth() <= 0 || viewport.remoteHeight() <= 0) {
            return;
        }
        if (!cursorInitialized) {
            setCursorPosition(viewport.remoteWidth() / 2, viewport.remoteHeight() / 2);
            cursorInitialized = true;
        }
        setCursorPosition(clamp((int) (remoteCursorX + dx), 0, viewport.remoteWidth() - 1),
                clamp((int) (remoteCursorY + dy), 0, viewport.remoteHeight() - 1));
        inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
    }

    /** Sends a balanced button transition at the current remote cursor. */
    public void setMouseButton(int button, boolean down) {
        if (button != InputSink.BUTTON_LEFT && button != InputSink.BUTTON_RIGHT &&
                button != InputSink.BUTTON_MIDDLE) {
            return;
        }
        if (viewOnly || ((heldMouseButtons & button) != 0) == down) {
            return;
        }
        if (down) {
            heldMouseButtons |= button;
        } else {
            heldMouseButtons &= ~button;
        }
        inputSink.mouse(InputSink.mouseMask(down ? InputSink.MOUSE_BUTTON_DOWN : InputSink.MOUSE_BUTTON_UP,
                button), remoteCursorX, remoteCursorY);
    }

    /** Sends remote wheel deltas; positive y scrolls up as required by the native bridge. */
    public void scrollRemote(float dx, float dy) {
        if (viewOnly) {
            return;
        }
        sendWheelDelta(dx, dy);
    }

    public int remoteCursorX() {
        return remoteCursorX;
    }

    public int remoteCursorY() {
        return remoteCursorY;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (!cursorVisible || !cursorInitialized) {
            return;
        }
        float[] point = viewport.mapRemoteToView(remoteCursorX, remoteCursorY);
        if (point == null || point[0] < 0 || point[1] < 0 ||
                point[0] >= getWidth() || point[1] >= getHeight()) {
            return;
        }
        float density = getResources().getDisplayMetrics().density;
        Path pointer = new Path();
        pointer.moveTo(0.0f, 0.0f);
        pointer.lineTo(0.0f, 19.0f * density);
        pointer.lineTo(4.5f * density, 14.5f * density);
        pointer.lineTo(8.0f * density, 22.0f * density);
        pointer.lineTo(10.5f * density, 21.0f * density);
        pointer.lineTo(7.0f * density, 13.5f * density);
        pointer.lineTo(14.0f * density, 13.5f * density);
        pointer.close();
        canvas.save();
        canvas.translate(point[0], point[1]);
        canvas.drawPath(pointer, cursorFill);
        canvas.drawPath(pointer, cursorOutline);
        canvas.restore();
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return !viewOnly;
    }

    @Override
    public android.view.inputmethod.InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        if (viewOnly) {
            return null;
        }
        outAttrs.inputType = android.text.InputType.TYPE_CLASS_TEXT |
                android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        outAttrs.imeOptions = EditorInfo.IME_ACTION_NONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI |
                EditorInfo.IME_FLAG_NO_FULLSCREEN;
        outAttrs.initialSelStart = 0;
        outAttrs.initialSelEnd = 0;
        inputConnection = new RemoteInputConnection();
        return inputConnection;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (!viewOnly && routeKeyEvent(event)) {
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (!viewOnly && routeKeyEvent(event)) {
            return true;
        }
        return super.onKeyUp(keyCode, event);
    }

    @Override
    public boolean onKeyPreIme(int keyCode, KeyEvent event) {
        if (viewOnly || event == null || !isShortcutKeyEvent(event)) {
            return super.onKeyPreIme(keyCode, event);
        }
        if ((event.getAction() == KeyEvent.ACTION_DOWN || event.getAction() == KeyEvent.ACTION_UP) &&
                routeKeyEvent(event)) {
            return true;
        }
        return super.onKeyPreIme(keyCode, event);
    }

    @Override
    public boolean onKeyMultiple(int keyCode, int repeatCount, KeyEvent event) {
        if (!viewOnly && event.getCharacters() != null && !event.getCharacters().isEmpty()) {
            inputSink.text(event.getCharacters());
            return true;
        }
        return super.onKeyMultiple(keyCode, repeatCount, event);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            return handleMouseTouchEvent(event);
        }
        if (viewOnly) {
            return true;
        }
        requestFocus();
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            if (event.getPointerCount() != 1) {
                return true;
            }
            Viewport.RemotePoint point = viewport.mapViewToRemote(event.getX(), event.getY());
            if (point == null) {
                touchActive = false;
                return true;
            }
            cancelPointerGesture();
            setCursorPosition(point.x, point.y);
            cursorInitialized = true;
            inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
            touchPointerId = event.getPointerId(0);
            touchDownX = event.getX();
            touchDownY = event.getY();
            touchActive = true;
            rightClicked = false;
            handler.postDelayed(longPressRunnable, (long) longPressTimeoutMs);
            return true;
        }
        if (action == MotionEvent.ACTION_POINTER_DOWN) {
            if (event.getPointerCount() >= 2) {
                beginMultiTouch(event);
            }
            scaleDetector.onTouchEvent(event);
            return true;
        }
        if (action == MotionEvent.ACTION_MOVE) {
            if (event.getPointerCount() >= 2) {
                handleMultiTouchMove(event);
            } else if (touchActive && !multiTouch) {
                handleSingleTouchMove(event);
            }
            scaleDetector.onTouchEvent(event);
            return true;
        }
        if (action == MotionEvent.ACTION_POINTER_UP) {
            scaleDetector.onTouchEvent(event);
            if (event.getPointerCount() <= 2) {
                finishMultiTouch();
            }
            return true;
        }
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            scaleDetector.onTouchEvent(event);
            if (multiTouch) {
                finishMultiTouch();
            } else if (touchActive) {
                finishSingleTouch(event, action == MotionEvent.ACTION_UP);
            }
            return true;
        }
        scaleDetector.onTouchEvent(event);
        return true;
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent event) {
        if (viewOnly) {
            return super.onGenericMotionEvent(event);
        }
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_HOVER_MOVE || action == MotionEvent.ACTION_MOVE) {
            boolean mapped = moveMousePointer(event.getX(), event.getY());
            if (action == MotionEvent.ACTION_MOVE) {
                updateMouseButtonState(event, mapped);
            }
            return true;
        }
        if (action == MotionEvent.ACTION_BUTTON_PRESS || action == MotionEvent.ACTION_BUTTON_RELEASE) {
            boolean mapped = moveMousePointer(event.getX(), event.getY());
            int button = event.getActionButton();
            if (isSupportedMouseButton(button) && (action == MotionEvent.ACTION_BUTTON_RELEASE || mapped)) {
                setMouseButton(button, action == MotionEvent.ACTION_BUTTON_PRESS);
            }
            return true;
        }
        if (action == MotionEvent.ACTION_SCROLL) {
            moveMousePointer(event.getX(), event.getY());
            if (viewport.mapViewToRemote(event.getX(), event.getY()) != null) {
                float horizontal = event.getAxisValue(MotionEvent.AXIS_HSCROLL);
                float vertical = event.getAxisValue(MotionEvent.AXIS_VSCROLL);
                sendWheelDelta(horizontal, vertical);
            }
            return true;
        }
        return super.onGenericMotionEvent(event);
    }

    @Override
    protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        if (oldWidth != width || oldHeight != height) {
            if (oldWidth > 0 && oldHeight > 0) {
                releaseAll();
            }
            viewport.setViewSize(width, height);
            notifyViewportChanged();
        }
    }

    @Override
    protected void onFocusChanged(boolean gainFocus, int direction, android.graphics.Rect previouslyFocusedRect) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect);
        if (!gainFocus) {
            releaseAll();
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasWindowFocus) {
        super.onWindowFocusChanged(hasWindowFocus);
        if (!hasWindowFocus) {
            releaseAll();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        releaseAll();
        if (inputConnection != null) {
            inputConnection.closeConnection();
            inputConnection = null;
        }
        super.onDetachedFromWindow();
    }

    private boolean handleMouseTouchEvent(MotionEvent event) {
        if (viewOnly) {
            return true;
        }
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP) {
            boolean mapped = moveMousePointer(event.getX(), event.getY());
            int button = changedButton(event, action == MotionEvent.ACTION_DOWN);
            if (isSupportedMouseButton(button) && (action == MotionEvent.ACTION_UP || mapped)) {
                setMouseButton(button, action == MotionEvent.ACTION_DOWN);
            }
            return true;
        }
        if (action == MotionEvent.ACTION_MOVE) {
            boolean mapped = moveMousePointer(event.getX(), event.getY());
            updateMouseButtonState(event, mapped);
            return true;
        }
        if (action == MotionEvent.ACTION_CANCEL) {
            releaseMouseButtons();
            return true;
        }
        return true;
    }

    private boolean moveMousePointer(float x, float y) {
        Viewport.RemotePoint point = viewport.mapViewToRemote(x, y);
        if (point == null) {
            return false;
        }
        setCursorPosition(point.x, point.y);
        cursorInitialized = true;
        inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
        return true;
    }

    private void updateMouseButtonState(MotionEvent event, boolean allowDown) {
        int state = event.getButtonState() & (InputSink.BUTTON_LEFT | InputSink.BUTTON_RIGHT |
                InputSink.BUTTON_MIDDLE);
        for (int button : MOUSE_BUTTONS) {
            boolean down = (state & button) != 0;
            if (((heldMouseButtons & button) != 0) != down) {
                if (down && !allowDown) {
                    continue;
                }
                setMouseButton(button, down);
            }
        }
    }

    private int changedButton(MotionEvent event, boolean down) {
        int actionButton = event.getActionButton();
        if (isSupportedMouseButton(actionButton)) {
            return actionButton;
        }
        int state = event.getButtonState() & (InputSink.BUTTON_LEFT | InputSink.BUTTON_RIGHT |
                InputSink.BUTTON_MIDDLE);
        int changed = down ? state & ~heldMouseButtons : heldMouseButtons & ~state;
        for (int button : MOUSE_BUTTONS) {
            if ((changed & button) != 0) {
                return button;
            }
        }
        return InputSink.BUTTON_LEFT;
    }

    private void beginMultiTouch(MotionEvent event) {
        if (!multiTouch) {
            handler.removeCallbacks(longPressRunnable);
            if (touchDragging) {
                setMouseButton(InputSink.BUTTON_LEFT, false);
            }
            touchActive = false;
            multiTouch = true;
            pinchGesture = false;
            PointF center = centroid(event);
            multiTouchValid = viewport.mapViewToRemote(center.x, center.y) != null;
            touchWheelRemainderX = 0.0f;
            touchWheelRemainderY = 0.0f;
        }
        updateMultiTouchBaseline(event);
    }

    private void handleMultiTouchMove(MotionEvent event) {
        if (!multiTouch) {
            beginMultiTouch(event);
            return;
        }
        PointF center = centroid(event);
        float span = span(event, center.x, center.y);
        float dx = center.x - lastCentroidX;
        float dy = center.y - lastCentroidY;
        float spanDelta = Math.abs(span - lastSpan);
        if (spanDelta > Math.max(4.0f * getResources().getDisplayMetrics().density, lastSpan * 0.015f)) {
            pinchGesture = true;
        }
        scaleDetector.onTouchEvent(event);
        if (multiTouchValid && !pinchGesture) {
            // Same-direction two-finger movement scrolls remote content. Touch moving down
            // is a downward wheel movement, so it carries a negative RustDesk delta.
            touchWheelRemainderX -= dx / wheelPixelsPerStep;
            touchWheelRemainderY -= dy / wheelPixelsPerStep;
            int wheelX = (int) touchWheelRemainderX;
            int wheelY = (int) touchWheelRemainderY;
            touchWheelRemainderX -= wheelX;
            touchWheelRemainderY -= wheelY;
            if (wheelX != 0 || wheelY != 0) {
                inputSink.mouse(InputSink.mouseMask(InputSink.MOUSE_WHEEL, 0), wheelX, wheelY);
            }
        }
        lastCentroidX = center.x;
        lastCentroidY = center.y;
        lastSpan = span;
    }

    private void updateMultiTouchBaseline(MotionEvent event) {
        PointF center = centroid(event);
        lastCentroidX = center.x;
        lastCentroidY = center.y;
        lastSpan = span(event, center.x, center.y);
    }

    private PointF centroid(MotionEvent event) {
        int count = Math.min(2, event.getPointerCount());
        float x = 0.0f;
        float y = 0.0f;
        for (int i = 0; i < count; i++) {
            x += event.getX(i);
            y += event.getY(i);
        }
        return new PointF(x / Math.max(1, count), y / Math.max(1, count));
    }

    private float span(MotionEvent event, float centerX, float centerY) {
        if (event.getPointerCount() < 2) {
            return 0.0f;
        }
        float dx = event.getX(0) - centerX;
        float dy = event.getY(0) - centerY;
        return (float) (2.0 * Math.sqrt(dx * dx + dy * dy));
    }

    private void finishMultiTouch() {
        multiTouch = false;
        pinchGesture = false;
        touchActive = false;
        touchDragging = false;
        touchMoved = false;
        touchPointerId = -1;
        multiTouchValid = false;
        touchWheelRemainderX = 0.0f;
        touchWheelRemainderY = 0.0f;
        handler.removeCallbacks(longPressRunnable);
    }

    private void handleSingleTouchMove(MotionEvent event) {
        int index = event.findPointerIndex(touchPointerId);
        if (index < 0) {
            return;
        }
        float x = event.getX(index);
        float y = event.getY(index);
        if (rightClicked) {
            Viewport.RemotePoint rightClickPoint = viewport.mapViewToRemote(x, y);
            if (rightClickPoint != null) {
                setCursorPosition(rightClickPoint.x, rightClickPoint.y);
                cursorInitialized = true;
                inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
            }
            return;
        }
        if (!touchMoved && (Math.abs(x - touchDownX) > touchSlop || Math.abs(y - touchDownY) > touchSlop)) {
            touchMoved = true;
            handler.removeCallbacks(longPressRunnable);
        }
        Viewport.RemotePoint point = viewport.mapViewToRemote(x, y);
        if (point == null) {
            return;
        }
        setCursorPosition(point.x, point.y);
        cursorInitialized = true;
        if (touchMoved && !touchDragging) {
            setMouseButton(InputSink.BUTTON_LEFT, true);
            touchDragging = true;
        }
        inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
    }

    private void finishSingleTouch(MotionEvent event, boolean isUp) {
        handler.removeCallbacks(longPressRunnable);
        int index = event.findPointerIndex(touchPointerId);
        if (index < 0 && event.getPointerCount() > 0) {
            index = 0;
        }
        if (index >= 0) {
            Viewport.RemotePoint point = viewport.mapViewToRemote(event.getX(index), event.getY(index));
            if (point != null) {
                setCursorPosition(point.x, point.y);
                cursorInitialized = true;
            }
        }
        if (touchDragging) {
            setMouseButton(InputSink.BUTTON_LEFT, false);
        } else if (isUp && !touchMoved && !rightClicked && cursorInitialized) {
            inputSink.mouse(InputSink.MOUSE_MOVE, remoteCursorX, remoteCursorY);
            setMouseButton(InputSink.BUTTON_LEFT, true);
            setMouseButton(InputSink.BUTTON_LEFT, false);
        }
        touchActive = false;
        touchDragging = false;
        touchMoved = false;
        touchPointerId = -1;
        multiTouchValid = false;
    }

    private void fireLongPress() {
        if (viewOnly || !touchActive || touchMoved || multiTouch || !cursorInitialized) {
            return;
        }
        setMouseButton(InputSink.BUTTON_RIGHT, true);
        setMouseButton(InputSink.BUTTON_RIGHT, false);
        rightClicked = true;
    }

    private void cancelPointerGesture() {
        handler.removeCallbacks(longPressRunnable);
        if (touchDragging) {
            setMouseButton(InputSink.BUTTON_LEFT, false);
        }
        touchActive = false;
        touchDragging = false;
        touchMoved = false;
        rightClicked = false;
        multiTouch = false;
        pinchGesture = false;
        multiTouchValid = false;
        touchPointerId = -1;
        touchWheelRemainderX = 0.0f;
        touchWheelRemainderY = 0.0f;
    }

    private void sendWheelDelta(float dx, float dy) {
        if (!Float.isFinite(dx) || !Float.isFinite(dy)) {
            return;
        }
        mouseWheelRemainderX += dx;
        mouseWheelRemainderY += dy;
        int wheelX = (int) mouseWheelRemainderX;
        int wheelY = (int) mouseWheelRemainderY;
        mouseWheelRemainderX -= wheelX;
        mouseWheelRemainderY -= wheelY;
        if (wheelX != 0 || wheelY != 0) {
            inputSink.mouse(InputSink.mouseMask(InputSink.MOUSE_WHEEL, 0), wheelX, wheelY);
        }
    }

    private boolean routeKeyEvent(KeyEvent event) {
        int action = event.getAction();
        int keyCode = event.getKeyCode();
        if (action == KeyEvent.ACTION_DOWN) {
            KeyBinding binding = heldKeys.get(keyCode);
            if (binding == null) {
                binding = mapKey(event);
                if (binding == null) {
                    return false;
                }
                heldKeys.put(keyCode, binding);
            } else if (binding.modifier != 0) {
                return true;
            }
            int[] modifiers = collectModifiers(event, 0);
            lastSentModifiers = modifiers;
            inputSink.key(binding.kind, binding.code, true, modifiers);
            return true;
        }
        if (action == KeyEvent.ACTION_UP) {
            KeyBinding binding = heldKeys.remove(keyCode);
            if (binding == null) {
                return releaseObservedModifier(event, keyCode);
            }
            int[] modifiers = collectModifiers(event, binding.modifier);
            lastSentModifiers = modifiers;
            inputSink.key(binding.kind, binding.code, false, modifiers);
            return true;
        }
        return false;
    }

    private KeyBinding mapKey(KeyEvent event) {
        int code = InputSink.controlCodeForAndroidKeyCode(event.getKeyCode());
        if (code != 0) {
            pendingDeadAccent = 0;
            return new KeyBinding(InputSink.KEY_CONTROL, code,
                    InputSink.isModifierControlCode(code) ? code : 0);
        }
        int meta = event.getMetaState();
        boolean shortcut = (meta & (KeyEvent.META_CTRL_MASK | KeyEvent.META_META_MASK)) != 0;
        int unicode = event.getUnicodeChar(meta & ~(KeyEvent.META_CTRL_MASK | KeyEvent.META_META_MASK));
        if (unicode == 0) {
            pendingDeadAccent = 0;
            return null;
        }
        if ((unicode & KeyCharacterMap.COMBINING_ACCENT) != 0) {
            pendingDeadAccent = unicode & KeyCharacterMap.COMBINING_ACCENT_MASK;
            return null;
        }
        if (shortcut) {
            pendingDeadAccent = 0;
        }
        if (pendingDeadAccent != 0 && !shortcut) {
            int combined = KeyCharacterMap.getDeadChar(pendingDeadAccent, unicode);
            if (combined != 0) {
                unicode = combined;
            }
            pendingDeadAccent = 0;
        }
        if (unicode < 0x20 || (unicode >= 0x7F && unicode < 0xA0) ||
                (unicode >= 0xD800 && unicode <= 0xDFFF) || unicode > 0x10FFFF) {
            return null;
        }
        return new KeyBinding(InputSink.KEY_CHARACTER, unicode, 0);
    }

    private int[] collectModifiers(KeyEvent event, int releasedModifier) {
        List<Integer> local = new ArrayList<>();
        for (KeyBinding binding : heldKeys.values()) {
            if (binding.modifier != 0 && !local.contains(binding.modifier)) {
                local.add(binding.modifier);
            }
        }
        List<Integer> values = new ArrayList<>(local);
        boolean ctrl = event != null && event.isCtrlPressed();
        boolean shift = event != null && event.isShiftPressed();
        boolean alt = event != null && event.isAltPressed();
        boolean meta = event != null && event.isMetaPressed();
        int releasedGroup = modifierGroup(releasedModifier);
        addExternal(values, local, ctrl, CONTROL_CONTROL, releasedGroup);
        addExternal(values, local, shift, CONTROL_SHIFT, releasedGroup);
        addExternal(values, local, alt, CONTROL_ALT, releasedGroup);
        addExternal(values, local, meta, CONTROL_META, releasedGroup);
        if (event != null && event.isCapsLockOn() && !values.contains(CONTROL_CAPS_LOCK)) {
            values.add(CONTROL_CAPS_LOCK);
        }
        if (event != null && (event.getMetaState() & KeyEvent.META_NUM_LOCK_ON) != 0 &&
                !values.contains(CONTROL_NUM_LOCK)) {
            values.add(CONTROL_NUM_LOCK);
        }
        Collections.sort(values, Comparator.comparingInt(RemoteInputView::modifierOrder));
        int[] result = new int[values.size()];
        for (int i = 0; i < values.size(); i++) {
            result[i] = values.get(i);
        }
        return result;
    }

    private boolean releaseObservedModifier(KeyEvent event, int keyCode) {
        int keyModifier = InputSink.controlCodeForAndroidKeyCode(keyCode);
        if (!InputSink.isModifierControlCode(keyModifier)) {
            return false;
        }
        int group = modifierGroup(keyModifier);
        for (KeyBinding binding : heldKeys.values()) {
            if (binding.modifier != 0 && modifierGroup(binding.modifier) == group) {
                return false;
            }
        }
        int observed = 0;
        for (int modifier : lastSentModifiers) {
            if (modifierGroup(modifier) == group) {
                observed = modifier;
                break;
            }
        }
        if (observed == 0) {
            return false;
        }
        int[] modifiers = collectModifiers(event, observed);
        inputSink.key(InputSink.KEY_CONTROL, observed, false, modifiers);
        lastSentModifiers = modifiers;
        return true;
    }

    private static void addExternal(List<Integer> values, List<Integer> local, boolean active,
                                    int code, int releasedGroup) {
        if (!active || modifierGroup(code) == releasedGroup || hasModifierGroup(local, modifierGroup(code)) ||
                values.contains(code)) {
            return;
        }
        values.add(code);
    }

    private static boolean hasModifierGroup(List<Integer> values, int group) {
        for (int value : values) {
            if (modifierGroup(value) == group) {
                return true;
            }
        }
        return false;
    }

    private void releaseKeys() {
        if (heldKeys.isEmpty() && lastSentModifiers.length == 0) {
            return;
        }
        int[] observed = lastSentModifiers.clone();
        List<Map.Entry<Integer, KeyBinding>> keys = new ArrayList<>(heldKeys.entrySet());
        keys.sort((left, right) -> Boolean.compare(left.getValue().modifier != 0,
                right.getValue().modifier != 0));
        for (Map.Entry<Integer, KeyBinding> entry : keys) {
            heldKeys.remove(entry.getKey());
            int[] modifiers = collectModifiers(null, entry.getValue().modifier);
            inputSink.key(entry.getValue().kind, entry.getValue().code, false, modifiers);
            lastSentModifiers = modifiers;
        }
        for (int modifier : observed) {
            if (modifier == CONTROL_CAPS_LOCK || modifier == CONTROL_NUM_LOCK) {
                continue;
            }
            boolean wasTracked = false;
            for (Map.Entry<Integer, KeyBinding> entry : keys) {
                if (entry.getValue().code == modifier) {
                    wasTracked = true;
                    break;
                }
            }
            if (!wasTracked) {
                inputSink.key(InputSink.KEY_CONTROL, modifier, false, new int[0]);
            }
        }
        lastSentModifiers = new int[0];
    }

    private void releaseMouseButtons() {
        for (int button : MOUSE_BUTTONS) {
            if ((heldMouseButtons & button) != 0) {
                setMouseButton(button, false);
            }
        }
    }

    private void clampCursor() {
        if (viewport.remoteWidth() > 0) {
            remoteCursorX = clamp(remoteCursorX, 0, viewport.remoteWidth() - 1);
        }
        if (viewport.remoteHeight() > 0) {
            remoteCursorY = clamp(remoteCursorY, 0, viewport.remoteHeight() - 1);
        }
        invalidate();
    }

    private void notifyViewportChanged() {
        if (getWidth() > 0 && getHeight() > 0 &&
                (viewport.viewWidth() != getWidth() || viewport.viewHeight() != getHeight())) {
            viewport.setViewSize(getWidth(), getHeight());
        }
        if (onViewportChanged != null) {
            onViewportChanged.run();
        }
        invalidate();
    }

    private void setCursorPosition(int x, int y) {
        if (remoteCursorX != x || remoteCursorY != y) {
            remoteCursorX = x;
            remoteCursorY = y;
            invalidate();
        }
    }

    private boolean isShortcutKeyEvent(KeyEvent event) {
        int controlCode = InputSink.controlCodeForAndroidKeyCode(event.getKeyCode());
        int group = modifierGroup(controlCode);
        boolean isCtrlOrMetaKey = group == modifierGroup(CONTROL_CONTROL) ||
                group == modifierGroup(CONTROL_META);
        boolean activeCtrlOrMeta = event.isCtrlPressed() || event.isMetaPressed();
        if (!activeCtrlOrMeta) {
            for (KeyBinding binding : heldKeys.values()) {
                if (binding.modifier != 0 &&
                        (modifierGroup(binding.modifier) == modifierGroup(CONTROL_CONTROL) ||
                                modifierGroup(binding.modifier) == modifierGroup(CONTROL_META))) {
                    activeCtrlOrMeta = true;
                    break;
                }
            }
        }
        // Let AltGr, ordinary printable keys, and IME language-switch gestures reach the IME.
        return isCtrlOrMetaKey || activeCtrlOrMeta;
    }

    private static int modifierGroup(int code) {
        return InputSink.modifierGroup(code);
    }

    private static int modifierOrder(int code) {
        for (int i = 0; i < MODIFIER_ORDER.length; i++) {
            if (MODIFIER_ORDER[i] == code) return i;
        }
        return MODIFIER_ORDER.length;
    }

    private static boolean isSupportedMouseButton(int button) {
        return button == InputSink.BUTTON_LEFT || button == InputSink.BUTTON_RIGHT ||
                button == InputSink.BUTTON_MIDDLE;
    }

    private static int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }

    private static final class KeyBinding {
        final int kind;
        final int code;
        final int modifier;

        KeyBinding(int kind, int code, int modifier) {
            this.kind = kind;
            this.code = code;
            this.modifier = modifier;
        }
    }

    private final class RemoteInputConnection extends BaseInputConnection {
        private final InputSink.CompositionGate compositionGate = new InputSink.CompositionGate();
        private boolean valid = true;

        RemoteInputConnection() {
            super(RemoteInputView.this, true);
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            if (!valid) {
                return false;
            }
            boolean accepted;
            compositionGate.beginCommit();
            try {
                accepted = super.commitText(text, newCursorPosition);
            } finally {
                compositionGate.endCommit();
            }
            if (accepted) {
                if (text != null && text.length() > 0 && !viewOnly) {
                    inputSink.text(text.toString());
                }
                // The remote desktop has no local editable text context. Keep only transient
                // composing text so the IME cannot read earlier committed remote input back.
                Editable editable = getEditable();
                if (editable != null) {
                    editable.clear();
                    Selection.setSelection(editable, 0);
                }
            }
            return accepted;
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            if (!valid || viewOnly) {
                return false;
            }
            boolean accepted = super.setComposingText(text, newCursorPosition);
            if (accepted) {
                compositionGate.beginComposing();
            }
            return accepted;
        }

        @Override
        public boolean finishComposingText() {
            if (!valid) {
                return false;
            }
            Editable editable = getEditable();
            String pending = composingText(editable);
            boolean accepted = super.finishComposingText();
            if (accepted) {
                boolean internalFinish = compositionGate.isCommitting() || compositionGate.isDiscarding();
                String finalized = compositionGate.finish(pending);
                if (!internalFinish) {
                    if (finalized != null && !viewOnly) {
                        inputSink.text(finalized);
                    }
                    clearEditable(editable);
                }
            }
            return accepted;
        }

        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            if (!valid || viewOnly) {
                return false;
            }
            if (event.getAction() == KeyEvent.ACTION_MULTIPLE && event.getCharacters() != null &&
                    !event.getCharacters().isEmpty()) {
                inputSink.text(event.getCharacters());
                return true;
            }
            return routeKeyEvent(event);
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            if (!valid || viewOnly) {
                return false;
            }
            Editable editable = getEditable();
            int composingStart = editable == null ? -1 : BaseInputConnection.getComposingSpanStart(editable);
            int composingEnd = editable == null ? -1 : BaseInputConnection.getComposingSpanEnd(editable);
            if (composingStart >= 0 && composingEnd >= 0) {
                return super.deleteSurroundingText(beforeLength, afterLength);
            }
            sendDeletion(beforeLength, afterLength);
            return true;
        }

        @Override
        public boolean deleteSurroundingTextInCodePoints(int beforeLength, int afterLength) {
            if (!valid || viewOnly) {
                return false;
            }
            Editable editable = getEditable();
            int composingStart = editable == null ? -1 : BaseInputConnection.getComposingSpanStart(editable);
            int composingEnd = editable == null ? -1 : BaseInputConnection.getComposingSpanEnd(editable);
            if (composingStart >= 0 && composingEnd >= 0) {
                return super.deleteSurroundingTextInCodePoints(beforeLength, afterLength);
            }
            sendDeletion(beforeLength, afterLength);
            return true;
        }

        @Override
        public void closeConnection() {
            if (valid) {
                compositionGate.beginDiscard();
                try {
                    super.closeConnection();
                    clearEditable(getEditable());
                } finally {
                    compositionGate.endDiscard();
                    valid = false;
                }
            }
        }

        private void discardComposingText() {
            if (!valid) {
                return;
            }
            Editable editable = getEditable();
            compositionGate.beginDiscard();
            try {
                super.finishComposingText();
                clearEditable(editable);
            } finally {
                compositionGate.endDiscard();
            }
        }

        private String composingText(Editable editable) {
            if (editable == null) {
                return null;
            }
            int start = BaseInputConnection.getComposingSpanStart(editable);
            int end = BaseInputConnection.getComposingSpanEnd(editable);
            if (start < 0 || end < 0) {
                return null;
            }
            int from = Math.max(0, Math.min(start, end));
            int to = Math.min(editable.length(), Math.max(start, end));
            return from < to ? editable.subSequence(from, to).toString() : null;
        }

        private void clearEditable(Editable editable) {
            if (editable != null) {
                editable.clear();
                Selection.setSelection(editable, 0);
            }
        }

        private void sendDeletion(int beforeLength, int afterLength) {
            int before = Math.min(64, Math.max(0, beforeLength));
            int after = Math.min(64, Math.max(0, afterLength));
            for (int i = 0; i < before; i++) {
                sendSoftControl(CONTROL_BACKSPACE);
            }
            for (int i = 0; i < after; i++) {
                sendSoftControl(CONTROL_DELETE);
            }
        }

        private void sendSoftControl(int code) {
            inputSink.key(InputSink.KEY_CONTROL, code, true, new int[0]);
            inputSink.key(InputSink.KEY_CONTROL, code, false, new int[0]);
        }
    }
}
