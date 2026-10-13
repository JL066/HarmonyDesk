$ErrorActionPreference = 'Stop'

$javac = Get-Command javac -ErrorAction SilentlyContinue
$java = Get-Command java -ErrorAction SilentlyContinue
if ($null -eq $javac -or $null -eq $java) {
    throw 'A JDK with javac and java is required to run these pure Java tests.'
}

$packagePath = 'app/src/main/java/io/github/jl066/harmonydesk'
$sourceRoot = Join-Path $PSScriptRoot '..'
$classesPath = Join-Path ([System.IO.Path]::GetTempPath()) ('harmonydesk-android-input-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$resolvedClasses = [System.IO.Path]::GetFullPath($classesPath)
if (-not $resolvedClasses.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create test output outside the system temporary directory.'
}
New-Item -ItemType Directory -Path $resolvedClasses | Out-Null

try {
    $sources = @(
        (Join-Path $sourceRoot (Join-Path $packagePath 'InputSink.java')),
        (Join-Path $sourceRoot (Join-Path $packagePath 'Viewport.java')),
        (Join-Path $PSScriptRoot 'RemoteInputGeometryTest.java')
    )
    & $javac.Source --release 17 -encoding UTF-8 -d $resolvedClasses $sources
    if ($LASTEXITCODE -ne 0) {
        throw "javac failed with exit code $LASTEXITCODE"
    }
    & $java.Source -cp $resolvedClasses io.github.jl066.harmonydesk.RemoteInputGeometryTest
    if ($LASTEXITCODE -ne 0) {
        throw "Java tests failed with exit code $LASTEXITCODE"
    }
} finally {
    if (Test-Path -LiteralPath $resolvedClasses) {
        Remove-Item -LiteralPath $resolvedClasses -Recurse -Force
    }
}
