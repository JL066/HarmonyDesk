package io.github.jl066.harmonydesk;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Surface;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/** Feeds RustDesk H.264/H.265 access units to Android MediaCodec and renders to a caller-owned Surface. */
public final class VideoDecoder {
    private static final int MAX_PACKET_BYTES = 8 * 1024 * 1024;
    private static final int MAX_NAL_UNITS = 4096;
    private static final int MAX_CODEC_CONFIG_BYTES = 1024 * 1024;
    private static final int MAX_DIMENSION = 8192;
    private static final long MAX_PIXELS = 33_177_600L;
    private static final long KEYFRAME_REQUEST_INTERVAL_MS = 1500L;
    private static final long ERROR_RETRY_DELAY_MS = 100L;
    private static final long PERF_LOG_INTERVAL_MS = 5000L;
    private static final Object PACKET_READ_LOCK = new Object();
    private static final Object ACTIVE_CONSUMER_LOCK = new Object();
    private static VideoDecoder activePacketConsumer;

    public interface Listener {
        void onSize(int width, int height);

        void onError(String message);
    }

    private static final class Packet {
        final byte[] data;
        final String codec;
        final boolean key;
        final long presentationTimeUs;
        byte[] annexB;
        boolean codecConfigScanned;

        Packet(byte[] data, String codec, boolean key, long presentationTimeUs) {
            this.data = data;
            this.codec = codec;
            this.key = key;
            this.presentationTimeUs = presentationTimeUs;
        }
    }

    private static final class CodecCandidate {
        final MediaCodecInfo info;
        final boolean hardware;
        final boolean lowLatency;

        CodecCandidate(MediaCodecInfo info, boolean hardware, boolean lowLatency) {
            this.info = info;
            this.hardware = hardware;
            this.lowLatency = lowLatency;
        }
    }

    private static final class CodecSelection {
        final MediaCodec codec;
        final int hardware;
        final int lowLatency;

        CodecSelection(MediaCodec codec, int hardware, int lowLatency) {
            this.codec = codec;
            this.hardware = hardware;
            this.lowLatency = lowLatency;
        }
    }

    private final Surface surface;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final List<Runnable> stopCallbacks = new ArrayList<>();

    private volatile boolean running;
    private volatile boolean callbacksEnabled;
    private Thread worker;

    // All decoder state below is owned by worker.
    private MediaCodec mediaCodec;
    private String activeCodec = "";
    private String observedCodec = "";
    private int activeWidth;
    private int activeHeight;
    private boolean haveKeyframe;
    private int lastNotifiedWidth;
    private int lastNotifiedHeight;
    private long lastKeyframeRequestMs;
    private long lastPresentationTimeUs;
    private long lastPostedErrorMs;
    private String lastPostedError = "";
    private byte[] cachedH264Sps;
    private byte[] cachedH264Pps;
    private byte[] cachedHevcVps;
    private byte[] cachedHevcSps;
    private byte[] cachedHevcPps;
    private long perfStartMs;
    private long perfWindowStartMs;
    private long firstOutputElapsedMs = -1L;
    private int perfLastReceivedFrames = -1;
    private int perfInputStalls;
    private int perfRenderedFrames;
    private int perfDiscardedFrames;
    private int activeCodecId;
    private int activeHardware = -1;
    private int activeLowLatency;

    public VideoDecoder(Surface surface, Listener listener) {
        if (surface == null) {
            throw new IllegalArgumentException("Surface is required");
        }
        this.surface = surface;
        this.listener = listener;
    }

