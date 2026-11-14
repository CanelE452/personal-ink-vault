param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [string]$RustToolchainRoot,
    [string]$TargetDirectory = $env:INK_VAULT_MCP_TARGET_DIR
)

$ErrorActionPreference = 'Stop'
$mcpProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$mcpManifest = Join-Path $mcpProjectRoot 'packages/ink_vault_mcp/Cargo.toml'
$mcpTargetRoot = if ($TargetDirectory) { $TargetDirectory } else { Join-Path $mcpProjectRoot 'build/mcp-target' }
if (-not $RustToolchainRoot -and $env:LOCALAPPDATA) {
    $mcpPortableRust = Join-Path $env:LOCALAPPDATA 'PersonalInkVault/tools/rust'
    if (Test-Path -LiteralPath $mcpPortableRust -PathType Container) { $RustToolchainRoot = $mcpPortableRust }
}
if ($RustToolchainRoot) {
    $env:CARGO_HOME = Join-Path $RustToolchainRoot 'cargo'
    $env:RUSTUP_HOME = Join-Path $RustToolchainRoot 'rustup'
    $env:Path = (Join-Path $env:CARGO_HOME 'bin') + [IO.Path]::PathSeparator + $env:Path
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'Rust 1.99.1 is required. Pass -RustToolchainRoot or enable cargo in this process.'
}
$mcpArguments = @('+1.99.1', 'build', '--locked', '--manifest-path', $mcpManifest, '--target-dir', $mcpTargetRoot, '--target', 'x86_64-pc-windows-msvc')
if ($Configuration -eq 'release') { $mcpArguments += '--release' }
& cargo @mcpArguments
if ($LASTEXITCODE -ne 0) { throw "MCP server build failed ($LASTEXITCODE)." }
$mcpDestination = Join-Path $mcpProjectRoot 'build/native/windows'
New-Item -ItemType Directory -Path $mcpDestination -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $mcpTargetRoot "x86_64-pc-windows-msvc/$Configuration/ink_vault_mcp.exe") -Destination (Join-Path $mcpDestination 'ink_vault_mcp.exe') -Force
Copy-Item -LiteralPath (Join-Path $mcpProjectRoot 'packages/ink_vault_mcp/THIRD_PARTY_LICENSES.txt') -Destination (Join-Path $mcpDestination 'ink-vault-mcp-THIRD-PARTY-LICENSES.txt') -Force
Write-Output (Join-Path $mcpDestination 'ink_vault_mcp.exe')
