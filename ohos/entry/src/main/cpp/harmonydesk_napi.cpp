#include "hilog/log.h"
#include "napi/native_api.h"
#include "video_decoder.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "HarmonyDesk"

namespace {
using HdInit = int32_t (*)();
using HdSetServer = int32_t (*)(const char *, const char *, int32_t, const char *);
using HdConnectStart = int32_t (*)(const char *, const char *);
using HdCheckPeer = int32_t (*)(const char *);
using HdStatus = int32_t (*)();
using HdDisconnect = void (*)();
using HdCopy = int32_t (*)(char *, int32_t);
using HdCopyPacket = int32_t (*)(uint8_t *, int32_t);
using HdFrameCount = int32_t (*)();
using HdIntFn = int32_t (*)();
using HdSendMouse = void (*)(int32_t, int32_t, int32_t);
using HdSendKey = void (*)(int32_t, int32_t, int32_t);
using HdSendChord = void (*)(int32_t, int32_t);
using HdSetImageQuality = void (*)(int32_t);
using HdSendText = void (*)(const char *);
using HdSendClipboardText = int32_t (*)(const char *);
using HdVoidFn = void (*)();
// Stage 3A: inbound clipboard read surface. u64 seq + UTF-8 null-terminated
// text copy (same convention as hd_copy_logs / hd_copy_error).
using HdClipboardSeq = uint64_t (*)();

std::mutex g_mu;
bool g_inited = false;
bool g_demoConnected = false;
bool g_coreLoading = false;
std::string g_logs = "C NAPI loaded\n";
std::string g_lastError;
std::string g_idServer;
std::string g_relayServer;
std::string g_key;
bool g_forceRelay = false;

void *g_core = nullptr;
HdInit g_hdInit = nullptr;
HdSetServer g_hdSetServer = nullptr;
HdConnectStart g_hdConnectStart = nullptr;
HdCheckPeer g_hdCheckPeer = nullptr;
HdStatus g_hdStatus = nullptr;
HdDisconnect g_hdDisconnect = nullptr;
HdCopy g_hdCopyLogs = nullptr;
HdCopy g_hdCopyError = nullptr;
HdCopy g_hdCopyCodec = nullptr;
HdCopy g_hdCopyCheckResult = nullptr;
HdCopyPacket g_hdCopyPacket = nullptr;
HdCopyPacket g_hdCopyKeyPacket = nullptr;
HdFrameCount g_hdFrameCount = nullptr;
HdIntFn g_hdPacketSeq = nullptr;
HdIntFn g_hdPacketKey = nullptr;
HdIntFn g_hdKeySeq = nullptr;
HdIntFn g_hdDisplayWidth = nullptr;
HdIntFn g_hdDisplayHeight = nullptr;
HdIntFn g_hdQueueLen = nullptr;
HdSendMouse g_hdSendMouse = nullptr;
HdSendKey g_hdSendKey = nullptr;
HdSendKey g_hdSendControl = nullptr;
HdSendChord g_hdSendChord = nullptr;
HdSetImageQuality g_hdSetImageQuality = nullptr;
HdSendText g_hdSendText = nullptr;
HdSendClipboardText g_hdSendClipboardText = nullptr;
HdVoidFn g_hdRequestKey = nullptr;
HdClipboardSeq g_hdClipboardSeq = nullptr;
HdIntFn g_hdClipboardAllowed = nullptr;
HdCopy g_hdCopyClipboardText = nullptr;
int32_t g_lastMouseX = 0;
int32_t g_lastMouseY = 0;

void AppendLog(const char *line)
{
    OH_LOG_INFO(LOG_APP, "%{public}s", line);
    std::lock_guard<std::mutex> lock(g_mu);
    g_logs.append(line);
    g_logs.push_back('\n');
    if (g_logs.size() > 4000) {
        g_logs.erase(0, g_logs.size() - 3000);
    }
}

bool IsDemoId(const std::string &deskId)
{
    return deskId.rfind("DEMO", 0) == 0 || deskId.rfind("TEST", 0) == 0;
}

std::string GetUtf8Arg(napi_env env, napi_callback_info info, size_t index, size_t expected)
{
    size_t argc = expected;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc || args[index] == nullptr) {
        return "";
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, args[index], nullptr, 0, &len);
    std::vector<char> buf(len + 1, 0);
    napi_get_value_string_utf8(env, args[index], buf.data(), buf.size(), &len);
    return std::string(buf.data(), len);
}

