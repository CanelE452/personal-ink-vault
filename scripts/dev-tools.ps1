param(
    [string]$FlutterRoot,
    [string]$AndroidSdkRoot,
    [string]$JavaRoot
)

# Dot-source this script to change only the current PowerShell process.
foreach ($toolRoot in @($FlutterRoot, $AndroidSdkRoot, $JavaRoot)) {
    if ($toolRoot -and -not (Test-Path -LiteralPath $toolRoot -PathType Container)) {
        throw "Tool directory does not exist: $toolRoot"
    }
}
if ($FlutterRoot) { $env:PATH = (Join-Path $FlutterRoot 'bin') + [IO.Path]::PathSeparator + $env:PATH }
if ($AndroidSdkRoot) {
    $env:ANDROID_HOME = (Resolve-Path -LiteralPath $AndroidSdkRoot).Path
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:PATH = (Join-Path $env:ANDROID_HOME 'platform-tools') + [IO.Path]::PathSeparator + $env:PATH
}
if ($JavaRoot) {
    $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaRoot).Path
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + [IO.Path]::PathSeparator + $env:PATH
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Pass -FlutterRoot or put Flutter on the existing process PATH.'
}
Write-Output 'Development tools enabled for this PowerShell process. No global settings changed.'
