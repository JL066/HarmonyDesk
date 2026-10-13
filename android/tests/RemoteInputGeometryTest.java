package io.github.jl066.harmonydesk;

public final class RemoteInputGeometryTest {
    private static int assertions;

    public static void main(String[] args) {
        fitLetterboxesAndMapsPixels();
        fillCropsWithoutProducingOutOfRangeCoordinates();
        originalSizeAndPanRespectViewBounds();
        zoomKeepsTheFocusPixelAnchored();
        resizeRecomputesForFoldAndRotationChanges();
        rustDeskMouseMasksMatchNativeEncoding();
        androidHardwareKeysMapToRustDeskControls();
        imeCompositionFinishesExactlyOnce();
        imeCommitAndCancellationDoNotReemitComposition();
        System.out.println("PASS: " + assertions + " Android input geometry and mask assertions");
    }

    private static void fitLetterboxesAndMapsPixels() {
        Viewport viewport = viewport(1280, 800, 1920, 1080, Viewport.Mode.FIT);
        near(2.0f / 3.0f, viewport.scale(), 0.0001f, "FIT scale");
        near(0.0f, viewport.offsetX(), 0.01f, "FIT horizontal offset");
        near(40.0f, viewport.offsetY(), 0.01f, "FIT vertical letterbox");
        point(960, 540, viewport.mapViewToRemote(640, 400), "FIT center");
        check(viewport.mapViewToRemote(100, 20) == null, "FIT rejects top letterbox");
        check(viewport.mapViewToRemote(-1, 400) == null, "FIT rejects outside view");
    }

    private static void fillCropsWithoutProducingOutOfRangeCoordinates() {
        Viewport viewport = viewport(1000, 1000, 1920, 1080, Viewport.Mode.FILL);
        near(1000.0f / 1080.0f, viewport.scale(), 0.0001f, "FILL scale");
        check(viewport.offsetX() < 0, "FILL crops horizontal edges");
        point(960, 540, viewport.mapViewToRemote(500, 500), "FILL center");
        Viewport.RemotePoint left = viewport.mapViewToRemote(0, 500);
        check(left != null && left.x > 0 && left.x < 960, "FILL left edge maps into cropped remote image");
        check(viewport.mapViewToRemote(1000, 500) == null, "right boundary is exclusive");
    }

    private static void originalSizeAndPanRespectViewBounds() {
        Viewport viewport = viewport(800, 600, 1920, 1080, Viewport.Mode.ORIGINAL);
        near(1.0f, viewport.scale(), 0.0001f, "ORIGINAL scale");
        near(-560.0f, viewport.offsetX(), 0.01f, "ORIGINAL crop origin x");
        near(-240.0f, viewport.offsetY(), 0.01f, "ORIGINAL crop origin y");
        point(560, 240, viewport.mapViewToRemote(0, 0), "ORIGINAL visible crop");
        viewport.panBy(10_000.0f, 10_000.0f);
        near(0.0f, viewport.offsetX(), 0.01f, "pan clamps at left edge");
        near(0.0f, viewport.offsetY(), 0.01f, "pan clamps at top edge");
        viewport.panBy(-20_000.0f, -20_000.0f);
        near(-1120.0f, viewport.offsetX(), 0.01f, "pan clamps at right edge");
        near(-480.0f, viewport.offsetY(), 0.01f, "pan clamps at bottom edge");
    }

    private static void zoomKeepsTheFocusPixelAnchored() {
        Viewport viewport = viewport(1000, 700, 1600, 900, Viewport.Mode.FIT);
        Viewport.RemotePoint before = viewport.mapViewToRemote(300, 280);
        viewport.zoomAround(2.0f, 300, 280);
        float[] after = viewport.mapRemoteToView(before.x, before.y);
        near(300.0f, after[0], 1.5f, "zoom focus x");
        near(280.0f, after[1], 1.5f, "zoom focus y");
        viewport.zoomAround(100.0f, 500, 350);
        near(5.0f, viewport.userZoom(), 0.0001f, "zoom upper bound");
        viewport.setUserZoom(0.0f);
        near(0.5f, viewport.userZoom(), 0.0001f, "zoom lower bound");
    }

    private static void resizeRecomputesForFoldAndRotationChanges() {
        Viewport viewport = viewport(1200, 800, 2560, 1600, Viewport.Mode.FIT);
        near(0.46875f, viewport.scale(), 0.0001f, "wide content scale");
        viewport.setViewSize(800, 1200);
        near(0.3125f, viewport.scale(), 0.0001f, "portrait/folded content scale");
        point(1280, 800, viewport.mapViewToRemote(400, 600), "resized center remains aligned");
    }

