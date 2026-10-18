# yuri - version manager for Windows (PowerShell 5.1+). Run 'yuri help'.
#
# Runs inside the calling PowerShell process. Everything it defines stays in
# this script's scope, so nothing leaks into the user's session.

$yuriArgs = $args   # saved first: dot-sourcing below would overwrite $args
$ErrorActionPreference = 'Stop'

$script:YuriRoot = Split-Path -Parent $PSScriptRoot
$script:YuriHome = $script:YuriRoot
if ($env:YURI_HOME) { $script:YuriHome = $env:YURI_HOME.TrimEnd('\') }

foreach ($yuriDir in 'core', 'providers') {
    foreach ($yuriFile in Get-ChildItem -Path (Join-Path $script:YuriRoot $yuriDir) -Filter '*.ps1') {
        . $yuriFile.FullName
    }
}

Invoke-Yuri -Arguments $yuriArgs
exit $script:YuriExitCode
