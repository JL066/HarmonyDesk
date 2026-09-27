param([string]$HdcPath = $env:HDC_PATH)
# Wait for USB authorization, then install a signed HAP if present.
$ErrorActionPreference = "Continue"
if (-not $HdcPath) {
  $hdcCommand = Get-Command hdc -ErrorAction SilentlyContinue
  if (-not $hdcCommand) { throw "Set -HdcPath or HDC_PATH, or add hdc to PATH." }
  $HdcPath = $hdcCommand.Source
}
if (-not (Test-Path -LiteralPath $HdcPath)) { throw "HDC executable was not found at the configured HDC_PATH." }
$hdc = $HdcPath
$hapCandidates = @(
  (Join-Path $PSScriptRoot "..\ohos\entry\build\default\outputs\default\entry-default-signed.hap"),
  (Join-Path $PSScriptRoot "..\ohos\entry\build\default\outputs\default\entry-default-unsigned.hap")
)

Write-Host "Waiting for hdc authorization. Unlock the phone and tap Trust / Allow USB debugging."
for ($i = 0; $i -lt 60; $i++) {
  $targets = & $hdc list targets 2>&1 | Out-String
  Write-Host ("[{0}] {1}" -f $i, $targets.Trim())
  if ($targets -match "Unauthorized") {
    Start-Sleep 3
    continue
  }
  $serial = ($targets -split "\s+") | Where-Object { $_ -and $_ -notmatch "Empty|\[|Fail" } | Select-Object -First 1
  if ($serial) {
    Write-Host "Authorized device: $serial"
    Write-Host "Model / API:"
    & $hdc -t $serial shell "param get const.product.model; param get const.ohos.apiversion; param get const.ohos.fullname"
    $hap = $hapCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $hap) {
      Write-Host "No HAP built yet. Native .so is ready; HAP still needs hvigor + debug cert."
      exit 2
    }
    Write-Host "Installing $hap"
    & $hdc -t $serial install $hap
    exit $LASTEXITCODE
  }
  Start-Sleep 3
}
Write-Host "Timed out waiting for USB authorization."
exit 1
