// Resolve SDK test dependencies without embedding a developer machine path.
const fs = require('node:fs');
const path = require('node:path');
function sdkFile(relative) {
  const roots = [process.env.OHOS_BASE_SDK_HOME,
    process.env.DEVECO_SDK_HOME && path.join(process.env.DEVECO_SDK_HOME, 'default', 'openharmony'),
    process.env.DEVECO_DIR && path.join(process.env.DEVECO_DIR, 'sdk', 'default', 'openharmony'),
    process.env.ProgramFiles && path.join(process.env.ProgramFiles, 'Huawei', 'DevEco Studio', 'sdk', 'default', 'openharmony')].filter(Boolean);
  for (const root of roots) {
    const candidate = path.join(root, relative);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error('Set OHOS_BASE_SDK_HOME or DEVECO_SDK_HOME to run HarmonyOS tests.');
}
exports.typescript = () => require(process.env.HARMONY_TYPESCRIPT || sdkFile('ets/build-tools/ets-loader/node_modules/typescript'));
exports.keyCodes = () => process.env.HARMONY_KEYCODE_DTS || sdkFile('ets/api/@ohos.multimodalInput.keyCode.d.ts');
