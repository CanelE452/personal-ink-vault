param([Parameter(Mandatory)][string]$RuntimePath,
      [Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$python = Join-Path $RuntimePath 'program/python.exe'
$worker = Join-Path $PSScriptRoot 'office_interactive.py'
$requestFile = Get-Item -LiteralPath $RequestPath
if ($requestFile.Length -gt 65536) { throw 'The private Office request exceeds its limit.' }
$request = [IO.File]::ReadAllText($requestFile.FullName, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$ownerId = [uint32]$request.parentProcessId
$ownerExecutable = [string]$request.parentExecutablePath
$arguments = @('-I', '-B', "`"$worker`"", '--runtime', "`"$RuntimePath`"", '--request', "`"$RequestPath`"")
. (Join-Path $PSScriptRoot 'worker_job.ps1')
exit [PivOfficeWorkerJob]::RunParentBound($python, ($arguments -join ' '), (Split-Path -Parent $python), $ownerId, $ownerExecutable)
