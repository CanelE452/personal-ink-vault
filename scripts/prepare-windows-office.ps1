$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$preparer = Join-Path $repository 'windows/office_engine/prepare_runtime.py'
& python $preparer
if ($LASTEXITCODE -ne 0) { throw "Windows Office runtime preparation failed: $LASTEXITCODE" }