int32_t GetI32Arg(napi_env env, napi_callback_info info, size_t index, size_t expected)
{
    size_t argc = expected;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc || args[index] == nullptr) {
        return 0;
    }
    int32_t value = 0;
    if (napi_get_value_int32(env, args[index], &value) == napi_ok) {
        return value;
    }
    double number = 0;
    if (napi_get_value_double(env, args[index], &number) == napi_ok) {
        return static_cast<int32_t>(number);
    }
    return 0;
}

bool GetBoolArg(napi_env env, napi_callback_info info, size_t index, size_t expected)
{
    size_t argc = expected;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (index >= argc || args[index] == nullptr) {
        return false;
    }
    bool value = false;
    napi_get_value_bool(env, args[index], &value);
    return value;
}

void LoadCoreLocked()
{
    if (g_core != nullptr) {
        return;
    }
    void *handle = dlopen("libhdcore.so", RTLD_NOW);
    if (handle == nullptr) {
        const char *err = dlerror();
        AppendLog(err != nullptr ? err : "dlopen libhdcore.so failed");
        return;
    }
    g_hdInit = reinterpret_cast<HdInit>(dlsym(handle, "hd_init"));
    g_hdSetServer = reinterpret_cast<HdSetServer>(dlsym(handle, "hd_set_server"));
    g_hdConnectStart = reinterpret_cast<HdConnectStart>(dlsym(handle, "hd_connect_start"));
    g_hdCheckPeer = reinterpret_cast<HdCheckPeer>(dlsym(handle, "hd_check_peer"));
    g_hdStatus = reinterpret_cast<HdStatus>(dlsym(handle, "hd_status"));
    g_hdDisconnect = reinterpret_cast<HdDisconnect>(dlsym(handle, "hd_disconnect"));
    g_hdCopyLogs = reinterpret_cast<HdCopy>(dlsym(handle, "hd_copy_logs"));
    g_hdCopyError = reinterpret_cast<HdCopy>(dlsym(handle, "hd_copy_error"));
    g_hdCopyCodec = reinterpret_cast<HdCopy>(dlsym(handle, "hd_copy_codec"));
    g_hdCopyCheckResult = reinterpret_cast<HdCopy>(dlsym(handle, "hd_copy_check_result"));
    g_hdCopyPacket = reinterpret_cast<HdCopyPacket>(dlsym(handle, "hd_copy_packet"));
    g_hdCopyKeyPacket = reinterpret_cast<HdCopyPacket>(dlsym(handle, "hd_copy_key_packet"));
    g_hdFrameCount = reinterpret_cast<HdFrameCount>(dlsym(handle, "hd_frame_count"));
    g_hdPacketSeq = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_packet_seq"));
    g_hdPacketKey = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_packet_key"));
    g_hdKeySeq = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_key_seq"));
    g_hdDisplayWidth = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_display_width"));
    g_hdDisplayHeight = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_display_height"));
    g_hdQueueLen = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_queue_len"));
    g_hdSendMouse = reinterpret_cast<HdSendMouse>(dlsym(handle, "hd_send_mouse"));
    g_hdSendKey = reinterpret_cast<HdSendKey>(dlsym(handle, "hd_send_key"));
    g_hdSendControl = reinterpret_cast<HdSendKey>(dlsym(handle, "hd_send_control"));
    g_hdSendChord = reinterpret_cast<HdSendChord>(dlsym(handle, "hd_send_chord"));
    g_hdSetImageQuality = reinterpret_cast<HdSetImageQuality>(dlsym(handle, "hd_set_image_quality"));
    g_hdSendText = reinterpret_cast<HdSendText>(dlsym(handle, "hd_send_text"));
    g_hdSendClipboardText = reinterpret_cast<HdSendClipboardText>(dlsym(handle, "hd_send_clipboard_text"));
    g_hdRequestKey = reinterpret_cast<HdVoidFn>(dlsym(handle, "hd_request_keyframe"));
    g_hdClipboardAllowed = reinterpret_cast<HdIntFn>(dlsym(handle, "hd_clipboard_allowed"));
    g_hdClipboardSeq = reinterpret_cast<HdClipboardSeq>(dlsym(handle, "hd_clipboard_seq"));
    g_hdCopyClipboardText = reinterpret_cast<HdCopy>(dlsym(handle, "hd_copy_clipboard_text"));
    HdPacketApi api{};
    api.seq = g_hdPacketSeq;
    api.key = g_hdPacketKey;
    api.keySeq = g_hdKeySeq;
    api.copyCodec = g_hdCopyCodec;
    api.copyPacket = g_hdCopyPacket;
    api.copyKeyPacket = g_hdCopyKeyPacket;
    api.displayWidth = g_hdDisplayWidth;
    api.displayHeight = g_hdDisplayHeight;
    api.requestKey = g_hdRequestKey;
    HdDecoderBind(api);
    if (g_hdInit == nullptr || g_hdConnectStart == nullptr || g_hdStatus == nullptr) {
        AppendLog("libhdcore.so missing symbols");
        dlclose(handle);
        g_hdInit = nullptr;
        return;
    }
    g_core = handle;
    g_hdInit();
    AppendLog("hdcore loaded");
}

