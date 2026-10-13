#include <jni.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

extern "C" {
int32_t hd_init();
int32_t hd_set_server(const char *id_server, const char *relay, int32_t force_relay, const char *key);
int32_t hd_connect_start(const char *peer, const char *password);
int32_t hd_status();
void hd_disconnect();
int32_t hd_copy_error(char *buf, int32_t len);
int32_t hd_display_width();
int32_t hd_display_height();
int32_t hd_queue_len();
int32_t hd_frame_count();
int32_t hd_set_route_policy(int32_t policy);
int32_t hd_route_kind();
int32_t hd_copy_packet_ex(uint8_t *buf, int32_t len, int32_t *codec, int32_t *key);
void hd_request_keyframe();
void hd_send_mouse(int32_t mask, int32_t x, int32_t y);
void hd_send_hardware_key(int32_t kind, int32_t code, int32_t down, const int32_t *modifiers,
    int32_t modifiers_len);
void hd_send_text(const char *text);
void hd_send_control(int32_t code, int32_t down, int32_t press);
uint64_t hd_clipboard_seq();
int32_t hd_copy_clipboard_text(char *buf, int32_t len);
int32_t hd_clipboard_allowed();
int32_t hd_send_clipboard_text(const char *text);
}

namespace {
constexpr size_t kMaxPacketBytes = 8U * 1024U * 1024U;
constexpr size_t kMaxClipboardBytes = 8U * 1024U * 1024U;
constexpr size_t kMaxKeyboardTextBytes = 64U * 1024U;
constexpr size_t kMaxConfigBytes = 8U * 1024U;
constexpr size_t kMaxPeerBytes = 4U * 1024U;
constexpr size_t kMaxPasswordBytes = 8U * 1024U;
constexpr int kClipboardReadAttempts = 3;

std::mutex g_packetCopyMutex;
thread_local std::string g_threadPacketCodec;
thread_local bool g_threadPacketIsKey = false;

struct WipeStringOnExit {
    std::string &value;
    ~WipeStringOnExit()
    {
        volatile char *bytes = value.empty() ? nullptr : value.data();
        for (size_t i = 0; i < value.size(); ++i) {
            bytes[i] = 0;
        }
        value.clear();
    }
};

void AppendUtf8(uint32_t codepoint, std::string &out)
{
    if (codepoint <= 0x7f) {
        out.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ff) {
        out.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else if (codepoint <= 0xffff) {
        out.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else {
        out.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    }
}

bool ReadJavaString(JNIEnv *env, jstring value, size_t maxBytes, std::string &out)
{
    out.clear();
    if (value == nullptr) {
        return true;
    }
    const jsize length = env->GetStringLength(value);
    const jchar *chars = env->GetStringChars(value, nullptr);
    if (chars == nullptr) {
        return false;
    }
    bool valid = true;
    try {
        out.reserve(std::min(maxBytes, static_cast<size_t>(length) * 3U));
        for (jsize i = 0; i < length; ++i) {
            uint32_t codepoint = chars[i];
            if (codepoint == 0) {
                valid = false; // The Rust ABI accepts NUL-terminated strings.
                break;
            }
            if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
                if (i + 1 < length && chars[i + 1] >= 0xdc00 && chars[i + 1] <= 0xdfff) {
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (chars[++i] - 0xdc00);
                } else {
                    codepoint = 0xfffd;
                }
            } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
                codepoint = 0xfffd;
            }
            const size_t before = out.size();
            AppendUtf8(codepoint, out);
            if (out.size() > maxBytes || out.size() < before) {
                valid = false;
                break;
            }
        }
    } catch (...) {
        valid = false;
    }
    env->ReleaseStringChars(value, chars);
    if (!valid) {
        out.clear();
    }
    return valid;
}

void AppendUtf16(uint32_t codepoint, std::vector<jchar> &out)
{
    if (codepoint <= 0xffff) {
        out.push_back(static_cast<jchar>(codepoint));
    } else {
        codepoint -= 0x10000;
        out.push_back(static_cast<jchar>(0xd800 + (codepoint >> 10)));
        out.push_back(static_cast<jchar>(0xdc00 + (codepoint & 0x3ff)));
    }
}

uint32_t DecodeUtf8(const unsigned char *bytes, size_t length, size_t &index)
{
    const unsigned char first = bytes[index++];
    if (first <= 0x7f) {
        return first;
    }

    uint32_t codepoint = 0;
    size_t continuationCount = 0;
    uint32_t minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) {
        codepoint = first & 0x1f;
        continuationCount = 1;
        minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
        codepoint = first & 0x0f;
        continuationCount = 2;
        minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
        codepoint = first & 0x07;
        continuationCount = 3;
        minimum = 0x10000;
    } else {
        return 0xfffd;
    }

