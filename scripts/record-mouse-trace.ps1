param(
  [string]$HdcPath = $env:HDC_PATH,
  [string]$DeviceId = $env:HDC_DEVICE_ID
)
$ErrorActionPreference = "Stop"
if (-not $HdcPath) {
  $command = Get-Command hdc -ErrorAction SilentlyContinue
  if (-not $command) { throw 'Set HDC_PATH or add hdc to PATH.' }
  $HdcPath = $command.Source
}
if (-not $DeviceId -or $DeviceId -notmatch '^[A-Za-z0-9_.:-]+$') {
  throw 'Set HDC_DEVICE_ID or pass -DeviceId with the target device identifier.'
}
$hdc = $HdcPath
$serial = $DeviceId
$out = Join-Path (Split-Path -Parent $PSScriptRoot) 'mouse_trace.log'

if (Test-Path $out) {
  Remove-Item $out -Force
}

Write-Host "Clearing device hilog..."
& $hdc -t $serial shell "hilog -r" | Out-Null

Write-Host "Recording MOUSE_TRACE to $out"
Write-Host "Operate the virtual mouse now. Ctrl+C to stop."

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $hdc
$psi.Arguments = "-t $serial hilog"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$writer = [System.IO.StreamWriter]::new($out, $false, [System.Text.Encoding]::UTF8)

try {
  while (-not $proc.HasExited) {
    $line = $proc.StandardOutput.ReadLine()
    if ($null -eq $line) {
      break
    }
    if ($line -match "MOUSE_TRACE") {
      $writer.WriteLine($line)
      $writer.Flush()
      Write-Host $line
    }
  }
} finally {
  $writer.Close()
  if (-not $proc.HasExited) {
    $proc.Kill()
  }
}