void EnsureCoreAsync()
{
    bool needStart = false;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        if (g_core == nullptr && !g_coreLoading) {
            g_coreLoading = true;
            needStart = true;
        }
    }
    if (!needStart) {
        return;
    }
    std::thread([]() {
        LoadCoreLocked();
        std::lock_guard<std::mutex> lock(g_mu);
        g_coreLoading = false;
    }).detach();
}

void ApplyServerToCore()
{
    if (g_hdSetServer == nullptr) {
        return;
    }
    std::string idServer;
    std::string relay;
    std::string key;
    bool forceRelay = false;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        idServer = g_idServer;
        relay = g_relayServer;
        key = g_key;
        forceRelay = g_forceRelay;
    }
    g_hdSetServer(idServer.c_str(), relay.c_str(), forceRelay ? 1 : 0, key.c_str());
}

std::string g_lastCoreLogs;

void PumpCoreLogsToHilog()
{
    if (g_hdCopyLogs == nullptr) {
        return;
    }
    char buf[4096] = {0};
    g_hdCopyLogs(buf, sizeof(buf));
    std::string all = buf;
    if (all.empty() || all == g_lastCoreLogs) {
        return;
    }
    std::string added = all;
    if (!g_lastCoreLogs.empty()) {
        const auto pos = all.find(g_lastCoreLogs);
        if (pos != std::string::npos) {
            added = all.substr(pos + g_lastCoreLogs.size());
        }
    }
    g_lastCoreLogs = all;
    size_t start = 0;
    while (start < added.size()) {
        size_t nl = added.find('\n', start);
        const size_t end = nl == std::string::npos ? added.size() : nl;
        if (end > start) {
            const std::string line = added.substr(start, end - start);
            OH_LOG_INFO(LOG_APP, "hdcore %{public}s", line.c_str());
        }
        if (nl == std::string::npos) {
            break;
        }
        start = nl + 1;
    }
}

std::string MergeLogs()
{
    PumpCoreLogsToHilog();
    std::string logs;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        logs = g_logs;
    }
    logs.append(g_lastCoreLogs);
    return logs;
}

napi_value MakeInt(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value Init(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_inited) {
        AppendLog("init: already initialized");
        return MakeInt(env, 1);
    }
    g_inited = true;
    AppendLog("init: ok");
    EnsureCoreAsync();
    return MakeInt(env, 0);
}

napi_value InitDebug(napi_env env, napi_callback_info info)
{
    (void)info;
    AppendLog("initDebug: ok");
    return MakeInt(env, 0);
}

