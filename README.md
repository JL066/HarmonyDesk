# HarmonyDesk

面向 HarmonyOS NEXT 手机、平板与二合一设备的远程桌面**控制端**客户端。当前版本为
**1.0.0**（`versionCode 1000000`；协议核心 crate `hdcore` **0.1.0**），在
ArkUI 工作台中基于 RustDesk 兼容协议连接已运行 RustDesk 的电脑：支持自建
hbbs/hbbr 与局域网 IP 直连，画面走系统硬解，输入覆盖触摸板与常用快捷键。

> 本仓库**只提供控制端**，不包含被控端服务。GitHub / 本机产物中的调试 HAP
> 依赖本地签名材料，未经你的证书签名前不能当作正式分发包。请仅在有权管理的
> 设备上使用。

## 功能概览

| 能力 | 当前实现 |
|---|---|
| 自建服务器 | 配置 hbbs（ID）、hbbr（中继）与 Key；打洞优先，失败走中继；可强制中继 |
| 设备列表 | 本机 preferences 保存常用设备 ID、名称与密码；首装含演示占位项 |
| ID 连接 | 经 ID 服务器查询并建立会话；支持在线探测 |
| IP 直连 | 直接填写被控端 IP（默认端口 `21118`） |
| 视频解码 | H.264 / H.265 系统硬解，XComponent / NativeWindow 出图 |
| 触控输入 | 触摸板模式、左右键、可拖拽滚轮；支持只读（viewOnly） |
| 屏幕键盘 | 文本/密码、中英切换，Ctrl+Alt+Del、Alt+F4、显示桌面等快捷组合 |
| 会话稳定 | 短线自动重连（有限次数）、前后台短时保活后断开 |
| 平板 / 二合一适配 | 会话布局自适应平板与二合一形态；视窗尺寸变化时，视频面、远端分辨率、几何 / 缩放与指针 / 触摸映射保持同步 |
| 画质档位 | UI/API 保留切换入口；核心当前为统一 profile，非完整多档平滑切换 |
| 音频 | 未实现（核心关闭音频） |
| 剪贴板 | 未实现（核心关闭；设置页开关仅为本地偏好占位） |
| 文件传输 | 未实现（仅有设置/详情开关，无传输链路） |

部分能力依赖对端 RustDesk 版本、自建中继可达性、HarmonyOS 设备权限与本机
签名配置。仓库不会把未完成的音视频外能力描述为已经可用。

## 支持平台与技术栈

- HarmonyOS NEXT 手机、平板与二合一设备（开发机建议 API 26 / 鸿蒙 7 基线；亦兼容 API 15+ 工具链）。
- 已验证机型：MatePad Pro 2026 / HarmonyOS 6.1.0；该机型为已实测配置，不视为对全部 HarmonyOS 平板的通用兼容声明。
- ArkTS + ArkUI 声明式 UI。
- C++ NAPI 扩展：加载协议库、OH AVCodec 硬解与 Surface 出图。
- Rust `cdylib`（`libhdcore.so`）承载登录、打洞/中继、视频包与键鼠协议。
- 构建：DevEco Studio Hvigor + Cargo（目标 `aarch64-unknown-linux-ohos`）。
- 当前主产物面向 **ARM64** 真机侧载。

## 架构

```text
ArkTS pages（设备列表 / 设置 / 会话触控与键盘）
        │
        └── NAPI boundary（libharmonydesk.so）
              ├── OH AVCodec 硬解 H.264/H.265 → Surface
              └── dlopen libhdcore.so（Rust）
                    ├── 登录 / 打洞 / 中继
                    ├── 视频包队列
                    └── 键鼠 / 文本 / 快捷键
                              │
                    hbbs:21116 / hbbr:21117
                    或 IP:21118 直连
                              │
                        RustDesk 被控端
```

