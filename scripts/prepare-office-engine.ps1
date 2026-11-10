param([string]$ApkPath)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$preparer = Join-Path $repository 'android/office_engine/prepare_engine.py'
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'Python 3.11 or newer is required to prepare the Office engine.' }
$arguments = @($preparer)
if ($ApkPath) { $arguments += @('--apk-path', $ApkPath) }
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw "Office engine preparation failed: $LASTEXITCODE" }
