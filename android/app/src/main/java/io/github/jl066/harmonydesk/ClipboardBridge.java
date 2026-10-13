package io.github.jl066.harmonydesk;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Iterator;
import java.util.function.Consumer;

/**
 * Foreground-only plain-text clipboard bridge. The owning Activity should call {@link #start()}
 * while it has window focus and {@link #stop()} as focus is lost.
 */
public final class ClipboardBridge {
    private static final String TAG = "RemoteDeskClipboard";
    private static final int READY = 1;
    private static final int MAX_TEXT_BYTES = 256 * 1024;
    private static final int MAX_PENDING_ECHOES = 16;
    private static final int MAX_PENDING_ECHO_BYTES = 4 * 1024 * 1024;
    private static final long POLL_INTERVAL_MS = 500;

    private static final String STATUS_OFF = "剪贴板同步已关闭";
    private static final String STATUS_PAUSED = "剪贴板同步已暂停";
    private static final String STATUS_WAITING = "剪贴板同步等待连接";
    private static final String STATUS_DENIED = "远端已禁用剪贴板同步";
    private static final String STATUS_ACTIVE = "剪贴板同步已开启（文本）";
    private static final String STATUS_UNAVAILABLE = "剪贴板暂不可用，返回前台后自动重试";
    private static final String STATUS_TOO_LARGE = "剪贴板文本超过 256 KiB，暂不支持同步";
    private static final String STATUS_EMPTY = "文本剪贴板同步已开启；暂不支持同步清空";
    private static final String STATUS_SEND_FAILED = "剪贴板发送暂不可用，正在重试";
    private static final String STATUS_RECEIVE_FAILED = "剪贴板接收暂不可用，正在重试";

    private final ClipboardManager clipboardManager;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ArrayDeque<Echo> pendingEchoes = new ArrayDeque<>();

    private volatile boolean enabled;
    private boolean running;
    private boolean baselineEstablished;
    private boolean localBaselineEstablished;
    private boolean clipboardAllowed;
    private boolean resumeReconciliationPending;
    private boolean resumeReadFailureLogged;
    private boolean localClipboardTooLarge;
    private long generation;
    private long lastRemoteSequence;
    private long localVersion;
    private long localVersionAtRemote;
    private long lastLoggedRemoteSequence = Long.MIN_VALUE;
    private long lastLoggedRemoteFailureSequence = Long.MIN_VALUE;
    private int pendingEchoBytes;
    private boolean sendFailureLogged;
    private String lastLocalText;
    private String pendingLocalText;
    private String lastStatus = "";
    private Consumer<String> statusListener;
    private ClipboardManager.OnPrimaryClipChangedListener clipboardListener;

    public ClipboardBridge(Context context) {
        if (context == null) {
            throw new IllegalArgumentException("context must not be null");
        }
        Context appContext = context.getApplicationContext();
        Context safeContext = appContext != null ? appContext : context;
        this.clipboardManager = (ClipboardManager) safeContext.getSystemService(Context.CLIPBOARD_SERVICE);
    }

    /** Activates polling only while the owning Activity is foregrounded. */
    public void start() {
        onMain(() -> {
            if (running) {
                return;
            }
            running = true;
            generation++;
            logState("start");
            if (enabled) {
                activate(generation);
            } else {
                report(STATUS_OFF);
            }
        });
    }

    /** Stops all polling/listening. No clipboard work is performed while stopped. */
    public void stop() {
        onMain(() -> {
            boolean wasRunning = running;
            if (!wasRunning) {
                return;
            }
            generation++;
            running = false;
            detachClipboardListener();
            mainHandler.removeCallbacksAndMessages(null);
            resumeReconciliationPending = enabled;
            resumeReadFailureLogged = false;
            logState("pause");
            if (enabled) {
                report(STATUS_PAUSED);
            }
        });
    }

    /**
     * Clears clipboard checkpoints for a disconnected remote session. The user's enablement
     * setting is retained so the next connected session can start normally.
     */
    public void resetSession() {
        onMain(() -> {
            generation++;
            running = false;
            detachClipboardListener();
            mainHandler.removeCallbacksAndMessages(null);
            resetSessionState();
            resumeReconciliationPending = false;
            resumeReadFailureLogged = false;
            logState("reset_session");
            report(enabled ? STATUS_WAITING : STATUS_OFF);
        });
    }

