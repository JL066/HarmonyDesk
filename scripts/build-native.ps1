# Build HarmonyDesk Rust native .so for Mate 80 (aarch64 OHOS)
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RustDir = Join-Path $RepoRoot "ohos\entry\ohos\rust"
$CoreDir = Join-Path $RepoRoot "ohos\entry\ohos\hdcore"
$LibOut = Join-Path $RepoRoot "ohos\entry\libs\arm64-v8a"
$Target = "aarch64-unknown-linux-ohos"

$mingw = Join-Path $env:ProgramFiles "mingw-w64\bin"
if (Test-Path $mingw) { $env:PATH = "$mingw;$env:PATH" }
$cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }

if (-not $env:OHOS_NATIVE_HOME) {
  $devecoDir = $env:DEVECO_DIR
  if (-not $devecoDir) { $devecoDir = Join-Path $env:ProgramFiles "Huawei\DevEco Studio" }
  $candidates = @(
    (Join-Path $devecoDir "sdk\default\openharmony\native"),
    (Join-Path $env:LOCALAPPDATA "Huawei\Sdk\openharmony\native")
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "llvm\bin\clang.exe")) {
      $env:OHOS_NATIVE_HOME = $c
      break
    }
  }
}

if (-not $env:OHOS_NATIVE_HOME) {
  throw "OHOS_NATIVE_HOME not set and native clang not found. Extract the OHOS SDK native package first."
}

$env:HARMONYOS_NDK_PATH = $env:OHOS_NATIVE_HOME
$llvm = Join-Path $env:OHOS_NATIVE_HOME "llvm\bin"
$sysroot = Join-Path $env:OHOS_NATIVE_HOME "sysroot"
$env:AR = Join-Path $llvm "llvm-ar.exe"
$env:CC = Join-Path $llvm "clang.exe"
$env:CXX = Join-Path $llvm "clang++.exe"
$env:RANLIB = Join-Path $llvm "llvm-ranlib.exe"
$env:PATH = "$llvm;" + $env:PATH
$env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER = Join-Path $llvm "clang.exe"
$sep = [char]0x1f
$env:CARGO_ENCODED_RUSTFLAGS = "-C${sep}link-arg=--target=aarch64-linux-ohos${sep}-C${sep}link-arg=--sysroot=$sysroot"
Remove-Item env:RUSTFLAGS -ErrorAction SilentlyContinue

Write-Host "Using OHOS native SDK"
Write-Host "Building $Target ..."

Push-Location $CoreDir
try {
  cargo build --target $Target --release
  $cargoExitCode = $LASTEXITCODE
  if ($cargoExitCode -ne 0) {
    throw "cargo build failed with exit code $cargoExitCode; existing native library was not copied"
  }
} finally {
  Pop-Location
}

$so = Join-Path $CoreDir "target\$Target\release\libhdcore.so"
if (-not (Test-Path $so)) {
  throw "Build finished but $so was not produced"
}

New-Item -ItemType Directory -Force -Path $LibOut | Out-Null
Copy-Item $so (Join-Path $LibOut "libhdcore.so") -Force
Write-Host "Copied $(Join-Path $LibOut 'libhdcore.so')"
Get-Item (Join-Path $LibOut "libhdcore.so") | Format-List FullName, Length, LastWriteTime