    /** Starts the polling and decode loop on a dedicated thread. */
    public synchronized void start() {
        if (running) {
            return;
        }
        if (worker != null && worker.isAlive()) {
            throw new IllegalStateException("The previous decoder thread is still stopping");
        }
        final Thread nextWorker = new Thread(this::runLoop, "HarmonyDeskVideoDecoder");
        synchronized (ACTIVE_CONSUMER_LOCK) {
            if (activePacketConsumer != null) {
                throw new IllegalStateException("Another video decoder is still stopping");
            }
            activePacketConsumer = this;
        }
        lastNotifiedWidth = 0;
        lastNotifiedHeight = 0;
        perfStartMs = SystemClock.elapsedRealtime();
        perfWindowStartMs = perfStartMs;
        firstOutputElapsedMs = -1L;
        perfLastReceivedFrames = readReceivedFrames();
        perfInputStalls = 0;
        perfRenderedFrames = 0;
        perfDiscardedFrames = 0;
        callbacksEnabled = true;
        running = true;
        worker = nextWorker;
        try {
            nextWorker.start();
        } catch (RuntimeException | Error e) {
            worker = null;
            running = false;
            synchronized (ACTIVE_CONSUMER_LOCK) {
                if (activePacketConsumer == this) {
                    activePacketConsumer = null;
                }
            }
            throw e;
        }
    }

    /**
     * Stops polling, releases MediaCodec on its owner thread, and waits at most two seconds.
     * Returns false if the worker is still stopping; keep the caller-owned Surface alive then.
     */
    public boolean stop() {
        return stop(null);
    }