    /** Enables or disables synchronization for the current and next foreground session. */
    public void setEnabled(boolean value) {
        onMain(() -> {
            if (enabled == value && !running) {
                report(value ? "剪贴板同步将在前台会话中启用" : STATUS_OFF);
                return;
            }
            if (enabled == value && running) {
                return;
            }
            enabled = value;
            generation++;
            detachClipboardListener();
            mainHandler.removeCallbacksAndMessages(null);
            resumeReconciliationPending = value && localBaselineEstablished;
            resumeReadFailureLogged = false;
            logState(value ? "enable" : "disable");
            if (!value) {
                report(STATUS_OFF);
            } else if (running) {
                activate(generation);
            } else {
                report("剪贴板同步将在前台会话中启用");
            }
        });
    }

    /** Returns the user enablement setting; foreground activity is controlled by start/stop. */
    public boolean isEnabled() {
        return enabled;
    }

    /** Replaces the status callback. Status text is Chinese and never includes clipboard data. */
    public void setStatusListener(Consumer<String> listener) {
        onMain(() -> {
            statusListener = listener;
            if (listener != null && !lastStatus.isEmpty()) {
                invokeStatusListener(listener, lastStatus);
            }
        });
    }

    private void activate(long token) {
        if (!isCurrent(token)) {
            return;
        }
        if (clipboardManager != null) {
            ClipboardManager.OnPrimaryClipChangedListener listener =
                    () -> onLocalClipboardChanged(token);
            clipboardListener = listener;
            try {
                clipboardManager.addPrimaryClipChangedListener(listener);
            } catch (RuntimeException | LinkageError e) {
                clipboardListener = null;
                report(STATUS_UNAVAILABLE);
            }
        } else {
            report(STATUS_UNAVAILABLE);
        }
        poll(token);
    }

    private void poll(long token) {
        if (!isCurrent(token)) {
            return;
        }
        try {
            if (NativeCore.status() != READY) {
                report(STATUS_WAITING);
                schedulePoll(token);
                return;
            }

            boolean allowed = NativeCore.clipboardAllowed();
            if (!allowed) {
                boolean wasAllowed = clipboardAllowed;
                clipboardAllowed = false;
                if (wasAllowed) {
                    logState("allowed_0");
                }
                baselineEstablished = false;
                resumeReconciliationPending = true;
                pendingLocalText = null;
                report(STATUS_DENIED);
                schedulePoll(token);
                return;
            }

            if (!clipboardAllowed) {
                clipboardAllowed = true;
                logState("allowed_1");
            }

            if (resumeReconciliationPending) {
                if (!reconcileLocalOnResume(token)) {
                    schedulePoll(token);
                    return;
                }
                resumeReconciliationPending = false;
            }

            if (!baselineEstablished || !localBaselineEstablished) {
                if (!establishInitialLocalBaseline(token)) {
                    schedulePoll(token);
                    return;
                }
            }

            if (pendingLocalText != null) {
                sendPendingLocal(token);
                if (!isCurrent(token) || pendingLocalText != null) {
                    schedulePoll(token);
                    return;
                }
            }

            processRemoteChange(token);
        } catch (RuntimeException | LinkageError e) {
            if (isCurrent(token)) {
                report(STATUS_UNAVAILABLE);
            }
        }
        schedulePoll(token);
    }

