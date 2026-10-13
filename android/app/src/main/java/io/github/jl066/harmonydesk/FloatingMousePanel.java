package io.github.jl066.harmonydesk;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;

/** Optional bounded on-screen mouse pad. Add as a sibling above RemoteInputView. */
public final class FloatingMousePanel extends View {
    private static final int CONTROL_NONE = 0;
    private static final int CONTROL_LEFT = 1;
    private static final int CONTROL_RIGHT = 2;
    private static final int CONTROL_WHEEL_UP = 3;
    private static final int CONTROL_WHEEL_DOWN = 4;

    private final InputSink inputSink;
    private final RemoteInputView remoteInputView;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float density;
    private final float panelRadius;
    private final float padding;
    private final float headerHeight;
    private final float buttonHeight;
    private final float desiredWidth;
    private final float desiredHeight;
    private final RectF padBounds = new RectF();
    private final RectF headerBounds = new RectF();
    private final RectF[] controlBounds = {new RectF(), new RectF(), new RectF(), new RectF()};

    private boolean draggingPanel;
    private boolean movingCursor;
    private float downRawX;
    private float downRawY;
    private float downTranslationX;
    private float downTranslationY;
    private float lastPadX;
    private float lastPadY;
    private int pressedControl;
    private int pressedButton;

    public FloatingMousePanel(Context context, InputSink sink, RemoteInputView remoteInput) {
        super(context);
        if (sink == null || remoteInput == null) {
            throw new IllegalArgumentException("InputSink and RemoteInputView are required");
        }
        inputSink = sink;
        remoteInputView = remoteInput;
        density = getResources().getDisplayMetrics().density;
        panelRadius = dp(14.0f);
        padding = dp(9.0f);
        headerHeight = dp(30.0f);
        buttonHeight = dp(42.0f);
        desiredWidth = dp(248.0f);
        desiredHeight = dp(212.0f);
        setFocusable(false);
        setFocusableInTouchMode(false);
        setClickable(true);
        setLongClickable(false);
        setSaveEnabled(false);
        setLayerType(View.LAYER_TYPE_SOFTWARE, null);
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int width = boundedSize(desiredWidth, widthMeasureSpec);
        int height = boundedSize(desiredHeight, heightMeasureSpec);
        setMeasuredDimension(width, height);
    }

    @Override
    protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        updateGeometry(width, height);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float width = getWidth();
        float height = getHeight();
        if (width <= 0 || height <= 0) {
            return;
        }
        paint.setColor(0xE620252D);
        paint.setStyle(Paint.Style.FILL);
        canvas.drawRoundRect(0.0f, 0.0f, width, height, panelRadius, panelRadius, paint);

        paint.setColor(0xFF343B46);
        canvas.drawRoundRect(headerBounds, panelRadius, panelRadius, paint);
        paint.setColor(0xFF161B22);
        canvas.drawRoundRect(padBounds, dp(9.0f), dp(9.0f), paint);
        paint.setColor(0xFF697586);
        paint.setStrokeWidth(dp(1.0f));
        paint.setStyle(Paint.Style.STROKE);
        canvas.drawRoundRect(padBounds, dp(9.0f), dp(9.0f), paint);
        paint.setStyle(Paint.Style.FILL);

        drawText(canvas, "Mouse", padding + dp(4.0f), headerBounds.centerY() + dp(5.0f),
                dp(13.0f), 0xFFF3F4F6, Paint.Align.LEFT);
        drawText(canvas, "drag", width - padding - dp(3.0f), headerBounds.centerY() + dp(4.0f),
                dp(10.0f), 0xFFADB7C4, Paint.Align.RIGHT);
        drawText(canvas, "Touchpad", padBounds.centerX(), padBounds.centerY() + dp(4.0f),
                dp(12.0f), 0xFF8994A3, Paint.Align.CENTER);