    /**
     * Requests shutdown, waits at most two seconds, and runs {@code onStopped}
     * on the main thread after MediaCodec is released and this decoder no
     * longer owns the process-wide video packet stream. If this returns false,
     * keep the Surface alive until the callback runs.
     */
    public boolean stop(Runnable onStopped) {
        Thread thread;
        synchronized (this) {
            if (onStopped != null) {
                stopCallbacks.add(onStopped);
            }
            callbacksEnabled = false;
            running = false;
            thread = worker;
            if (thread != null) {
                thread.interrupt();
            }
        }
        if (thread != null && thread != Thread.currentThread()) {
            try {
                thread.join(2000L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        final boolean stopped = thread == null || !thread.isAlive();
        if (stopped) {
            clearStoppedWorker(thread);
            postStopCallbacks();
        } else if (onStopped != null) {
            watchForStop(thread);
        }
        return stopped;
    }

    private void watchForStop(Thread thread) {
        Thread waiter = new Thread(() -> {
            boolean interrupted = false;
            while (thread.isAlive()) {
                try {
                    thread.join();
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
            clearStoppedWorker(thread);
            postStopCallbacks();
        }, "HarmonyDeskVideoDecoderStopWaiter");
        waiter.setDaemon(true);
        waiter.start();
    }

    private void clearStoppedWorker(Thread thread) {
        synchronized (this) {
            if (thread == null || worker == thread) {
                worker = null;
                running = false;
            }
        }
    }

    private void runLoop() {
        Packet pending = null;
        boolean failureReported = false;
        long lastStatusCheckMs = 0;
        try {
            while (running) {
                final long nowMs = SystemClock.elapsedRealtime();
                logPerformanceIfDue(nowMs);
                if (nowMs - lastStatusCheckMs >= 250L) {
                    lastStatusCheckMs = nowMs;
                    final int state = NativeCore.status();
                    if (state == 3) {
                        if (!failureReported) {
                            String detail = NativeCore.error();
                            postError(detail == null || detail.isEmpty() ? "Remote connection failed" : detail);
                            failureReported = true;
                        }
                    } else {
                        failureReported = false;
                    }
                }

                if (pending == null) {
                    pending = readPacket();
                }
                if (pending == null) {
                    drainOutput();
                    sleepQuietly(5L);
                    continue;
                }

                if (!isSupportedCodec(pending.codec)) {
                    postError("The remote sent an unsupported video codec");
                    requestKeyframe();
                    pending = null;
                    continue;
                }

                final int width = sanitizeDimension(NativeCore.width(), 1920);
                final int height = sanitizeDimension(NativeCore.height(), 1080);
                if (!validDimensions(width, height)) {
                    postError("The remote video dimensions exceed the decoder limit");
                    pending = null;
                    requestKeyframe();
                    continue;
                }

                observeCodec(pending.codec);
                if (pending.annexB == null) {
                    pending.annexB = toAnnexB(pending.data);
                    if (pending.annexB == null || pending.annexB.length > MAX_PACKET_BYTES + 4) {
                        postError("The remote video packet is invalid or too large");
                        pending = null;
                        requestKeyframe();
                        continue;
                    }
                }
                final byte[] annexB = pending.annexB;
                if (!pending.codecConfigScanned) {
                    if (pending.key || !hasCompleteCodecConfig(pending.codec)) {
                        updateCodecConfig(pending.codec, annexB);
                    }
                    pending.codecConfigScanned = true;
                }

                if (mediaCodec == null || !pending.codec.equals(activeCodec) || width != activeWidth ||
                    height != activeHeight) {
                    releaseCodec();
                    haveKeyframe = false;
                    if (!pending.key) {
                        requestKeyframe();
                        pending = null;
                        continue;
                    }
                    try {
                        createCodec(pending.codec, width, height);
                    } catch (Exception e) {
                        postError("Could not configure the remote video decoder");
                        releaseCodec();
                        pending = null;
                        requestKeyframe();
                        sleepQuietly(ERROR_RETRY_DELAY_MS);
                        continue;
                    }
                }

                if (!haveKeyframe && !pending.key) {
                    pending = null;
                    requestKeyframe();
                    continue;
                }

                try {
                    final int inputResult = queueInput(pending, annexB);
                    if (inputResult != 0) {
                        if (inputResult == 1 && pending.key) {
                            haveKeyframe = true;
                        } else if (inputResult == 2 && pending.key) {
                            haveKeyframe = false;
                        }
                        pending = null;
                    }
                    drainOutput();
                } catch (Exception e) {
                    postError("The remote video decoder stopped unexpectedly");
                    releaseCodec();
                    haveKeyframe = false;
                    pending = null;
                    requestKeyframe();
                    sleepQuietly(ERROR_RETRY_DELAY_MS);
                }
            }
        } catch (RuntimeException e) {
            postError("The remote video decoder stopped unexpectedly");
        } finally {
            releaseCodec();
            synchronized (this) {
                running = false;
            }
            synchronized (ACTIVE_CONSUMER_LOCK) {
                if (activePacketConsumer == this) {
                    activePacketConsumer = null;
                }
            }
        }
    }

    private Packet readPacket() {
        final byte[] raw;
        final String codecName;
        final boolean key;
        try {
            synchronized (PACKET_READ_LOCK) {
                raw = NativeCore.nextPacket();
                if (raw == null) {
                    return null;
                }
                codecName = NativeCore.codec();
                key = NativeCore.packetIsKey();
            }
        } catch (RuntimeException e) {
            postError("Could not read a remote video packet");
            return null;
        }
        if (raw == null) {
            return null;
        }
        if (raw.length == 0 || raw.length > MAX_PACKET_BYTES) {
            postError("The remote video packet is invalid or too large");
            requestKeyframe();
            return null;
        }
        final long nowUs = SystemClock.elapsedRealtimeNanos() / 1000L;
        final long pts = Math.max(nowUs, lastPresentationTimeUs + 1L);
        lastPresentationTimeUs = pts;
        return new Packet(raw, codecName == null ? "" : codecName, key, pts);
    }

    private void observeCodec(String codecName) {
        if (!codecName.equals(observedCodec)) {
            observedCodec = codecName;
            cachedH264Sps = null;
            cachedH264Pps = null;
            cachedHevcVps = null;
            cachedHevcSps = null;
            cachedHevcPps = null;
            releaseCodec();
            haveKeyframe = false;
        }
    }

    private void updateCodecConfig(String codecName, byte[] annexB) {
        int start = findStartCode(annexB, 0);
        int count = 0;
        while (start >= 0) {
            if (++count > MAX_NAL_UNITS) {
                return;
            }
            final int unitStart = start + startCodeLength(annexB, start);
            final int next = findStartCode(annexB, unitStart);
            int unitEnd = next >= 0 ? next : annexB.length;
            while (unitEnd > unitStart && annexB[unitEnd - 1] == 0) {
                unitEnd--;
            }
            final int unitLength = unitEnd - unitStart;
            if (unitLength > 0 && "h264".equals(codecName)) {
                final int type = annexB[unitStart] & 0x1f;
                if (type == 7 && unitLength <= MAX_CODEC_CONFIG_BYTES) {
                    cachedH264Sps = withStartCode(annexB, unitStart, unitLength);
                } else if (type == 8 && unitLength <= MAX_CODEC_CONFIG_BYTES) {
                    cachedH264Pps = withStartCode(annexB, unitStart, unitLength);
                }
            } else if (unitLength >= 2 && "h265".equals(codecName)) {
                final int type = (annexB[unitStart] >>> 1) & 0x3f;
                if ((type == 32 || type == 33 || type == 34) &&
                        unitLength <= MAX_CODEC_CONFIG_BYTES - 4) {
                    byte[] data = withStartCode(annexB, unitStart, unitLength);
                    if (type == 32) {
                        cachedHevcVps = data;
                    } else if (type == 33) {
                        cachedHevcSps = data;
                    } else {
                        cachedHevcPps = data;
                    }
                }
            }
            start = next;
        }
    }

    private boolean hasCompleteCodecConfig(String codecName) {
        if ("h264".equals(codecName)) {
            return cachedH264Sps != null && cachedH264Pps != null;
        }
        return cachedHevcVps != null && cachedHevcSps != null && cachedHevcPps != null;
    }

    private void createCodec(String codecName, int width, int height) throws IOException {
        final String mime = "h264".equals(codecName) ? "video/avc" : "video/hevc";
        CodecSelection selection = createDecoder(mime, codecName, width, height);
        mediaCodec = selection.codec;
        activeCodec = codecName;
        activeWidth = width;
        activeHeight = height;
        activeCodecId = "h264".equals(codecName) ? 1 : 2;
        activeHardware = selection.hardware;
        activeLowLatency = selection.lowLatency;
        notifySize(width, height);
    }

    private CodecSelection createDecoder(String mime, String codecName, int width, int height) throws IOException {
        Exception lastFailure = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            List<CodecCandidate> candidates = findDecoderCandidates(mime, width, height);
            candidates.sort((left, right) -> Integer.compare(codecRank(left), codecRank(right)));
            for (CodecCandidate candidate : candidates) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && candidate.lowLatency) {
                    try {
                        return configureCandidate(candidate, mime, codecName, width, height, true);
                    } catch (IOException | RuntimeException e) {
                        lastFailure = e;
                        try {
                            return configureCandidate(candidate, mime, codecName, width, height, false);
                        } catch (IOException | RuntimeException fallbackError) {
                            fallbackError.addSuppressed(e);
                            lastFailure = fallbackError;
                        }
                    }
                } else {
                    try {
                        return configureCandidate(candidate, mime, codecName, width, height, false);
                    } catch (IOException | RuntimeException e) {
                        lastFailure = e;
                    }
                }
            }
        }

        MediaCodec fallback = null;
        try {
            fallback = MediaCodec.createDecoderByType(mime);
            MediaFormat format = createMediaFormat(mime, codecName, width, height, false);
            fallback.configure(format, surface, null, 0);
            fallback.start();
            int hardware = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    fallback.getCodecInfo().isHardwareAccelerated() ? 1 : 0;
            return new CodecSelection(fallback, hardware, 0);
        } catch (IOException | RuntimeException e) {
            if (fallback != null) {
                fallback.release();
            }
            if (lastFailure != null) {
                e.addSuppressed(lastFailure);
            }
            throw e;
        }
    }

    private List<CodecCandidate> findDecoderCandidates(String mime, int width, int height) {
        List<CodecCandidate> candidates = new ArrayList<>();
        MediaCodecInfo[] infos = new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos();
        for (MediaCodecInfo info : infos) {
            if (info.isEncoder() || !supportsType(info, mime)) {
                continue;
            }
            try {
                MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType(mime);
                MediaCodecInfo.VideoCapabilities video = capabilities.getVideoCapabilities();
                if (video != null && !video.isSizeSupported(width, height)) {
                    continue;
                }
                final boolean lowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                        (capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) ||
                        capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency));
                candidates.add(new CodecCandidate(info, Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isHardwareAccelerated(), lowLatency));
            } catch (RuntimeException ignored) {
                // Skip codec entries whose advertised capabilities cannot be queried.
            }
        }
        return candidates;
    }

