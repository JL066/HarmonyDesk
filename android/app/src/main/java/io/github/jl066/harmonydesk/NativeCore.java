package io.github.jl066.harmonydesk;

/** Thin JNI surface for the process-wide RustDesk core. */
public final class NativeCore {
    static {
        System.loadLibrary("hdcore");
        System.loadLibrary("androidbridge");
    }

    private NativeCore() {}

    public static native int init();

    public static native int configure(String idServer, String relay, boolean forceRelay, String key);

    /** 0 legacy direct allowed, 1 relay only, 2 automatic LAN direct / external relay. */
    public static native int setRoutePolicy(int policy);

    /** 0 pending, 1 LAN direct, 2 relay, 3 other direct. */
    public static native int routeKind();

    /** Starts an asynchronous connection attempt. Poll status() for progress. */
    public static native int connect(String peer, String password);

    /** 0=idle, 1=ready, 2=connecting, 3=failed (see core limitations). */
    public static native int status();

    public static native void disconnect();

    public static native String error();

    public static native int width();

    public static native int height();

    /** Numeric-only diagnostics; no peer IDs, addresses or content. */
    public static native int queueDepth();

    public static native int receivedFrames();

    /** Codec metadata for the packet most recently returned by nextPacket(). */
    public static native String codec();

    /** Returns one encoded access unit, or null when the queue is empty. */
    public static native byte[] nextPacket();

    /** Keyframe metadata for the packet most recently returned by nextPacket(). */
    public static native boolean packetIsKey();

    public static native void requestKeyframe();

    public static native void mouse(int mask, int x, int y);

    /** kind=1 for a character, kind=2 for a RustDesk ControlKey. */
    public static native void key(int kind, int code, boolean down, int[] modifiers);

    public static native void text(String text);

    /** Sends a tapped ControlKey. */
    public static native void control(int code);

    public static native long clipboardSequence();

    public static native String clipboardText();

    public static native boolean clipboardAllowed();

    public static native int sendClipboard(String text);
}