napi_value SetServerConfig(napi_env env, napi_callback_info info)
{
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_idServer = GetUtf8Arg(env, info, 0, 4);
        g_relayServer = GetUtf8Arg(env, info, 1, 4);
        g_forceRelay = GetBoolArg(env, info, 2, 4);
        g_key = GetUtf8Arg(env, info, 3, 4);
    }
    AppendLog("setServerConfig: stored");
    ApplyServerToCore();
    return MakeInt(env, 0);
}

napi_value Connect(napi_env env, napi_callback_info info)
{
    const std::string deskId = GetUtf8Arg(env, info, 0, 2);
    const std::string password = GetUtf8Arg(env, info, 1, 2);
    if (IsDemoId(deskId)) {
        g_demoConnected = true;
        AppendLog("connect: demo session ready");
        return MakeInt(env, 0);
    }

    g_demoConnected = false;
    HdDecoderStart();
    EnsureCoreAsync();
    if (g_hdConnectStart == nullptr) {
        AppendLog("connect: hdcore not ready, start probe after load");
        std::thread([deskId, password]() {
            for (int i = 0; i < 40 && g_hdConnectStart == nullptr; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            if (g_hdConnectStart == nullptr) {
                AppendLog("connect: hdcore unavailable");
                std::lock_guard<std::mutex> lock(g_mu);
                g_lastError = "hdcore unavailable";
                return;
            }
            ApplyServerToCore();
            g_hdConnectStart(deskId.c_str(), password.c_str());
        }).detach();
        return MakeInt(env, 0);
    }
    ApplyServerToCore();
    g_hdConnectStart(deskId.c_str(), password.c_str());
    AppendLog("connect: probe started");
    return MakeInt(env, 0);
}

napi_value CheckPeer(napi_env env, napi_callback_info info)
{
    const std::string deskId = GetUtf8Arg(env, info, 0, 1);
    if (IsDemoId(deskId)) {
        {
            std::lock_guard<std::mutex> lock(g_mu);
            g_lastError.clear();
        }
        AppendLog("checkPeer: demo ONLINE");
        // Result polled via getCheckResult; write through core if available.
        if (g_hdCheckPeer != nullptr) {
            // Prefer real path even for demo ids when core is loaded — still treat as ONLINE locally.
        }
        return MakeInt(env, 2); // 2 = demo online (ETS maps without waiting)
    }
    EnsureCoreAsync();
    if (g_hdCheckPeer == nullptr) {
        AppendLog("checkPeer: hdcore not ready");
        return MakeInt(env, -1);
    }
    ApplyServerToCore();
    const int32_t rc = g_hdCheckPeer(deskId.c_str());
    AppendLog(("checkPeer: started id=" + deskId).c_str());
    return MakeInt(env, rc);
}

napi_value GetCheckResult(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_hdCopyCheckResult == nullptr) {
        return MakeString(env, "");
    }
    char buf[256] = {0};
    g_hdCopyCheckResult(buf, static_cast<int32_t>(sizeof(buf)));
    return MakeString(env, buf);
}

napi_value Disconnect(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    g_demoConnected = false;
    HdDecoderStop();
    if (g_hdDisconnect != nullptr) {
        g_hdDisconnect();
    }
    AppendLog("disconnect: ok");
    return nullptr;
}

napi_value Cleanup(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    g_demoConnected = false;
    g_inited = false;
    HdDecoderStop();
    if (g_hdDisconnect != nullptr) {
        g_hdDisconnect();
    }
    AppendLog("cleanup: ok");
    return nullptr;
}

napi_value GetConnectionStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_demoConnected) {
        return MakeInt(env, 1);
    }
    if (g_hdStatus != nullptr) {
        return MakeInt(env, g_hdStatus());
    }
    return MakeInt(env, 0);
}

napi_value SendKeyEvent(napi_env env, napi_callback_info info)
{
    const int32_t keyCode = GetI32Arg(env, info, 0, 2);
    const bool pressed = GetBoolArg(env, info, 1, 2);
    if (g_hdSendKey != nullptr) {
        g_hdSendKey(keyCode, pressed ? 1 : 0, 0);
    }
    return nullptr;
}