    private static void rustDeskMouseMasksMatchNativeEncoding() {
        equal(0, InputSink.mouseMask(InputSink.MOUSE_MOVE, 0), "move mask");
        equal(3, InputSink.mouseMask(InputSink.MOUSE_WHEEL, 0), "wheel mask");
        equal(9, InputSink.mouseMask(InputSink.MOUSE_BUTTON_DOWN, InputSink.BUTTON_LEFT), "left down");
        equal(10, InputSink.mouseMask(InputSink.MOUSE_BUTTON_UP, InputSink.BUTTON_LEFT), "left up");
        equal(17, InputSink.mouseMask(InputSink.MOUSE_BUTTON_DOWN, InputSink.BUTTON_RIGHT), "right down");
        equal(18, InputSink.mouseMask(InputSink.MOUSE_BUTTON_UP, InputSink.BUTTON_RIGHT), "right up");
        equal(33, InputSink.mouseMask(InputSink.MOUSE_BUTTON_DOWN, InputSink.BUTTON_MIDDLE), "middle down");
        equal(34, InputSink.mouseMask(InputSink.MOUSE_BUTTON_UP, InputSink.BUTTON_MIDDLE), "middle up");
    }

    private static void androidHardwareKeysMapToRustDeskControls() {
        int[][] keys = {
                {57, 1}, {58, 75}, {59, 29}, {60, 73}, {61, 31}, {62, 30}, {66, 27},
                {67, 2}, {19, 32}, {20, 6}, {21, 22}, {22, 28}, {92, 26}, {93, 25},
                {111, 8}, {112, 5}, {113, 4}, {114, 74}, {115, 3}, {116, 62}, {117, 23},
                {118, 64}, {122, 21}, {123, 7}, {124, 58}, {131, 9}, {132, 13}, {133, 14},
                {134, 15}, {135, 16}, {136, 17}, {137, 18}, {138, 19}, {139, 20},
                {140, 10}, {141, 11}, {142, 12}, {143, 63}, {144, 33}, {145, 34},
                {146, 35}, {147, 36}, {148, 37}, {149, 38}, {150, 39}, {151, 40},
                {152, 41}, {153, 42}, {154, 70}, {155, 66}, {156, 68}, {157, 67},
                {158, 69}, {159, 61}, {160, 72}, {161, 71}
        };
        for (int[] key : keys) {
            equal(key[1], InputSink.controlCodeForAndroidKeyCode(key[0]),
                    "Android keycode " + key[0]);
        }
        equal(0, InputSink.controlCodeForAndroidKeyCode(999), "unknown key stays unhandled");
        check(InputSink.isModifierControlCode(74), "right Ctrl is tracked as a modifier");
        check(!InputSink.isModifierControlCode(27), "Enter is not a modifier");
        equal(1, InputSink.modifierGroup(74), "left and right Ctrl share a group");
    }

    private static void imeCompositionFinishesExactlyOnce() {
        InputSink.CompositionGate gate = new InputSink.CompositionGate();
        gate.beginComposing();
        equal("你好", gate.finish("你好"), "finish forwards the composing text");
        check(gate.finish("你好") == null, "repeated finish does not forward stale text");
        gate.beginComposing();
        equal("世界", gate.finish("世界"), "a new composition can finish independently");
        gate.beginComposing();
        check(gate.finish("") == null, "empty composition is not forwarded");
    }

    private static void imeCommitAndCancellationDoNotReemitComposition() {
        InputSink.CompositionGate gate = new InputSink.CompositionGate();
        gate.beginComposing();
        gate.beginCommit();
        check(gate.finish("committed") == null, "nested finish during commit is suppressed");
        gate.endCommit();
        check(gate.finish("committed") == null, "commit path does not leave stale composition");

        gate.beginComposing();
        gate.beginDiscard();
        check(gate.finish("stale") == null, "focus cancellation discards pending composition");
        gate.endDiscard();
        check(gate.finish("stale") == null, "discarded text stays suppressed after cancellation");
        gate.beginComposing();
        equal("fresh", gate.finish("fresh"), "input resumes after cancellation cleanup");
    }

    private static Viewport viewport(int viewWidth, int viewHeight, int remoteWidth, int remoteHeight,
                                    Viewport.Mode mode) {
        Viewport viewport = new Viewport();
        viewport.setViewSize(viewWidth, viewHeight);
        viewport.setRemoteSize(remoteWidth, remoteHeight);
        viewport.setMode(mode);
        return viewport;
    }

    private static void point(int x, int y, Viewport.RemotePoint point, String description) {
        check(point != null, description + " exists");
        equal(x, point.x, description + " x");
        equal(y, point.y, description + " y");
    }

    private static void near(float expected, float actual, float tolerance, String description) {
        check(Math.abs(expected - actual) <= tolerance,
                description + " expected " + expected + " but got " + actual);
    }

    private static void equal(int expected, int actual, String description) {
        check(expected == actual, description + " expected " + expected + " but got " + actual);
    }

    private static void equal(String expected, String actual, String description) {
        check(expected.equals(actual), description + " expected " + expected + " but got " + actual);
    }

    private static void check(boolean condition, String description) {
        assertions++;
        if (!condition) {
            throw new AssertionError(description);
        }
    }
}
