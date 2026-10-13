package io.github.jl066.harmonydesk;

/** Small executable checks for the pause/resume clipboard conflict policy. */
public final class ClipboardBridgePolicyTest {
    public static void main(String[] args) {
        expect(ClipboardBridge.ResumeDecision.REMOTE_WINS,
                ClipboardBridge.decideResume(true, false, true),
                "unchanged local clipboard must leave a paused remote update pending");
        expect(ClipboardBridge.ResumeDecision.LOCAL_WINS,
                ClipboardBridge.decideResume(true, true, true),
                "changed local clipboard must win a simultaneous paused remote update");
        expect(ClipboardBridge.ResumeDecision.INITIAL_BASELINE,
                ClipboardBridge.decideResume(false, true, true),
                "unknown local state must be snapshotted before conflict resolution");
        expect(ClipboardBridge.ResumeDecision.NO_CHANGE,
                ClipboardBridge.decideResume(true, false, false),
                "unchanged snapshots must not create a transfer");
    }

    private static void expect(ClipboardBridge.ResumeDecision expected,
            ClipboardBridge.ResumeDecision actual, String message) {
        if (expected != actual) {
            throw new AssertionError(message + ": expected " + expected + ", got " + actual);
        }
    }
}
