@echo off
if not defined DEVECO_DIR set "DEVECO_DIR=%ProgramFiles%\Huawei\DevEco Studio"
if not exist "%DEVECO_DIR%\tools\hvigor\bin\hvigorw.bat" (
  echo DevEco Studio not found. Set DEVECO_DIR to its install folder.
  exit /b 2
)

set "JAVA_HOME=%DEVECO_DIR%\jbr"
set "NODE_HOME=%DEVECO_DIR%\tools\node"
set "DEVECO_SDK_HOME=%DEVECO_DIR%\sdk"
set "OHOS_BASE_SDK_HOME=%DEVECO_DIR%\sdk\default\openharmony"
set "PATH=%NODE_HOME%;%JAVA_HOME%\bin;%DEVECO_DIR%\tools\ohpm\bin;%DEVECO_DIR%\tools\hvigor\bin;%PATH%"

pushd "%~dp0..\ohos"
call "%DEVECO_DIR%\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
set "ERR=%ERRORLEVEL%"
popd
exit /b %ERR%