    private static int codecRank(CodecCandidate candidate) {
        if (candidate.hardware) {
            return candidate.lowLatency ? 0 : 1;
        }
        return candidate.lowLatency ? 2 : 3;
    }

    private static boolean supportsType(MediaCodecInfo info, String mime) {
        for (String type : info.getSupportedTypes()) {
            if (mime.equalsIgnoreCase(type)) {
                return true;
            }
        }
        return false;
    }

    private CodecSelection configureCandidate(CodecCandidate candidate, String mime, String codecName,
            int width, int height, boolean lowLatency) throws IOException {
        MediaCodec created = MediaCodec.createByCodecName(candidate.info.getName());
        try {
            MediaFormat format = createMediaFormat(mime, codecName, width, height, lowLatency);
            created.configure(format, surface, null, 0);
            created.start();
            return new CodecSelection(created, candidate.hardware ? 1 : 0, lowLatency ? 1 : 0);
        } catch (RuntimeException e) {
            created.release();
            throw e;
        }
    }

    private MediaFormat createMediaFormat(String mime, String codecName, int width, int height,
            boolean lowLatency) {
        MediaFormat format = MediaFormat.createVideoFormat(mime, width, height);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_PACKET_BYTES + 4);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
        if (lowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        }
        if ("h264".equals(codecName)) {
            if (cachedH264Sps != null) {
                format.setByteBuffer("csd-0", ByteBuffer.wrap(cachedH264Sps));
            }
            if (cachedH264Pps != null) {
                format.setByteBuffer("csd-1", ByteBuffer.wrap(cachedH264Pps));
            }
        } else {
            byte[] hevcConfig = combineHevcConfig();
            if (hevcConfig != null) {
                format.setByteBuffer("csd-0", ByteBuffer.wrap(hevcConfig));
            }
        }
        return format;
    }

    private byte[] combineHevcConfig() {
        if (cachedHevcVps == null || cachedHevcSps == null || cachedHevcPps == null) {
            return null;
        }
        final int size = cachedHevcVps.length + cachedHevcSps.length + cachedHevcPps.length;
        if (size > MAX_CODEC_CONFIG_BYTES) {
            return null;
        }
        ByteArrayOutputStream config = new ByteArrayOutputStream(size);
        config.write(cachedHevcVps, 0, cachedHevcVps.length);
        config.write(cachedHevcSps, 0, cachedHevcSps.length);
        config.write(cachedHevcPps, 0, cachedHevcPps.length);
        return config.toByteArray();
    }

    /** Returns 0 to retry the pending packet, 1 when queued, and 2 when dropped. */
    private int queueInput(Packet packet, byte[] annexB) {
        if (mediaCodec == null) {
            return 0;
        }
        final int index = mediaCodec.dequeueInputBuffer(10_000L);
        if (index < 0) {
            perfInputStalls++;
            return 0;
        }
        final ByteBuffer input = mediaCodec.getInputBuffer(index);
        if (input == null) {
            mediaCodec.queueInputBuffer(index, 0, 0, packet.presentationTimeUs, 0);
            return 0;
        }
        input.clear();
        if (input.remaining() < annexB.length) {
            mediaCodec.queueInputBuffer(index, 0, 0, packet.presentationTimeUs, 0);
            postError("The device decoder input buffer is too small");
            requestKeyframe();
            return 2; // Drop this unit instead of holding the network queue.
        }
        input.put(annexB);
        final int flags = packet.key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;
        mediaCodec.queueInputBuffer(index, 0, annexB.length, packet.presentationTimeUs, flags);
        return 1;
    }

    private void drainOutput() {
        final MediaCodec codec = mediaCodec;
        if (codec == null) {
            return;
        }
        final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        int newestOutput = -1;
        try {
            while (running) {
                final int index = codec.dequeueOutputBuffer(info, 0L);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    break;
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat format = codec.getOutputFormat();
                    final int width = format.containsKey(MediaFormat.KEY_WIDTH)
                        ? format.getInteger(MediaFormat.KEY_WIDTH) : activeWidth;
                    final int height = format.containsKey(MediaFormat.KEY_HEIGHT)
                        ? format.getInteger(MediaFormat.KEY_HEIGHT) : activeHeight;
                    if (validDimensions(width, height)) {
                        notifySize(width, height);
                    }
                    continue;
                }
                if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                    continue;
                }
                if (index < 0) {
                    break;
                }
                final boolean hasFrame = info.size > 0 &&
                        (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
                if (hasFrame) {
                    if (newestOutput >= 0) {
                        codec.releaseOutputBuffer(newestOutput, false);
                        perfDiscardedFrames++;
                    }
                    newestOutput = index;
                } else {
                    codec.releaseOutputBuffer(index, false);
                }
            }
        } finally {
            if (newestOutput >= 0) {
                final boolean render = running;
                codec.releaseOutputBuffer(newestOutput, render);
                if (render) {
                    perfRenderedFrames++;
                    if (firstOutputElapsedMs < 0L) {
                        firstOutputElapsedMs = SystemClock.elapsedRealtime() - perfStartMs;
                    }
                }
            }
        }
    }

    private void releaseCodec() {
        MediaCodec old = mediaCodec;
        mediaCodec = null;
        activeCodec = "";
        activeWidth = 0;
        activeHeight = 0;
        activeCodecId = 0;
        activeHardware = -1;
        activeLowLatency = 0;
        if (old != null) {
            try {
                old.stop();
            } catch (RuntimeException ignored) {
                // A codec that failed during setup may not have reached the started state.
            }
            try {
                old.release();
            } catch (RuntimeException ignored) {
                // The native decoder has no recovery action after release fails.
            }
        }
    }

    private void requestKeyframe() {
        final long now = SystemClock.elapsedRealtime();
        if (now - lastKeyframeRequestMs < KEYFRAME_REQUEST_INTERVAL_MS) {
            return;
        }
        lastKeyframeRequestMs = now;
        try {
            NativeCore.requestKeyframe();
        } catch (RuntimeException e) {
            postError("Could not request a fresh video keyframe");
        }
    }

    private void notifySize(int width, int height) {
        if (listener == null || (width == lastNotifiedWidth && height == lastNotifiedHeight)) {
            return;
        }
        lastNotifiedWidth = width;
        lastNotifiedHeight = height;
        mainHandler.post(() -> {
            if (callbacksEnabled) {
                listener.onSize(width, height);
            }
        });
    }

    private void postError(String message) {
        if (listener == null) {
            return;
        }
        final long now = SystemClock.elapsedRealtime();
        if (message.equals(lastPostedError) && now - lastPostedErrorMs < 2000L) {
            return;
        }
        lastPostedError = message;
        lastPostedErrorMs = now;
        mainHandler.post(() -> {
            if (callbacksEnabled) {
                listener.onError(message);
            }
        });
    }

    private void postStopCallbacks() {
        final List<Runnable> callbacks;
        synchronized (this) {
            if (stopCallbacks.isEmpty()) {
                return;
            }
            callbacks = new ArrayList<>(stopCallbacks);
            stopCallbacks.clear();
        }
        for (Runnable callback : callbacks) {
            mainHandler.post(callback);
        }
    }

    private static int sanitizeDimension(int value, int fallback) {
        return value > 0 ? value : fallback;
    }

    private static boolean validDimensions(int width, int height) {
        return width > 0 && height > 0 && width <= MAX_DIMENSION && height <= MAX_DIMENSION &&
            (long) width * (long) height <= MAX_PIXELS;
    }

    private static boolean isSupportedCodec(String codec) {
        return "h264".equals(codec) || "h265".equals(codec);
    }

    private static byte[] toAnnexB(byte[] data) {
        if (data == null || data.length == 0 || data.length > MAX_PACKET_BYTES) {
            return null;
        }
        if (startCodeLength(data, 0) > 0) {
            return data;
        }

        ByteArrayOutputStream converted = new ByteArrayOutputStream(data.length);
        int offset = 0;
        int units = 0;
        try {
            while (offset + 4 <= data.length) {
                long size = ((long) (data[offset] & 0xff) << 24) |
                    ((long) (data[offset + 1] & 0xff) << 16) |
                    ((long) (data[offset + 2] & 0xff) << 8) |
                    (long) (data[offset + 3] & 0xff);
                if (size == 0 || size > data.length - offset - 4L) {
                    break;
                }
                offset += 4;
                converted.write(0);
                converted.write(0);
                converted.write(0);
                converted.write(1);
                final int unitLength = (int) size;
                converted.write(data, offset, unitLength);
                offset += unitLength;
                units++;
            }
            if (units > 0 && offset == data.length) {
                return converted.toByteArray();
            }
        } catch (RuntimeException e) {
            return null;
        }

        byte[] prefixed = new byte[data.length + 4];
        prefixed[0] = 0;
        prefixed[1] = 0;
        prefixed[2] = 0;
        prefixed[3] = 1;
        System.arraycopy(data, 0, prefixed, 4, data.length);
        return prefixed;
    }

    private static byte[] withStartCode(byte[] data, int offset, int length) {
        byte[] result = new byte[length + 4];
        result[0] = 0;
        result[1] = 0;
        result[2] = 0;
        result[3] = 1;
        System.arraycopy(data, offset, result, 4, length);
        return result;
    }

    private int readReceivedFrames() {
        try {
            return NativeCore.receivedFrames();
        } catch (LinkageError | RuntimeException ignored) {
            return -1;
        }
    }

    private int readQueueDepth() {
        try {
            return NativeCore.queueDepth();
        } catch (LinkageError | RuntimeException ignored) {
            return -1;
        }
    }

    private void logPerformanceIfDue(long nowMs) {
        if (nowMs - perfWindowStartMs < PERF_LOG_INTERVAL_MS) {
            return;
        }
        final int receivedFrames = readReceivedFrames();
        final int receivedDelta = receivedFrames >= 0 && perfLastReceivedFrames >= 0
                ? Math.max(0, receivedFrames - perfLastReceivedFrames) : -1;
        final int queueDepth = readQueueDepth();
        final long firstOutputMs = firstOutputElapsedMs >= 0L ? firstOutputElapsedMs : -1L;
        Log.i("RemoteDeskPerf", "window_ms=" + (nowMs - perfWindowStartMs) +
                " rx_delta=" + receivedDelta + " queue_depth=" + queueDepth +
                " input_stalls=" + perfInputStalls + " rendered=" + perfRenderedFrames +
                " output_skipped=" + perfDiscardedFrames + " first_output_ms=" + firstOutputMs +
                " codec=" + activeCodecId + " hardware=" + activeHardware +
                " low_latency=" + activeLowLatency);
        if (receivedFrames >= 0) {
            perfLastReceivedFrames = receivedFrames;
        }
        perfWindowStartMs = nowMs;
        perfInputStalls = 0;
        perfRenderedFrames = 0;
        perfDiscardedFrames = 0;
    }

    private static int findStartCode(byte[] data, int from) {
        for (int i = Math.max(0, from); i + 3 <= data.length; ++i) {
            if (startCodeLength(data, i) > 0) {
                return i;
            }
        }
        return -1;
    }

    private static int startCodeLength(byte[] data, int offset) {
        if (offset < 0 || offset + 3 > data.length || data[offset] != 0 || data[offset + 1] != 0) {
            return 0;
        }
        if (data[offset + 2] == 1) {
            return 3;
        }
        if (offset + 4 <= data.length && data[offset + 2] == 0 && data[offset + 3] == 1) {
            return 4;
        }
        return 0;
    }

    private void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException ignored) {
            if (running) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