    if (index + continuationCount > length) {
        index = length;
        return 0xfffd;
    }
    for (size_t i = 0; i < continuationCount; ++i) {
        const unsigned char next = bytes[index];
        if ((next & 0xc0) != 0x80) {
            return 0xfffd;
        }
        ++index;
        codepoint = (codepoint << 6) | (next & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
        return 0xfffd;
    }
    return codepoint;
}

jstring NewJavaString(JNIEnv *env, const char *bytes, size_t length)
{
    if (bytes == nullptr) {
        static const jchar empty = 0;
        return env->NewString(&empty, 0);
    }
    std::vector<jchar> utf16;
    try {
        utf16.reserve(length);
        size_t index = 0;
        const auto *input = reinterpret_cast<const unsigned char *>(bytes);
        while (index < length) {
            AppendUtf16(DecodeUtf8(input, length, index), utf16);
        }
    } catch (...) {
        return nullptr;
    }
    if (utf16.size() > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
        return nullptr;
    }
    static const jchar empty = 0;
    return env->NewString(utf16.empty() ? &empty : utf16.data(), static_cast<jsize>(utf16.size()));
}

jstring CopyError(JNIEnv *env)
{
    std::array<char, 4096> buffer{};
    const int32_t length = hd_copy_error(buffer.data(), static_cast<int32_t>(buffer.size()));
    if (length <= 0) {
        return NewJavaString(env, "", 0);
    }
    const size_t copied = std::min(static_cast<size_t>(length), buffer.size() - 1);
    return NewJavaString(env, buffer.data(), copied);
}
} // namespace

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_init(JNIEnv *, jclass)
{
    return hd_init();
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_configure(JNIEnv *env, jclass,
    jstring idServer, jstring relay, jboolean forceRelay, jstring key)
{
    try {
        std::string id;
        std::string relayValue;
        std::string keyValue;
        if (!ReadJavaString(env, idServer, kMaxConfigBytes, id) ||
            !ReadJavaString(env, relay, kMaxConfigBytes, relayValue) ||
            !ReadJavaString(env, key, kMaxConfigBytes, keyValue)) {
            return -1;
        }
        WipeStringOnExit wipeKey{keyValue};
        return hd_set_server(id.c_str(), relayValue.c_str(), forceRelay == JNI_TRUE ? 1 : 0, keyValue.c_str());
    } catch (...) {
        return -1;
    }
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_connect(JNIEnv *env, jclass,
    jstring peer, jstring password)
{
    try {
        std::string peerValue;
        std::string passwordValue;
        if (!ReadJavaString(env, peer, kMaxPeerBytes, peerValue) ||
            !ReadJavaString(env, password, kMaxPasswordBytes, passwordValue)) {
            return -1;
        }
        WipeStringOnExit wipePassword{passwordValue};
        return hd_connect_start(peerValue.c_str(), passwordValue.c_str());
    } catch (...) {
        return -1;
    }
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_status(JNIEnv *, jclass)
{
    return hd_status();
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_disconnect(JNIEnv *, jclass)
{
    hd_disconnect();
}

extern "C" JNIEXPORT jstring JNICALL Java_io_github_jl066_harmonydesk_NativeCore_error(JNIEnv *env, jclass)
{
    return CopyError(env);
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_width(JNIEnv *, jclass)
{
    return hd_display_width();
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_height(JNIEnv *, jclass)
{
    return hd_display_height();
}

extern "C" JNIEXPORT jstring JNICALL Java_io_github_jl066_harmonydesk_NativeCore_codec(JNIEnv *env, jclass)
{
    return NewJavaString(env, g_threadPacketCodec.data(), g_threadPacketCodec.size());
}

extern "C" JNIEXPORT jbyteArray JNICALL Java_io_github_jl066_harmonydesk_NativeCore_nextPacket(JNIEnv *env, jclass)
{
    try {
        static thread_local std::vector<uint8_t> packet(kMaxPacketBytes);
        std::lock_guard<std::mutex> lock(g_packetCopyMutex);
        int32_t codec = 0;
        int32_t key = 0;
        const int32_t count = hd_copy_packet_ex(packet.data(), static_cast<int32_t>(packet.size()), &codec, &key);
        if (count < 0) {
            // The fixed Java packet limit cannot hold this access unit (or the
            // core reported an invalid packet). Drop queued deltas and request
            // a fresh keyframe rather than repeatedly retrying stale data.
            hd_request_keyframe();
            g_threadPacketCodec.clear();
            g_threadPacketIsKey = false;
            return nullptr;
        }
        if (count == 0 || static_cast<size_t>(count) > packet.size()) {
            g_threadPacketCodec.clear();
            g_threadPacketIsKey = false;
            return nullptr;
        }
        if (codec == 1) {
            g_threadPacketCodec = "h264";
        } else if (codec == 2) {
            g_threadPacketCodec = "h265";
        } else {
            g_threadPacketCodec.clear();
        }
        g_threadPacketIsKey = key != 0;

        jbyteArray result = env->NewByteArray(static_cast<jsize>(count));
        if (result == nullptr) {
            return nullptr;
        }
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(count), reinterpret_cast<const jbyte *>(packet.data()));
        return result;
    } catch (...) {
        g_threadPacketCodec.clear();
        g_threadPacketIsKey = false;
        return nullptr;
    }
}

extern "C" JNIEXPORT jboolean JNICALL Java_io_github_jl066_harmonydesk_NativeCore_packetIsKey(JNIEnv *, jclass)
{
    return g_threadPacketIsKey ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_requestKeyframe(JNIEnv *, jclass)
{
    hd_request_keyframe();
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_mouse(JNIEnv *, jclass, jint mask,
    jint x, jint y)
{
    hd_send_mouse(mask, x, y);
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_key(JNIEnv *env, jclass, jint kind,
    jint code, jboolean down, jintArray modifiers)
{
    std::array<jint, 8> values{};
    jsize count = 0;
    if (modifiers != nullptr) {
        count = std::min<jsize>(env->GetArrayLength(modifiers), static_cast<jsize>(values.size()));
        if (count > 0) {
            env->GetIntArrayRegion(modifiers, 0, count, values.data());
            if (env->ExceptionCheck()) {
                return;
            }
        }
    }
    hd_send_hardware_key(kind, code, down == JNI_TRUE ? 1 : 0,
        count > 0 ? reinterpret_cast<const int32_t *>(values.data()) : nullptr, count);
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_text(JNIEnv *env, jclass,
    jstring text)
{
    try {
        std::string value;
        if (!ReadJavaString(env, text, kMaxKeyboardTextBytes, value) || value.empty()) {
            return;
        }
        WipeStringOnExit wipeText{value};
        hd_send_text(value.c_str());
    } catch (...) {
        return;
    }
}

extern "C" JNIEXPORT void JNICALL Java_io_github_jl066_harmonydesk_NativeCore_control(JNIEnv *, jclass, jint code)
{
    hd_send_control(code, 0, 1);
}

extern "C" JNIEXPORT jlong JNICALL Java_io_github_jl066_harmonydesk_NativeCore_clipboardSequence(JNIEnv *, jclass)
{
    return static_cast<jlong>(hd_clipboard_seq());
}

extern "C" JNIEXPORT jstring JNICALL Java_io_github_jl066_harmonydesk_NativeCore_clipboardText(JNIEnv *env, jclass)
{
    try {
        for (int attempt = 0; attempt < kClipboardReadAttempts; ++attempt) {
            const uint64_t sequence = hd_clipboard_seq();
            const int32_t required = hd_copy_clipboard_text(nullptr, 0);
            if (required <= 0 || static_cast<size_t>(required) > kMaxClipboardBytes) {
                return NewJavaString(env, "", 0);
            }
            std::vector<char> buffer(static_cast<size_t>(required) + 1U, 0);
            const int32_t copied = hd_copy_clipboard_text(buffer.data(), static_cast<int32_t>(buffer.size()));
            if (copied != required || hd_clipboard_seq() != sequence) {
                continue;
            }
            return NewJavaString(env, buffer.data(), static_cast<size_t>(copied));
        }
    } catch (...) {
        return NewJavaString(env, "", 0);
    }
    return NewJavaString(env, "", 0);
}

extern "C" JNIEXPORT jboolean JNICALL Java_io_github_jl066_harmonydesk_NativeCore_clipboardAllowed(JNIEnv *,
    jclass)
{
    return hd_clipboard_allowed() != 0 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_sendClipboard(JNIEnv *env, jclass,
    jstring text)
{
    try {
        std::string value;
        if (!ReadJavaString(env, text, kMaxClipboardBytes, value)) {
            return -1;
        }
        if (value.empty()) {
            return 1;
        }
        WipeStringOnExit wipeText{value};
        return hd_send_clipboard_text(value.c_str());
    } catch (...) {
        return -1;
    }
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_queueDepth(JNIEnv *, jclass)
{
    return hd_queue_len();
}
extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_receivedFrames(JNIEnv *, jclass)
{
    return hd_frame_count();
}

extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_setRoutePolicy(JNIEnv *, jclass, jint policy)
{
    return hd_set_route_policy(policy);
}
extern "C" JNIEXPORT jint JNICALL Java_io_github_jl066_harmonydesk_NativeCore_routeKind(JNIEnv *, jclass)
{
    return hd_route_kind();
}
