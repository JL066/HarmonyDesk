# DevEco Studio 项目打开问题排查

## 仓库与工具路径

文中的 `HARMONYDESK_ROOT` 指向你自己的仓库根目录，项目目录为其下的 `ohos`。本机路径只在终端环境变量或被忽略的本地配置中设置，不写入仓库。

- Windows HAP 构建使用 `DEVECO_STUDIO_HOME`；未设置时按系统的 `ProgramFiles` 位置查找 DevEco Studio。已有的 `JAVA_HOME`、`NODE_HOME`、`DEVECO_SDK_HOME` 和 `OHOS_BASE_SDK_HOME` 会被保留。
- Native 构建可设置 `OHOS_NATIVE_HOME`，或通过 `OHOS_SDK_HOME` / `DEVECO_SDK_HOME` 查找 native 工具链。需要 MinGW 时设置 `MINGW_HOME` 或将其加入当前终端的 `PATH`。
- 设备辅助脚本通过 `HDC_PATH` 或 `PATH` 查找 `hdc`。鼠标追踪脚本还需要 `HDC_DEVICE_ID` 或 `-DeviceId` 参数；设备标识和追踪日志不要提交。
- 安装辅助脚本不再查询或打印设备 UDID。上述脚本不会修改全局环境变量。

## 问题: "Select an OpenHarmony or HarmonyOS project" 错误

这个错误表示 DevEco Studio 无法识别项目结构。以下是解决步骤:

### 解决方案 1: 重新导入项目

1. **关闭当前项目**
   - File → Close Project

2. **删除 DevEco Studio 缓存**
   ```bash
   # 删除 .idea 目录（如果存在）
   cd "${HARMONYDESK_ROOT:?Set HARMONYDESK_ROOT to your checkout}/ohos"
   rm -rf .idea
   rm -f .idea/
   ```

3. **重新打开项目**
   - DevEco Studio → File → Open
   - 选择 `harmonyos` 目录
   - 点击 **Open**

### 解决方案 2: 检查 DevEco Studio 版本

确保使用的是 **DevEco Studio 4.0+** (推荐 4.1 或更高)

检查版本:
- Help → About
- 查看版本号

如果版本过低:
1. 访问 https://developer.harmonyos.com/cn/develop/deveco-studio
2. 下载最新版本
3. 安装并重试

### 解决方案 3: 同步项目配置

如果项目已打开但显示错误:

1. **同步 Gradle/Hvigor**
   - 点击工具栏的 **Sync Project** 按钮（大象图标）
   - 或使用菜单: File → Sync Project

2. **清理并重建**
   - Build → Clean Project
   - Build → Rebuild Project

3. **重启 DevEco Studio**
   - File → Invalidate Caches / Restart
   - 选择 **Invalidate and Restart**

### 解决方案 4: 检查 SDK 配置

1. **打开 SDK 设置**
   - Preferences/Settings → SDK

2. **验证 HarmonyOS SDK 已安装**
   - 查看 API Level 列表
   - 如果为空，勾选 API 10 或 API 11
   - 点击 Apply 下载

3. **设置 SDK Location**
   - 记下 SDK 路径，例如: `~/HarmonyOS/Sdk`

4. **更新 local.properties**
   ```bash
   cd "${HARMONYDESK_ROOT:?Set HARMONYDESK_ROOT to your checkout}/ohos"
   echo "sdk.dir=$HOME/HarmonyOS/Sdk" > local.properties
   ```

### 解决方案 5: 手动配置项目

如果自动识别失败，尝试手动配置:

1. **创建项目标记文件**
   ```bash
   cd "${HARMONYDESK_ROOT:?Set HARMONYDESK_ROOT to your checkout}/ohos"
   touch .project
   ```

2. **检查文件权限**
   ```bash
   chmod -R u+w .
   ```

### 解决方案 6: 使用命令行构建

如果 DevEco Studio 仍有问题，可以先用命令行测试:

```bash
cd "${HARMONYDESK_ROOT:?Set HARMONYDESK_ROOT to your checkout}/ohos"

# 如果有 hvigorw 脚本
./hvigorw --version

# 或使用 npm
npm install
npm run build
```

### 完整的项目检查清单

运行以下命令检查项目是否完整:

```bash
cd "${HARMONYDESK_ROOT:?Set HARMONYDESK_ROOT to your checkout}/ohos"

# 1. 检查必需文件
ls -la build-profile.json5
ls -la oh-package.json5
ls -la oh-package-lock.json5

# 2. 检查 AppScope
ls -la AppScope/app.json5
ls -la AppScope/resources/base/element/string.json

# 3. 检查 entry 模块
ls -la entry/build-profile.json5
ls -la entry/oh-package.json5
ls -la entry/src/main/module.json5

# 4. 检查源代码
ls -la entry/src/main/ets/pages/
ls -la entry/ohos/rust/src/

# 5. 检查配置
cat build-profile.json5
cat entry/build-profile.json5
```

### 常见错误和解决方法

#### 错误 1: "SDK not found"

**解决**:
```bash
# 设置 local.properties
echo "sdk.dir=$HOME/HarmonyOS/Sdk" > local.properties
```

#### 错误 2: "Cannot resolve symbol"

**解决**:
- File → Invalidate Caches / Restart
- 等待索引完成

#### 错误 3: "Module not found"

**解决**:
1. File → Project Structure → Modules
2. 检查 entry 模块是否被识别
3. 如果没有，点击 + → Import Module

#### 错误 4: "OHOS npm package failed"

**解决**:
```bash
# 清理缓存
rm -rf oh_modules
rm -f oh-package-lock.json5

# 重新安装
ohpm install
# 或
npm install
```

### 如果以上都无效

尝试创建一个新的 HarmonyOS 项目，然后将代码复制过去:

1. **创建新项目**
   - File → New → Create Project
   - 选择 "Empty Ability" 模板
   - 命名为 HarmonyDesk2

2. **复制代码**
   ```bash
   # 复制 ArkTS 代码
   cp -r harmonyos/entry/src/main/ets/* HarmonyDesk2/entry/src/main/ets/

   # 复制 Rust 代码
   cp -r harmonyos/entry/ohos HarmonyDesk2/entry/

   # 复制配置
   cp harmonyos/entry/src/main/module.json5 HarmonyDesk2/entry/src/main/
   ```

3. **更新配置**
   - 在新项目中更新 module.json5
   - 配置 Native Library 路径

### 获取帮助

如果问题仍然存在:

1. **查看 DevEco Studio 日志**
   - Help → Show Log in Finder
   - 查看错误信息

2. **检查系统要求**
   - macOS 10.15+ (对于 HarmonyOS 4.0+)
   - 至少 8GB RAM
   - 至少 10GB 可用磁盘空间

3. **查看官方文档**
   - https://developer.harmonyos.com/cn/docs/documentation/doc-guides-V3/ide-project-0000001053582083-V3

### 验证修复

修复后，你应该能够:
1. ✅ 打开 harmonyos 目录
2. ✅ 看到项目结构（entry 模块、AppScope 等）
3. ✅ 没有红色错误标记
4. ✅ 可以点击 Run 按钮
