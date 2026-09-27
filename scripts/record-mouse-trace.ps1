param(
  [string]$Serial = $env:HDC_SERIAL,
  [string]$HdcPath = $env:HDC_PATH,
  [string]$OutputPath = (Join-Path $PSScriptRoot 'mouse-trace.log')
)
$ErrorActionPreference = "Continue"
if (-not $Serial) { throw "Set -Serial or HDC_SERIAL to the target device serial." }
if (-not $HdcPath) {
  $hdcCommand = Get-Command hdc -ErrorAction SilentlyContinue
  if (-not $hdcCommand) { throw "Set -HdcPath or HDC_PATH, or add hdc to PATH." }
  $HdcPath = $hdcCommand.Source
}
if (-not (Test-Path -LiteralPath $HdcPath)) { throw "HDC executable was not found at the configured HDC_PATH." }
$hdc = $HdcPath
$out = $OutputPath

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
