param([Parameter(Mandatory)][string]$RuntimePath,
      [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$python = Join-Path $RuntimePath 'program/python.exe'
$testScript = Join-Path $PSScriptRoot 'test_native.py'
$arguments = @('-I', '-B', "`"$testScript`"", '--runtime', "`"$RuntimePath`"", '--output', "`"$OutputPath`"")
. (Join-Path $PSScriptRoot 'worker_job.ps1')
$testExit = [PivOfficeWorkerJob]::Run($python, ($arguments -join ' '), (Split-Path -Parent $python), 210000)
if ($testExit -ne 0) { throw "Document engine test failed: $testExit. See $OutputPath.error.txt" }
Get-Content -LiteralPath (Join-Path $OutputPath 'result.json')
