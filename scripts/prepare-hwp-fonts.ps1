param(
    [string]$OutputDirectory,
    [string]$FontSourcePath,
    [switch]$Check,
    [ValidateSet('manifest.json', 'portable-export.json')][string]$ManifestName = 'manifest.json'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$metadataDirectory = Join-Path $projectRoot 'packages/ink_hwp_native/fonts'
$manifest = Get-Content -LiteralPath (Join-Path $metadataDirectory $ManifestName) -Raw | ConvertFrom-Json
$expectedLength = [long]$manifest.bytes
if ($expectedLength -le 0 -or $expectedLength -gt 50MB) { throw 'Invalid pinned HWP font size.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot (Split-Path -Path $manifest.assetPath -Parent) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$fontPath = Join-Path $OutputDirectory $manifest.fileName
$licensePath = Join-Path $OutputDirectory $manifest.license.fileName
$licenseSource = Join-Path $metadataDirectory $manifest.license.fileName

function Assert-PinnedFile([string]$Path, [long]$Length, [string]$Sha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required HWP font file is missing: $Path" }
    if ((Get-Item -LiteralPath $Path).Length -ne $Length) { throw "HWP font file size mismatch: $Path" }
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    $hashStream = [IO.File]::OpenRead($Path)
    try {
        $actualHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($hashStream)).Replace('-', '')
        if ($actualHash -ine $Sha256) { throw "HWP font file checksum mismatch: $Path" }
    } finally {
        $hashStream.Dispose()
        $hashAlgorithm.Dispose()
    }
}

Assert-PinnedFile $licenseSource ([long]$manifest.license.bytes) $manifest.license.sha256
if (Test-Path -LiteralPath $fontPath) { Assert-PinnedFile $fontPath $expectedLength $manifest.sha256 }
if (Test-Path -LiteralPath $licensePath) { Assert-PinnedFile $licensePath ([long]$manifest.license.bytes) $manifest.license.sha256 }
if ($Check) {
    Assert-PinnedFile $fontPath $expectedLength $manifest.sha256
    Assert-PinnedFile $licensePath ([long]$manifest.license.bytes) $manifest.license.sha256
    Write-Output $fontPath
    exit 0
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$temporary = Join-Path $OutputDirectory ('.hwp-font-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    if (-not (Test-Path -LiteralPath $fontPath -PathType Leaf)) {
        if ($FontSourcePath) {
            Assert-PinnedFile $FontSourcePath $expectedLength $manifest.sha256
            Copy-Item -LiteralPath $FontSourcePath -Destination $temporary
        } else {
            Add-Type -AssemblyName System.Net.Http
            $client = [Net.Http.HttpClient]::new()
            $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(60))
            $response = $null
            $inputStream = $null
            $outputStream = $null
            try {
                $client.DefaultRequestHeaders.UserAgent.ParseAdd('PersonalInkVault-HwpFontPreparer/1')
                $response = $client.GetAsync($manifest.sourceUrl, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
                $response.EnsureSuccessStatusCode() | Out-Null
                if ($response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $expectedLength) {
                    throw 'Pinned HWP font download has an unexpected Content-Length.'
                }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = [byte[]]::new(65536)
                $received = 0L
                while (($count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                    $received += $count
                    if ($received -gt $expectedLength) { throw 'Pinned HWP font download exceeded its size limit.' }
                    $outputStream.Write($buffer, 0, $count)
                }
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
                if ($response) { $response.Dispose() }
                $cancel.Dispose()
                $client.Dispose()
            }
        }
        Assert-PinnedFile $temporary $expectedLength $manifest.sha256
        Move-Item -LiteralPath $temporary -Destination $fontPath
    }
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        Copy-Item -LiteralPath $licenseSource -Destination $temporary
        Assert-PinnedFile $temporary ([long]$manifest.license.bytes) $manifest.license.sha256
        Move-Item -LiteralPath $temporary -Destination $licensePath
    }
    Assert-PinnedFile $fontPath $expectedLength $manifest.sha256
    Assert-PinnedFile $licensePath ([long]$manifest.license.bytes) $manifest.license.sha256
    Write-Output $fontPath
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
}
exit 0
