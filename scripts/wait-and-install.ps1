# Wait for USB authorization, then install a locally built HAP if present.
param([string]$HdcPath = $env:HDC_PATH)
$ErrorActionPreference = "Continue"
if (-not $HdcPath) {
  $command = Get-Command hdc -ErrorAction SilentlyContinue
  if (-not $command) { throw 'Set HDC_PATH or add hdc to PATH.' }
  $HdcPath = $command.Source
}
$hdc = $HdcPath
$hapCandidates = @(
  (Join-Path $PSScriptRoot "..\ohos\entry\build\default\outputs\default\entry-default-signed.hap"),
  (Join-Path $PSScriptRoot "..\ohos\entry\build\default\outputs\default\entry-default-unsigned.hap")
)

Write-Host "Waiting for hdc authorization. Unlock the phone and tap Trust / Allow USB debugging."
for ($i = 0; $i -lt 60; $i++) {
  $targets = & $hdc list targets 2>&1 | Out-String
  Write-Host ("Checking device authorization (attempt {0})" -f ($i + 1))
  if ($targets -match "Unauthorized") {
    Start-Sleep 3
    continue
  }
  $serial = ($targets -split "\s+") | Where-Object { $_ -and $_ -notmatch "Empty|\[|Fail" } | Select-Object -First 1
  if ($serial) {
    Write-Host 'An authorized device is available.'
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