        String[] labels = {"L", "R", "↑", "↓"};
        int[] ids = {CONTROL_LEFT, CONTROL_RIGHT, CONTROL_WHEEL_UP, CONTROL_WHEEL_DOWN};
        for (int i = 0; i < controlBounds.length; i++) {
            RectF bounds = controlBounds[i];
            paint.setColor(pressedControl == ids[i] ? 0xFF4B86C6 : 0xFF303844);
            canvas.drawRoundRect(bounds, dp(8.0f), dp(8.0f), paint);
            drawText(canvas, labels[i], bounds.centerX(), bounds.centerY() + dp(5.0f),
                    dp(16.0f), 0xFFF3F4F6, Paint.Align.CENTER);
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        float x = event.getX();
        float y = event.getY();
        if (action == MotionEvent.ACTION_DOWN) {
            if (headerBounds.contains(x, y)) {
                draggingPanel = true;
                downRawX = event.getRawX();
                downRawY = event.getRawY();
                downTranslationX = getTranslationX();
                downTranslationY = getTranslationY();
                return true;
            }
            int control = controlAt(x, y);
            if (control != CONTROL_NONE) {
                pressedControl = control;
                if (control == CONTROL_LEFT || control == CONTROL_RIGHT) {
                    pressedButton = control == CONTROL_LEFT ? InputSink.BUTTON_LEFT : InputSink.BUTTON_RIGHT;
                    remoteInputView.setMouseButton(pressedButton, true);
                }
                invalidate();
                return true;
            }
            if (padBounds.contains(x, y)) {
                movingCursor = true;
                lastPadX = x;
                lastPadY = y;
                return true;
            }
            return false;
        }
        if (action == MotionEvent.ACTION_MOVE) {
            if (draggingPanel) {
                movePanel(event.getRawX(), event.getRawY());
                return true;
            }
            if (movingCursor) {
                moveCursor(x, y);
                return true;
            }
            return pressedControl != CONTROL_NONE;
        }
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            if (pressedButton != 0) {
                remoteInputView.setMouseButton(pressedButton, false);
                pressedButton = 0;
            }
            if (action == MotionEvent.ACTION_UP && pressedControl == CONTROL_WHEEL_UP) {
                sendWheel(1);
            } else if (action == MotionEvent.ACTION_UP && pressedControl == CONTROL_WHEEL_DOWN) {
                sendWheel(-1);
            }
            draggingPanel = false;
            movingCursor = false;
            pressedControl = CONTROL_NONE;
            invalidate();
            return true;
        }
        return action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP;
    }

    @Override
    protected void onDetachedFromWindow() {
        if (pressedButton != 0) {
            remoteInputView.setMouseButton(pressedButton, false);
            pressedButton = 0;
        }
        super.onDetachedFromWindow();
    }

    private void moveCursor(float x, float y) {
        float dx = x - lastPadX;
        float dy = y - lastPadY;
        lastPadX = x;
        lastPadY = y;
        Viewport viewport = remoteInputView.viewport;
        if (padBounds.width() <= 0.0f || padBounds.height() <= 0.0f ||
                viewport.remoteWidth() <= 0 || viewport.remoteHeight() <= 0 || remoteInputView.isViewOnly()) {
            return;
        }
        float sensitivity = 1.35f;
        remoteInputView.moveCursorBy(dx * viewport.remoteWidth() / padBounds.width() * sensitivity,
                dy * viewport.remoteHeight() / padBounds.height() * sensitivity);
    }

    private void movePanel(float rawX, float rawY) {
        float x = downTranslationX + rawX - downRawX;
        float y = downTranslationY + rawY - downRawY;
        if (getParent() instanceof ViewGroup) {
            ViewGroup parent = (ViewGroup) getParent();
            float minX = -getLeft();
            float minY = -getTop();
            float maxX = parent.getWidth() - getLeft() - getWidth();
            float maxY = parent.getHeight() - getTop() - getHeight();
            x = Math.max(minX, Math.min(Math.max(minX, maxX), x));
            y = Math.max(minY, Math.min(Math.max(minY, maxY), y));
        }
        setTranslationX(x);
        setTranslationY(y);
    }

    private void sendWheel(int direction) {
        if (!remoteInputView.isViewOnly()) {
            inputSink.mouse(InputSink.mouseMask(InputSink.MOUSE_WHEEL, 0), 0, direction);
        }
    }

    private int controlAt(float x, float y) {
        for (int i = 0; i < controlBounds.length; i++) {
            if (controlBounds[i].contains(x, y)) {
                return i + 1;
            }
        }
        return CONTROL_NONE;
    }

    private void updateGeometry(int width, int height) {
        float contentWidth = Math.max(0.0f, width - padding * 2.0f);
        float headerBottom = Math.min(height, padding + headerHeight);
        headerBounds.set(padding, padding, width - padding, headerBottom);
        float buttonsTop = Math.max(headerBottom, height - padding - buttonHeight);
        float padTop = headerBottom + dp(7.0f);
        float padBottom = Math.max(padTop, buttonsTop - dp(7.0f));
        padBounds.set(padding, padTop, width - padding, padBottom);
        float gap = dp(5.0f);
        float cellWidth = Math.max(0.0f, (contentWidth - gap * 3.0f) / 4.0f);
        for (int i = 0; i < controlBounds.length; i++) {
            float left = padding + i * (cellWidth + gap);
            controlBounds[i].set(left, buttonsTop, left + cellWidth, buttonsTop + buttonHeight);
        }
    }

    private void drawText(Canvas canvas, String text, float x, float y, float size, int color,
                          Paint.Align align) {
        paint.setColor(color);
        paint.setTextSize(size);
        paint.setTextAlign(align);
        paint.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL));
        paint.setStyle(Paint.Style.FILL);
        canvas.drawText(text, x, y, paint);
    }

    private float dp(float value) {
        return value * density;
    }

    private static int boundedSize(float desired, int measureSpec) {
        int size = (int) Math.ceil(desired);
        int mode = MeasureSpec.getMode(measureSpec);
        int limit = MeasureSpec.getSize(measureSpec);
        if (mode == MeasureSpec.UNSPECIFIED) {
            return size;
        }
        return Math.min(size, limit);
    }
}
