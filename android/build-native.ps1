param([string]$SdkRoot = $env:ANDROID_HOME)
$ErrorActionPreference = 'Stop'
if (-not $SdkRoot) { throw 'Set ANDROID_HOME or pass -SdkRoot.' }
$repo = Split-Path -Parent $PSScriptRoot
$ndk = Join-Path $SdkRoot 'ndk\27.2.12479018'
$llvm = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
$linker = Join-Path $llvm 'aarch64-linux-android26-clang.cmd'
if (-not (Test-Path -LiteralPath $linker)) { throw 'Install NDK 27.2.12479018 with SDK Manager.' }
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $linker
$env:CARGO_TARGET_DIR = Join-Path $PSScriptRoot '.native-build'
$env:RUSTFLAGS = '-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-soname,libhdcore.so'
& cargo build --manifest-path (Join-Path $repo 'ohos\entry\ohos\hdcore\Cargo.toml') --release --target aarch64-linux-android
if ($LASTEXITCODE -ne 0) { throw 'Android Rust core build failed.' }
$output = Join-Path $PSScriptRoot 'app\src\main\jniLibs\arm64-v8a'
New-Item -ItemType Directory -Force $output | Out-Null
Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'aarch64-linux-android\release\libhdcore.so') -Destination $output