napi_value SendMouseMove(napi_env env, napi_callback_info info)
{
    const int32_t x = GetI32Arg(env, info, 0, 2);
    const int32_t y = GetI32Arg(env, info, 1, 2);
    if (g_hdSendMouse != nullptr) {
        g_hdSendMouse(0, x, y);
        g_lastMouseX = x;
        g_lastMouseY = y;
    }
    return nullptr;
}

napi_value SendMouseClick(napi_env env, napi_callback_info info)
{
    const int32_t button = GetI32Arg(env, info, 0, 2);
    const bool pressed = GetBoolArg(env, info, 1, 2);
    int32_t flag = 1;
    if (button == 1) {
        flag = 4;
    } else if (button == 2) {
        flag = 2;
    }
    const int32_t mask = (pressed ? 1 : 2) | (flag << 3);
    if (g_hdSendMouse != nullptr) {
        g_hdSendMouse(mask, g_lastMouseX, g_lastMouseY);
        OH_LOG_INFO(LOG_APP, "MOUSE_TRACE napi click btn=%{public}d down=%{public}d %{public}d %{public}d",
            static_cast<int>(button), pressed ? 1 : 0, static_cast<int>(g_lastMouseX), static_cast<int>(g_lastMouseY));
    }
    return nullptr;
}

napi_value SendMouseWheel(napi_env env, napi_callback_info info)
{
    // dy > 0 scroll up, dy < 0 scroll down (RustDesk MOUSE_TYPE_WHEEL = 3)
    const int32_t dy = GetI32Arg(env, info, 0, 1);
    if (g_hdSendMouse != nullptr && dy != 0) {
        g_hdSendMouse(3, 0, dy);
        OH_LOG_INFO(LOG_APP, "MOUSE_TRACE napi wheel dy=%{public}d", static_cast<int>(dy));
    }
    return nullptr;
}

napi_value SendText(napi_env env, napi_callback_info info)
{
    const std::string text = GetUtf8Arg(env, info, 0, 1);
    if (g_hdSendText != nullptr && !text.empty()) {
        g_hdSendText(text.c_str());
    }
    return nullptr;
}

napi_value IsClipboardAllowed(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_get_boolean(env, g_hdClipboardAllowed != nullptr && g_hdClipboardAllowed() != 0, &result);
    return result;
}

napi_value SendClipboardText(napi_env env, napi_callback_info info)
{
    // Forwards UTF-8 unchanged. No keyboard fallback. Returns:
    //   0  = packet enqueued
    //   1  = empty input (no-op)
    //  -1  = core not ready / not loaded yet
    const std::string text = GetUtf8Arg(env, info, 0, 1);
    if (g_hdSendClipboardText == nullptr) {
        AppendLog("sendClipboardText: hdcore not ready");
        return MakeInt(env, -1);
    }
    if (text.empty()) {
        return MakeInt(env, 1);
    }
    const int32_t rc = g_hdSendClipboardText(text.c_str());
    return MakeInt(env, rc);
}

// Stage 3A: read-only access to the latest remote clipboard.
// Returns the monotonic generation counter. Increases by 1 for every
// accepted plain-text clipboard update. 0 means no clipboard received
// in the current session.
//
// Returned as a JS Number via `napi_create_double` (NOT `napi_create_int32`).
// JS Number is exactly representable through 2^53-1, which is many
// orders of magnitude beyond any realistic session counter; a
// `uint64_t -> int32_t` cast or a 31-bit mask would make the visible
// generation non-monotonic for a long-running session and break the
// "snapshot-then-poll-for-change" edge-trigger the UI uses to detect a
// fresh remote clipboard.
napi_value GetRemoteClipboardSeq(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    if (g_hdClipboardSeq == nullptr) {
        napi_create_double(env, 0.0, &result);
        return result;
    }
    const uint64_t seq = g_hdClipboardSeq();
    napi_create_double(env, static_cast<double>(seq), &result);
    return result;
}