会话、解码与输入保持边界。可选设置项（剪贴板/文件传输等）失败或未实现时，
不应被叙述为已建立完整桌面能力；协议核心以 `ohos/entry/ohos/hdcore/` 为准，
遗留 `ohos/entry/ohos/rust/` 不进入主构建。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `ohos/` | 主工程（请用 DevEco Studio 打开此目录） |
| `ohos/AppScope/` | 应用级清单、版本与图标 |
| `ohos/entry/src/main/ets/` | ArkTS 页面、Ability、本地存储与桥接 |
| `ohos/entry/src/main/cpp/` | NAPI 与视频硬解 |
| `ohos/entry/ohos/hdcore/` | 现行 Rust 协议核心（产出 `libhdcore.so`） |
| `ohos/entry/ohos/rust/` | 早期遗留栈，勿当作主路径 |
| `ohos/build-profile.json5.example` | 构建/签名配置模板 |
| `scripts/` | `build-native.ps1`、`build-hap.bat`、安装辅助 |
| `docs/` | 补充说明（部分历史文档可能过时，以本 README 为准） |

## 获取源码

```powershell
git clone https://github.com/zyfdandan/HarmonyDesk.git
Set-Location HarmonyDesk
```

## 本地私有配置

仓库不跟踪签名证书、口令、本机 SDK 路径、真实服务器 Key 与远程密码。首次
构建请：

- `ohos/build-profile.json5.example` → 本地 `ohos/build-profile.json5`
  （或在 DevEco **Signing Configs** 勾选自动签名）
- 按需配置 `local.properties`（若使用）

真实值只保存在本机安全路径。不要把 `*.p12`、`*.p7b`、`*.cer`、含密钥的
`build-profile*.json5`、`*.so`、HAP 调试包或设备 preferences 导出加入 Git。

## 构建依赖

1. 安装 DevEco Studio 5.0+ 与对应 HarmonyOS SDK。
2. 安装 Rust stable，并添加目标 `aarch64-unknown-linux-ohos`。
3. 准备 OHOS Native SDK（含 `llvm/bin/clang`），设置 `OHOS_NATIVE_HOME`。
4. 准备上述本地私有配置（签名）。

## 编译原生核心

在仓库根目录（Windows PowerShell）：

```powershell
$env:OHOS_NATIVE_HOME = 'C:\path\to\ohos-sdk\native'
powershell -ExecutionPolicy Bypass -File .\scripts\build-native.ps1
```

预期产出：

```text
ohos/entry/libs/arm64-v8a/libhdcore.so
```

## 构建 HAP 并安装

```powershell
.\scripts\build-hap.bat
hdc install ohos\entry\build\default\outputs\default\entry-default-signed.hap
```

也可在 DevEco 中打开 `ohos/` 后直接 Run。手机需开启开发者模式与 USB 调试。

## 使用流程

1. 打开应用 → 设置中填写自建 hbbs / hbbr / Key（或仅使用 IP 直连）。
2. 在设备页添加对端 ID + 密码，或填写局域网 IP。
3. 进入会话：查看画面，使用触摸板与屏幕键盘操作。

被控端需已安装并登录兼容的 RustDesk；本仓库不提供公网默认路由。

## 测试与验证

- 真机侧载后验证：ID 连接、IP 直连、断线重连、只读模式、常用快捷键。
- 解码确认：对端开启 H.264/H.265 时画面可出图；勿将 VP8/VP9/AV1 写成已支持。
- 根目录部分历史 Markdown（如仍写 `harmonyos/` 或软解测试模式）可能过时，
  以本文件与 `ohos/` + `hdcore` 实现为准。

## 许可与上游说明

仓库尚未放置统一的 `LICENSE` 文件；使用范围以项目授权为准。协议实现参考
RustDesk 生态，部署与分发时请自行核对上游许可证与合规要求。请勿在公开
issue 中提交真实服务器地址、Key、远程密码或设备日志中的敏感字段。
