@echo off
setlocal
if not defined DEVECO_STUDIO_HOME set "DEVECO_STUDIO_HOME=%ProgramFiles%\Huawei\DevEco Studio"
if not exist "%DEVECO_STUDIO_HOME%\tools\hvigor\bin\hvigorw.bat" (
  echo Set DEVECO_STUDIO_HOME to your DevEco Studio installation.
  exit /b 1
)
if not defined JAVA_HOME set "JAVA_HOME=%DEVECO_STUDIO_HOME%\jbr"
if not defined NODE_HOME set "NODE_HOME=%DEVECO_STUDIO_HOME%\tools\node"
if not defined DEVECO_SDK_HOME set "DEVECO_SDK_HOME=%DEVECO_STUDIO_HOME%\sdk"
if not defined OHOS_BASE_SDK_HOME set "OHOS_BASE_SDK_HOME=%DEVECO_SDK_HOME%\default\openharmony"
set "PATH=%NODE_HOME%;%JAVA_HOME%\bin;%DEVECO_STUDIO_HOME%\tools\ohpm\bin;%DEVECO_STUDIO_HOME%\tools\hvigor\bin;%PATH%"
cd /d "%~dp0..\ohos"
if errorlevel 1 exit /b 1
call "%DEVECO_STUDIO_HOME%\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
exit /b %ERRORLEVEL%