// Stage 3A: returns the latest remote clipboard text (UTF-8 round-tripped).
// Empty string when no clipboard has been received, or when the slot is
// poisoned / exceeded the 8 MiB hard cap, or when the slot keeps
// changing under us across the bounded retry window.
//
// Dynamic two-call protocol against `hd_copy_clipboard_text`:
//   1. Call once with null buffer to learn the required UTF-8 byte length.
//   2. Allocate that length + 1 (for the trailing NUL) and call again
//      to copy the exact payload.
// If the seq changes between step 1 and step 2 the slot has been
// overwritten by another accepted clipboard and the data we just copied
// is stale; retry the pair a small bounded number of times so the UI
// never sees a seq/text mismatch. After the retry budget is exhausted
// we return an empty string rather than a possibly-stale snapshot.
napi_value GetRemoteClipboardText(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_hdCopyClipboardText == nullptr) {
        return MakeString(env, "");
    }
    // 8 MiB hard cap mirrors CLIPBOARD_MAX_OUTPUT in lib.rs. Anything
    // larger than this either signals a corrupted state or a peer
    // exceeding the negotiated clipboard limit, and we MUST NOT hand
    // the caller a truncated string.
    constexpr size_t kHardCap = 8 * 1024 * 1024;
    constexpr int kMaxRetries = 3;

    uint64_t observedSeq = 0;
    if (g_hdClipboardSeq != nullptr) {
        observedSeq = g_hdClipboardSeq();
    }

    for (int attempt = 0; attempt < kMaxRetries; ++attempt) {
        // Step 1: size query.
        const int32_t required = g_hdCopyClipboardText(nullptr, 0);
        if (required <= 0) {
            return MakeString(env, "");
        }
        if (static_cast<size_t>(required) > kHardCap) {
            AppendLog("getRemoteClipboardText: required > 8 MiB; rejecting");
            return MakeString(env, "");
        }
        // Step 2: exact copy.
        std::vector<char> buf(static_cast<size_t>(required) + 1, 0);
        const int32_t n = g_hdCopyClipboardText(
            buf.data(), static_cast<int32_t>(buf.size()));
        if (n <= 0) {
            return MakeString(env, "");
        }
        if (static_cast<size_t>(n) > kHardCap) {
            AppendLog("getRemoteClipboardText: copy > 8 MiB; rejecting");
            return MakeString(env, "");
        }
        // The slot can grow between step 1 and step 2. If the actual
        // copy length does not match the size we sized for, the slot was
        // raced: `n > required` would make `std::string(buf.data(), n)`
        // read past the allocated `required + 1` buffer, and `n <
        // required` would silently hand JS back a truncated payload.
        // Either is a raced slot — retry within the bounded budget and
        // refresh `observedSeq` so the next attempt compares against the
        // current generation instead of the stale one.
        if (n != required) {
            AppendLog("getRemoteClipboardText: size mismatch; retrying");
            if (g_hdClipboardSeq != nullptr) {
                observedSeq = g_hdClipboardSeq();
            }
            continue;
        }
        // Verify the slot is still the snapshot we sized for; if it
        // changed, retry.
        if (g_hdClipboardSeq == nullptr || g_hdClipboardSeq() == observedSeq) {
            return MakeString(env, std::string(buf.data(), static_cast<size_t>(n)));
        }
        observedSeq = g_hdClipboardSeq();
    }
    AppendLog("getRemoteClipboardText: slot kept changing; returning empty");
    return MakeString(env, "");
}

napi_value SendControlKey(napi_env env, napi_callback_info info)
{
    const int32_t code = GetI32Arg(env, info, 0, 2);
    const bool pressed = GetBoolArg(env, info, 1, 2);
    if (g_hdSendControl != nullptr) {
        g_hdSendControl(code, 0, 1);
        (void)pressed;
    }
    return nullptr;
}

napi_value SendChord(napi_env env, napi_callback_info info)
{
    // Ctrl/Alt/Shift + letter. chr = ASCII (e.g. 'c'=99), modifier = ControlKey (Control=4)
    const int32_t chr = GetI32Arg(env, info, 0, 2);
    const int32_t modifier = GetI32Arg(env, info, 1, 2);
    if (g_hdSendChord != nullptr && chr > 0 && modifier > 0) {
        g_hdSendChord(chr, modifier);
    }
    return nullptr;
}

