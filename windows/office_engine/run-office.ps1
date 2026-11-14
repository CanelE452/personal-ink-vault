param([Parameter(Mandatory)][string]$RuntimePath,
      [Parameter(Mandatory)][string]$RequestPath,
      [Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
$python = Join-Path $RuntimePath 'program/python.exe'
$worker = Join-Path $PSScriptRoot 'office_worker.py'
$arguments = @('-I', '-B', "`"$worker`"", '--runtime', "`"$RuntimePath`"", '--request', "`"$RequestPath`"", '--response', "`"$ResponsePath`"")
. (Join-Path $PSScriptRoot 'worker_job.ps1')
exit [PivOfficeWorkerJob]::Run($python, ($arguments -join ' '), (Split-Path -Parent $python), 210000)