    private void processRemoteChange(long token) {
        long before = NativeCore.clipboardSequence();
        if (before == lastRemoteSequence) {
            return;
        }
        String remote = NativeCore.clipboardText();
        long after = NativeCore.clipboardSequence();
        if (!isCurrent(token) || !clipboardAllowed || before != after) {
            return;
        }
        if (NativeCore.status() != READY) {
            report(STATUS_WAITING);
            return;
        }
        if (!NativeCore.clipboardAllowed()) {
            boolean wasAllowed = clipboardAllowed;
            clipboardAllowed = false;
            if (wasAllowed) {
                logState("allowed_0");
            }
            baselineEstablished = false;
            resumeReconciliationPending = true;
            pendingLocalText = null;
            report(STATUS_DENIED);
            return;
        }

        if (lastLoggedRemoteSequence != after) {
            Log.i(TAG, "event=remote_update seq=" + after + " chars=" + (remote == null ? 0 : remote.length()));
            lastLoggedRemoteSequence = after;
        }
        // A remote empty snapshot is ambiguous in the native API. Observe its sequence but do
        // not erase local data or send the previous local value back over it.
        if (remote == null || remote.isEmpty()) {
            lastRemoteSequence = after;
            localVersionAtRemote = localVersion;
            report(STATUS_EMPTY);
            return;
        }
        if (!isWithinLimit(remote)) {
            lastRemoteSequence = after;
            localVersionAtRemote = localVersion;
            report(STATUS_TOO_LARGE);
            return;
        }

        Echo echo = consumeEcho(remote);
        if (echo != null) {
            lastRemoteSequence = after;
            localVersionAtRemote = Math.max(localVersionAtRemote, echo.localVersion);
            report(STATUS_ACTIVE);
            return;
        }

        if (remote.equals(lastLocalText)) {
            lastRemoteSequence = after;
            localVersionAtRemote = localVersion;
            report(STATUS_ACTIVE);
            return;
        }

        if (localClipboardTooLarge) {
            lastRemoteSequence = after;
            localVersionAtRemote = localVersion;
            report(STATUS_TOO_LARGE);
            return;
        }

        // If a local copy was observed after the last remote generation, preserve and re-send
        // that newer local value instead of replacing it with an older remote snapshot.
        if (localVersion > localVersionAtRemote && lastLocalText != null) {
            pendingLocalText = lastLocalText;
            sendPendingLocal(token);
            return;
        }

        try {
            addEcho(remote, localVersion);
            clipboardManager.setPrimaryClip(ClipData.newPlainText("", remote));
            lastRemoteSequence = after;
            Log.i(TAG, "event=receive result=applied seq=" + after + " bytes=" + remote.getBytes(StandardCharsets.UTF_8).length);
            lastLocalText = remote;
            localVersionAtRemote = localVersion;
            localClipboardTooLarge = false;
            report(STATUS_ACTIVE);
        } catch (RuntimeException | LinkageError e) {
            removeNewestEcho(remote);
            if (lastLoggedRemoteFailureSequence != after) {
                Log.i(TAG, "event=receive result=failed seq=" + after);
                lastLoggedRemoteFailureSequence = after;
            }
            report(STATUS_RECEIVE_FAILED);
        }
    }