napi_value SetImageQuality(napi_env env, napi_callback_info info)
{
    // 2=Low, 3=Balanced, 4=Best
    const int32_t quality = GetI32Arg(env, info, 0, 1);
    if (g_hdSetImageQuality != nullptr) {
        g_hdSetImageQuality(quality);
    }
    return nullptr;
}

napi_value GetVideoFrame(napi_env env, napi_callback_info info)
{
    (void)info;
    int32_t decodedW = 0;
    int32_t decodedH = 0;
    if (HdDecoderPeek(&decodedW, &decodedH) && decodedW > 0 && decodedH > 0) {
        if (!HdDecoderHasNewFrame()) {
            napi_value nullValue = nullptr;
            napi_get_null(env, &nullValue);
            return nullValue;
        }
        const size_t size = static_cast<size_t>(decodedW * decodedH * 4);
        void *data = nullptr;
        napi_value buffer = nullptr;
        napi_create_arraybuffer(env, size, &data, &buffer);
        if (data != nullptr && HdDecoderCopyRgba(static_cast<uint8_t *>(data), size, &decodedW, &decodedH)) {
            napi_value obj = nullptr;
            napi_create_object(env, &obj);
            napi_set_named_property(env, obj, "width", MakeInt(env, decodedW));
            napi_set_named_property(env, obj, "height", MakeInt(env, decodedH));
            napi_set_named_property(env, obj, "data", buffer);
            napi_set_named_property(env, obj, "timestamp", MakeInt(env, 0));
            return obj;
        }
        napi_value nullValue = nullptr;
        napi_get_null(env, &nullValue);
        return nullValue;
    }

    if (!g_demoConnected) {
        napi_value nullValue = nullptr;
        napi_get_null(env, &nullValue);
        return nullValue;
    }

    const int32_t frameCount = g_hdFrameCount != nullptr ? g_hdFrameCount() : 0;
    const int32_t width = 320;
    const int32_t height = 180;
    const size_t size = static_cast<size_t>(width * height * 4);
    void *data = nullptr;
    napi_value buffer = nullptr;
    napi_create_arraybuffer(env, size, &data, &buffer);
    if (data != nullptr) {
        auto *pixels = static_cast<uint8_t *>(data);
        const uint8_t pulse = static_cast<uint8_t>((frameCount * 12) & 0xff);
        for (int32_t y = 0; y < height; ++y) {
            for (int32_t x = 0; x < width; ++x) {
                const size_t idx = static_cast<size_t>((y * width + x) * 4);
                if (g_demoConnected) {
                    const bool dark = ((x / 32) + (y / 32)) % 2 == 0;
                    pixels[idx] = static_cast<uint8_t>(x * 255 / width);
                    pixels[idx + 1] = static_cast<uint8_t>(y * 255 / height);
                    pixels[idx + 2] = dark ? 80 : 180;
                } else {
                    pixels[idx] = pulse;
                    pixels[idx + 1] = static_cast<uint8_t>(40 + (y * 80 / height));
                    pixels[idx + 2] = static_cast<uint8_t>(80 + (x * 80 / width));
                }
                pixels[idx + 3] = 255;
            }
        }
    }

    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "width", MakeInt(env, width));
    napi_set_named_property(env, obj, "height", MakeInt(env, height));
    napi_set_named_property(env, obj, "data", buffer);
    napi_set_named_property(env, obj, "timestamp", MakeInt(env, 0));
    return obj;
}

