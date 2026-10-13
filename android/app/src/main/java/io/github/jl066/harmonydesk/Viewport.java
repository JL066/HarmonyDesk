package io.github.jl066.harmonydesk;

/** Pixel-accurate mapping between a remote frame and the local content view. */
public final class Viewport {
    public enum Mode {
        FIT,
        FILL,
        ORIGINAL
    }

    public static final class RemotePoint {
        public final int x;
        public final int y;

        private RemotePoint(int x, int y) {
            this.x = x;
            this.y = y;
        }
    }

    private int viewWidth;
    private int viewHeight;
    private int remoteWidth;
    private int remoteHeight;
    private Mode mode = Mode.FIT;
    private float userZoom = 1.0f;
    private float baseScale = 1.0f;
    private float scale = 1.0f;
    private float renderedWidth;
    private float renderedHeight;
    private float offsetX;
    private float offsetY;
    private float panX;
    private float panY;

    public void setViewSize(int width, int height) {
        viewWidth = Math.max(0, width);
        viewHeight = Math.max(0, height);
        recompute();
    }

    public void setRemoteSize(int width, int height) {
        remoteWidth = Math.max(0, width);
        remoteHeight = Math.max(0, height);
        recompute();
    }

    public void setMode(Mode newMode) {
        if (newMode == null || mode == newMode) {
            return;
        }
        mode = newMode;
        panX = 0.0f;
        panY = 0.0f;
        recompute();
    }

    public Mode mode() {
        return mode;
    }

    public void setUserZoom(float zoom) {
        if (!Float.isFinite(zoom)) {
            return;
        }
        userZoom = clamp(zoom, 0.5f, 5.0f);
        recompute();
    }

    /** Zoom while keeping the remote pixel beneath the local focus point stationary. */
    public void zoomAround(float factor, float focusX, float focusY) {
        if (!Float.isFinite(factor) || factor <= 0.0f || remoteWidth <= 0 || remoteHeight <= 0) {
            return;
        }
        RemotePoint focusRemote = mapViewToRemote(focusX, focusY);
        float remoteX = focusRemote == null ? remoteWidth / 2.0f : focusRemote.x;
        float remoteY = focusRemote == null ? remoteHeight / 2.0f : focusRemote.y;
        userZoom = clamp(userZoom * factor, 0.5f, 5.0f);
        recompute();
        if (focusRemote != null) {
            panX = focusX - remoteX * scale - (viewWidth - renderedWidth) / 2.0f;
            panY = focusY - remoteY * scale - (viewHeight - renderedHeight) / 2.0f;
            recompute();
        }
    }

    /** Move a zoomed frame in local pixels. Content smaller than the view stays centered. */
    public void panBy(float dx, float dy) {
        if (!Float.isFinite(dx) || !Float.isFinite(dy)) {
            return;
        }
        panX += dx;
        panY += dy;
        recompute();
    }

    public int viewWidth() {
        return viewWidth;
    }

    public int viewHeight() {
        return viewHeight;
    }

    public int remoteWidth() {
        return remoteWidth;
    }

    public int remoteHeight() {
        return remoteHeight;
    }

    public float scale() {
        return scale;
    }

    public float userZoom() {
        return userZoom;
    }

    public float offsetX() {
        return offsetX;
    }

    public float offsetY() {
        return offsetY;
    }

    public float renderedWidth() {
        return renderedWidth;
    }

    public float renderedHeight() {
        return renderedHeight;
    }

    /** Returns null for letterbox space or an unavailable/invalid viewport. */
    public RemotePoint mapViewToRemote(float x, float y) {
        if (remoteWidth <= 0 || remoteHeight <= 0 || viewWidth <= 0 || viewHeight <= 0 ||
                !Float.isFinite(x) || !Float.isFinite(y) || x < 0 || y < 0 ||
                x >= viewWidth || y >= viewHeight || scale <= 0.0f) {
            return null;
        }
        float remoteX = (x - offsetX) / scale;
        float remoteY = (y - offsetY) / scale;
        if (remoteX < 0 || remoteY < 0 || remoteX >= remoteWidth || remoteY >= remoteHeight) {
            return null;
        }
        int ix = Math.min(remoteWidth - 1, Math.max(0, (int) remoteX));
        int iy = Math.min(remoteHeight - 1, Math.max(0, (int) remoteY));
        return new RemotePoint(ix, iy);
    }

    /** Maps a remote pixel to its local view location. */
    public float[] mapRemoteToView(float x, float y) {
        if (remoteWidth <= 0 || remoteHeight <= 0 || !Float.isFinite(x) || !Float.isFinite(y)) {
            return null;
        }
        return new float[]{offsetX + x * scale, offsetY + y * scale};
    }

    private void recompute() {
        if (viewWidth <= 0 || viewHeight <= 0 || remoteWidth <= 0 || remoteHeight <= 0) {
            baseScale = 1.0f;
            scale = 1.0f;
            renderedWidth = remoteWidth;
            renderedHeight = remoteHeight;
            offsetX = 0.0f;
            offsetY = 0.0f;
            return;
        }
        if (mode == Mode.ORIGINAL) {
            baseScale = 1.0f;
        } else {
            float sx = viewWidth / (float) remoteWidth;
            float sy = viewHeight / (float) remoteHeight;
            baseScale = mode == Mode.FILL ? Math.max(sx, sy) : Math.min(sx, sy);
        }
        scale = baseScale * userZoom;
        renderedWidth = remoteWidth * scale;
        renderedHeight = remoteHeight * scale;
        panX = constrain(panX, viewWidth, renderedWidth);
        panY = constrain(panY, viewHeight, renderedHeight);
        offsetX = (viewWidth - renderedWidth) / 2.0f + panX;
        offsetY = (viewHeight - renderedHeight) / 2.0f + panY;
    }

    private static float constrain(float pan, float viewport, float rendered) {
        if (rendered <= viewport) {
            return 0.0f;
        }
        float limit = (rendered - viewport) / 2.0f;
        return clamp(pan, -limit, limit);
    }

    private static float clamp(float value, float min, float max) {
        return Math.max(min, Math.min(max, value));
    }
}