    private void onLocalClipboardChanged(long token) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> onLocalClipboardChanged(token));
            return;
        }
        if (!isCurrent(token)) {
            return;
        }
        try {
            if (NativeCore.status() != READY) {
                report(STATUS_WAITING);
                return;
            }
            if (!NativeCore.clipboardAllowed()) {
                boolean wasAllowed = clipboardAllowed;
                clipboardAllowed = false;
                if (wasAllowed) {
                    logState("allowed_0");
                }
                baselineEstablished = false;
                resumeReconciliationPending = true;
                pendingLocalText = null;
                report(STATUS_DENIED);
                return;
            }
            clipboardAllowed = true;

            // This read is reached only from a post-activation clipboard-change notification.
            LocalRead read;
            try {
                read = readLocalText();
            } catch (RuntimeException | LinkageError e) {
                logReadFailure();
                report(STATUS_UNAVAILABLE);
                return;
            }
            if (!read.available) {
                logReadFailure();
                report(STATUS_UNAVAILABLE);
                return;
            }
            resumeReadFailureLogged = false;
            if (!localBaselineEstablished) {
                localBaselineEstablished = true;
                baselineEstablished = true;
                lastRemoteSequence = NativeCore.clipboardSequence();
                localVersionAtRemote = localVersion;
            }
            localClipboardTooLarge = false;
            if (read.tooLarge) {
                localVersion++;
                localClipboardTooLarge = true;
                pendingLocalText = null;
                Log.i(TAG, "event=local_change chars=" + read.characterCount + " result=too_large");
                report(STATUS_TOO_LARGE);
                return;
            }
            if (read.text == null || read.text.isEmpty()) {
                return;
            }

            Echo echo = consumeEcho(read.text);
            if (echo != null) {
                lastLocalText = read.text;
                localVersionAtRemote = Math.max(localVersionAtRemote, echo.localVersion);
                return;
            }
            if (read.text.equals(lastLocalText)) {
                return;
            }

            localClipboardTooLarge = false;
            lastLocalText = read.text;
            localVersion++;
            pendingLocalText = read.text;
            sendFailureLogged = false;
            Log.i(TAG, "event=local_change bytes=" + read.byteCount + " result=pending");
            establishBaseline();
            sendPendingLocal(token);
        } catch (RuntimeException | LinkageError e) {
            if (isCurrent(token)) {
                report(STATUS_UNAVAILABLE);
            }
        }
    }

    private LocalRead readLocalText() {
        if (clipboardManager == null) {
            return LocalRead.UNAVAILABLE;
        }
        if (!clipboardManager.hasPrimaryClip()) {
            return LocalRead.EMPTY;
        }
        ClipData clip = clipboardManager.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) {
            return LocalRead.EMPTY;
        }
        ClipDescription description = clip.getDescription();
        if (description == null || !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) {
            return LocalRead.EMPTY;
        }
        CharSequence value = clip.getItemAt(0).getText();
        if (value == null || value.length() == 0) {
            return LocalRead.EMPTY;
        }
        if (value.length() > MAX_TEXT_BYTES) {
            return LocalRead.tooLarge(value.length());
        }
        String text = value.toString();
        if (!isWithinLimit(text)) {
            return LocalRead.tooLarge(text.length());
        }
        return new LocalRead(text, false, true, text.length(), text.getBytes(StandardCharsets.UTF_8).length);
    }

    private void sendPendingLocal(long token) {
        if (!isCurrent(token) || pendingLocalText == null) {
            return;
        }
        if (NativeCore.status() != READY) {
            report(STATUS_WAITING);
            return;
        }
        if (!NativeCore.clipboardAllowed()) {
            boolean wasAllowed = clipboardAllowed;
            clipboardAllowed = false;
            if (wasAllowed) {
                logState("allowed_0");
            }
            baselineEstablished = false;
            resumeReconciliationPending = true;
            pendingLocalText = null;
            report(STATUS_DENIED);
            return;
        }
        String text = pendingLocalText;
        try {
            int result = NativeCore.sendClipboard(text);
            if (result == 0 || !sendFailureLogged) {
                Log.i(TAG, "event=send result=" + result + " bytes=" + text.getBytes(StandardCharsets.UTF_8).length);
            }
            if (result != 0) {
                sendFailureLogged = true;
                report(STATUS_SEND_FAILED);
                return;
            }
            sendFailureLogged = false;
            pendingLocalText = null;
            addEcho(text, localVersion);
            localVersionAtRemote = Math.max(localVersionAtRemote, localVersion);
            report(STATUS_ACTIVE);
        } catch (RuntimeException | LinkageError e) {
            if (!sendFailureLogged) {
                Log.i(TAG, "event=send_failure result=exception");
                sendFailureLogged = true;
            }
            report(STATUS_SEND_FAILED);
        }
    }

    /**
     * Reconciles once after foreground resume. If both sides changed while paused, a changed
     * local clipboard wins and the current remote sequence is consumed; otherwise the retained
     * remote checkpoint is left untouched so the latest remote update can be applied below.
     */
    private boolean reconcileLocalOnResume(long token) {
        if (!isCurrent(token)) {
            return false;
        }
        LocalRead read;
        try {
            read = readLocalText();
        } catch (RuntimeException | LinkageError e) {
            logReadFailure();
            report(STATUS_UNAVAILABLE);
            return false;
        }
        if (!read.available) {
            logReadFailure();
            report(STATUS_UNAVAILABLE);
            return false;
        }
        resumeReadFailureLogged = false;

        long sequenceAtResume = NativeCore.clipboardSequence();
        boolean localChanged = read.tooLarge
                ? true
                : read.text != null && !read.text.isEmpty() && !read.text.equals(lastLocalText);
        ResumeDecision decision = decideResume(localBaselineEstablished, localChanged,
                sequenceAtResume != lastRemoteSequence);
        if (decision == ResumeDecision.INITIAL_BASELINE) {
            acceptInitialLocalBaseline(read, sequenceAtResume);
            return true;
        }
        baselineEstablished = true;

        if (read.tooLarge) {
            localVersion++;
            localClipboardTooLarge = true;
            Log.i(TAG, "event=resume_local chars=" + read.characterCount + " result=too_large");
            report(STATUS_TOO_LARGE);
            return true;
        }
        if (read.text == null || read.text.isEmpty()) {
            return true;
        }

        Echo echo = consumeEcho(read.text);
        if (echo != null) {
            lastLocalText = read.text;
            localVersionAtRemote = Math.max(localVersionAtRemote, echo.localVersion);
            Log.i(TAG, "event=resume_local bytes=" + read.byteCount + " result=echo");
            return true;
        }
        if (decision != ResumeDecision.LOCAL_WINS) {
            Log.i(TAG, "event=resume_local bytes=" + read.byteCount + " result=unchanged");
            return true;
        }

        localClipboardTooLarge = false;
        lastLocalText = read.text;
        localVersion++;
        pendingLocalText = read.text;
        lastRemoteSequence = sequenceAtResume;
        localVersionAtRemote = localVersion;
        sendFailureLogged = false;
        Log.i(TAG, "event=resume_local bytes=" + read.byteCount + " result=local_wins seq=" + sequenceAtResume);
        return true;
    }

    private boolean establishInitialLocalBaseline(long token) {
        if (!isCurrent(token)) {
            return false;
        }
        LocalRead read;
        try {
            read = readLocalText();
        } catch (RuntimeException | LinkageError e) {
            logReadFailure();
            report(STATUS_UNAVAILABLE);
            return false;
        }
        if (!read.available) {
            logReadFailure();
            report(STATUS_UNAVAILABLE);
            return false;
        }
        resumeReadFailureLogged = false;
        acceptInitialLocalBaseline(read, NativeCore.clipboardSequence());
        return true;
    }

    private void acceptInitialLocalBaseline(LocalRead read, long currentRemoteSequence) {
        localBaselineEstablished = true;
        baselineEstablished = true;
        localClipboardTooLarge = read.tooLarge;
        lastLocalText = read.tooLarge ? null : read.text;
        localVersionAtRemote = localVersion;
        // A new native connection resets its sequence to zero. Keeping zero here allows a
        // remote update received before foreground activation to be applied after this snapshot.
        lastRemoteSequence = 0;
        Log.i(TAG, "event=baseline observed_seq=" + currentRemoteSequence + " chars=" + read.characterCount +
                " bytes=" + (read.tooLarge ? -1 : read.byteCount) +
                " result=" + (read.tooLarge ? "too_large" : "ok"));
        report(read.tooLarge ? STATUS_TOO_LARGE : STATUS_ACTIVE);
    }

    enum ResumeDecision {
        INITIAL_BASELINE,
        LOCAL_WINS,
        REMOTE_WINS,
        NO_CHANGE
    }

    static ResumeDecision decideResume(boolean localBaselineKnown, boolean localChanged,
            boolean remoteChanged) {
        if (!localBaselineKnown) {
            return ResumeDecision.INITIAL_BASELINE;
        }
        if (localChanged) {
            return ResumeDecision.LOCAL_WINS;
        }
        return remoteChanged ? ResumeDecision.REMOTE_WINS : ResumeDecision.NO_CHANGE;
    }

    private void logReadFailure() {
        if (!resumeReadFailureLogged) {
            Log.i(TAG, "event=read_failure count=1");
            resumeReadFailureLogged = true;
        }
    }

    private void logState(String event) {
        Log.i(TAG, "event=" + event + " enabled=" + (enabled ? 1 : 0) +
                " running=" + (running ? 1 : 0) + " allowed=" + (clipboardAllowed ? 1 : 0) +
                " seq=" + lastRemoteSequence);
    }

    private void establishBaseline() {
        lastRemoteSequence = NativeCore.clipboardSequence();
        baselineEstablished = true;
        localBaselineEstablished = true;
        localVersionAtRemote = localVersion;
    }

    private void schedulePoll(long token) {
        if (isCurrent(token)) {
            mainHandler.postDelayed(() -> poll(token), POLL_INTERVAL_MS);
        }
    }

    private boolean isCurrent(long token) {
        return running && enabled && generation == token;
    }

    private void detachClipboardListener() {
        ClipboardManager.OnPrimaryClipChangedListener listener = clipboardListener;
        clipboardListener = null;
        if (listener != null && clipboardManager != null) {
            try {
                clipboardManager.removePrimaryClipChangedListener(listener);
            } catch (RuntimeException | LinkageError ignored) {
                // Stopping must remain safe even if the platform service has already gone away.
            }
        }
    }

    private void resetSessionState() {
        baselineEstablished = false;
        localBaselineEstablished = false;
        clipboardAllowed = false;
        resumeReconciliationPending = false;
        resumeReadFailureLogged = false;
        localClipboardTooLarge = false;
        lastRemoteSequence = 0;
        localVersion = 0;
        localVersionAtRemote = 0;
        lastLocalText = null;
        pendingLocalText = null;
        pendingEchoes.clear();
        pendingEchoBytes = 0;
        lastLoggedRemoteSequence = Long.MIN_VALUE;
        lastLoggedRemoteFailureSequence = Long.MIN_VALUE;
        sendFailureLogged = false;
    }

    private void addEcho(String text, long version) {
        removeEcho(text);
        pendingEchoes.addLast(new Echo(text, version));
        pendingEchoBytes += text.getBytes(StandardCharsets.UTF_8).length;
        while (pendingEchoes.size() > MAX_PENDING_ECHOES ||
                pendingEchoBytes > MAX_PENDING_ECHO_BYTES) {
            Echo removed = pendingEchoes.removeFirst();
            pendingEchoBytes -= removed.bytes;
        }
    }

    private Echo consumeEcho(String text) {
        Iterator<Echo> iterator = pendingEchoes.iterator();
        while (iterator.hasNext()) {
            Echo echo = iterator.next();
            if (echo.text.equals(text)) {
                iterator.remove();
                pendingEchoBytes -= echo.bytes;
                return echo;
            }
        }
        return null;
    }

    private void removeEcho(String text) {
        Iterator<Echo> iterator = pendingEchoes.iterator();
        while (iterator.hasNext()) {
            Echo echo = iterator.next();
            if (echo.text.equals(text)) {
                iterator.remove();
                pendingEchoBytes -= echo.bytes;
            }
        }
    }

    private void removeNewestEcho(String text) {
        Iterator<Echo> iterator = pendingEchoes.descendingIterator();
        while (iterator.hasNext()) {
            Echo echo = iterator.next();
            if (echo.text.equals(text)) {
                iterator.remove();
                pendingEchoBytes -= echo.bytes;
                return;
            }
        }
    }

    private static boolean isWithinLimit(String text) {
        if (text == null || text.length() > MAX_TEXT_BYTES) {
            return false;
        }
        return text.getBytes(StandardCharsets.UTF_8).length <= MAX_TEXT_BYTES;
    }

    private void report(String status) {
        if (status.equals(lastStatus)) {
            return;
        }
        lastStatus = status;
        Consumer<String> listener = statusListener;
        if (listener != null) {
            invokeStatusListener(listener, status);
        }
    }

    private static void invokeStatusListener(Consumer<String> listener, String status) {
        try {
            listener.accept(status);
        } catch (RuntimeException ignored) {
            // UI callback failures must not interrupt the clipboard state machine.
        }
    }

    private void onMain(Runnable action) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action.run();
        } else {
            mainHandler.post(action);
        }
    }

    private static final class LocalRead {
        static final LocalRead EMPTY = new LocalRead(null, false, true, 0, 0);
        static final LocalRead UNAVAILABLE = new LocalRead(null, false, false, 0, 0);

        final String text;
        final boolean tooLarge;
        final boolean available;
        final int characterCount;
        final int byteCount;

        LocalRead(String text, boolean tooLarge, boolean available, int characterCount, int byteCount) {
            this.text = text;
            this.tooLarge = tooLarge;
            this.available = available;
            this.characterCount = characterCount;
            this.byteCount = byteCount;
        }

        static LocalRead tooLarge(int characterCount) {
            return new LocalRead(null, true, true, characterCount, 0);
        }
    }

    private static final class Echo {
        final String text;
        final long localVersion;
        final int bytes;

        Echo(String text, long localVersion) {
            this.text = text;
            this.localVersion = localVersion;
            this.bytes = text.getBytes(StandardCharsets.UTF_8).length;
        }
    }
}