napi_value GetVideoStats(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    const int32_t status = g_hdStatus != nullptr ? g_hdStatus() : 0;
    const int32_t packets = g_hdPacketSeq != nullptr ? g_hdPacketSeq() : 0;
    const int32_t frames = g_hdFrameCount != nullptr ? g_hdFrameCount() : 0;
    const int32_t width = g_hdDisplayWidth != nullptr ? g_hdDisplayWidth() : 0;
    const int32_t height = g_hdDisplayHeight != nullptr ? g_hdDisplayHeight() : 0;
    napi_set_named_property(env, obj, "status", MakeInt(env, status));
    napi_set_named_property(env, obj, "packets", MakeInt(env, packets));
    napi_set_named_property(env, obj, "frames", MakeInt(env, frames));
    napi_set_named_property(env, obj, "width", MakeInt(env, width));
    napi_set_named_property(env, obj, "height", MakeInt(env, height));
    napi_set_named_property(env, obj, "decoded", MakeInt(env, HdDecoderDecodedCount()));
    napi_set_named_property(env, obj, "pushed", MakeInt(env, HdDecoderPushedCount()));
    napi_set_named_property(env, obj, "surface", MakeInt(env, HdDecoderSurfaceActive()));
    napi_set_named_property(env, obj, "convertMs", MakeInt(env, HdDecoderLastConvertMs()));
    int32_t queueLen = 0;
    if (g_hdQueueLen != nullptr) {
        queueLen = g_hdQueueLen();
    }
    napi_set_named_property(env, obj, "queue", MakeInt(env, queueLen));
    return obj;
}

napi_value GetLogs(napi_env env, napi_callback_info info)
{
    (void)info;
    PumpCoreLogsToHilog();
    return MakeString(env, MergeLogs());
}

napi_value GetLastError(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string err;
    {
        std::lock_guard<std::mutex> lock(g_mu);
        err = g_lastError;
    }
    if (g_hdCopyError != nullptr) {
        char buf[512] = {0};
        g_hdCopyError(buf, sizeof(buf));
        if (buf[0] != '\0') {
            err = buf;
        }
    }
    if (err.empty()) {
        napi_value nullValue = nullptr;
        napi_get_null(env, &nullValue);
        return nullValue;
    }
    return MakeString(env, err);
}

napi_value ClearLogs(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    std::lock_guard<std::mutex> lock(g_mu);
    g_logs.clear();
    g_lastError.clear();
    return nullptr;
}

napi_value BindVideoSurface(napi_env env, napi_callback_info info)
{
    const std::string id = GetUtf8Arg(env, info, 0, 1);
    if (id.empty()) {
        return MakeInt(env, -1);
    }
    uint64_t surfaceId = 0;
    try {
        surfaceId = std::stoull(id);
    } catch (...) {
        AppendLog("bindVideoSurface: bad surface id");
        return MakeInt(env, -2);
    }
    if (surfaceId == 0) {
        return MakeInt(env, -3);
    }
    HdDecoderSetSurface(surfaceId);
    AppendLog("bindVideoSurface: ok");
    return MakeInt(env, 0);
}

napi_value UnbindVideoSurface(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    HdDecoderClearSurface();
    AppendLog("unbindVideoSurface: ok");
    return nullptr;
}

napi_value Register(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initDebug", nullptr, InitDebug, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setServerConfig", nullptr, SetServerConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"checkPeer", nullptr, CheckPeer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCheckResult", nullptr, GetCheckResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cleanup", nullptr, Cleanup, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnectionStatus", nullptr, GetConnectionStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKeyEvent", nullptr, SendKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseMove", nullptr, SendMouseMove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseClick", nullptr, SendMouseClick, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseWheel", nullptr, SendMouseWheel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendText", nullptr, SendText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isClipboardAllowed", nullptr, IsClipboardAllowed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendClipboardText", nullptr, SendClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRemoteClipboardSeq", nullptr, GetRemoteClipboardSeq, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRemoteClipboardText", nullptr, GetRemoteClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendControlKey", nullptr, SendControlKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendChord", nullptr, SendChord, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setImageQuality", nullptr, SetImageQuality, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVideoFrame", nullptr, GetVideoFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVideoStats", nullptr, GetVideoStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"bindVideoSurface", nullptr, BindVideoSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unbindVideoSurface", nullptr, UnbindVideoSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLogs", nullptr, GetLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLastError", nullptr, GetLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearLogs", nullptr, ClearLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    AppendLog("module registered");
    return exports;
}
} // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Register,
    .nm_modname = "harmonydesk",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHarmonyDeskModule(void)
{
    napi_module_register(&g_module);
}
