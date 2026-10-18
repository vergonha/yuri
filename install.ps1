<#
.SYNOPSIS
    Sets up yuri.

.DESCRIPTION
    Copies yuri to the prefix folder (default C:\yuri), lets your user write
    to it, and adds its folders to the machine PATH. Asks for administrator
    rights once (UAC); after that, installing and switching versions never
    needs admin. Run it again at any time to update yuri.

    If the execution policy for your user blocks scripts, it is set to
    RemoteSigned (your user only, not the whole machine).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param(
    [string]$Prefix = 'C:\yuri',
    # Internal: used when the script restarts itself elevated.
    [switch]$Elevated,
    [string]$UserSid,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$Source = $PSScriptRoot
$Prefix = [IO.Path]::GetFullPath($Prefix).TrimEnd('\')

foreach ($setupDir in 'core', 'providers') {
    foreach ($setupFile in Get-ChildItem -Path (Join-Path $Source $setupDir) -Filter '*.ps1') {
        . $setupFile.FullName
    }
}
$script:YuriRoot = $Prefix
$script:YuriHome = $Prefix

function Say([string]$Message, [string]$Color = '') {
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Message -Encoding UTF8 }
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisites {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'PowerShell 5.1 or later is required' }
    foreach ($tool in 'curl.exe', 'tar.exe', 'icacls.exe') {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "$tool not found. It ships with Windows 10 1803 and later."
        }
    }
    if ([IO.Path]::GetPathRoot($Prefix).TrimEnd('\') -eq $Prefix) { throw "refusing to use a drive root ($Prefix) as the prefix" }
}

# Runs as the normal user: CurrentUser policy belongs to whoever runs it.
function Set-UserExecutionPolicy {
    $current = Get-PolicyWithoutProcess
    if (Test-PolicyAllowsScripts $current.Policy) {
        Say "Execution policy: $($current.Policy), no change needed"
        return
    }
    if ($current.Scope -in 'MachinePolicy', 'UserPolicy') {
        Say "warning: the execution policy ($($current.Policy)) is set by Group Policy, which blocks yuri (and npm in PowerShell). Ask your IT team to allow RemoteSigned." Yellow
        return
    }
    # Throws "overridden by a more specific scope" when this process runs
    # with -ExecutionPolicy Bypass, even though the change was saved.
    try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch { }
    if ((Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned') {
        Say "Execution policy for your user: RemoteSigned (was $($current.Policy))"
    } else {
        Say "warning: could not set the execution policy. Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" Yellow
    }
}

function Copy-YuriFiles {
    if ((ConvertTo-NormalPath $Source) -eq (ConvertTo-NormalPath $Prefix)) { return }
    foreach ($dir in 'bin', 'core', 'providers') {
        $target = Join-Path $Prefix $dir
        New-Dir $target
        Get-ChildItem -LiteralPath $target -File | Remove-Item -Force
        Copy-Item -Path (Join-Path $Source "$dir\*") -Destination $target -Force
    }
    foreach ($file in 'install.ps1', 'README.md') {
        $from = Join-Path $Source $file
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $Prefix -Force }
    }
}

function Get-OurFiles {
    foreach ($dir in 'bin', 'core', 'providers') { Get-ChildItem -LiteralPath (Join-Path $Prefix $dir) -File }
    Get-Item -LiteralPath (Join-Path $Prefix 'install.ps1') -ErrorAction SilentlyContinue
}

function Invoke-Setup([string]$Sid) {
    Say "Installing yuri $script:YuriVersion to $Prefix"
    New-Dir $Prefix
    foreach ($dir in 'installs', 'current', 'cache') { New-Dir (Join-Path $Prefix $dir) }
    Copy-YuriFiles
    Get-OurFiles | Unblock-File
    Say '  files copied'

    # Only admins and your user can write here. Every other user can read and run.
    # Owner and old rules are reset first: anyone may have created this folder before us.
    foreach ($fix in @('/setowner', '*S-1-5-32-544'), @('/reset')) {
        $code = Invoke-Exe 'icacls.exe' (@($Prefix) + $fix + @('/T', '/C', '/Q'))
        if ($code -ne 0) { throw "icacls $($fix[0]) failed (exit code $code)" }
    }
    $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', "*${Sid}:(OI)(CI)M")
    $code = Invoke-Exe 'icacls.exe' (@($Prefix, '/inheritance:r', '/grant:r') + $grants + @('/C', '/Q'))
    if ($code -ne 0) { throw "icacls failed (exit code $code)" }
    Say '  write permission granted to your user'

    $entries = @(Get-YuriPathEntries)
    $raw = Get-RawPath Machine
    $new = Add-PathEntries $raw $entries
    if ($new -cne $raw) {
        $backup = Join-Path $Prefix ('cache\machine-path-backup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [IO.File]::WriteAllText($backup, $raw)
        Set-RawPath Machine $new
        Send-EnvironmentChange
        Say "  machine PATH: added $($entries -join ' and ')"
        Say "  (previous PATH saved to $backup)"
    } else {
        Say '  machine PATH already set up'
    }

    foreach ($P in Get-YuriProviders) {
        foreach ($scope in 'Machine', 'User') {
            foreach ($entry in ((Get-RawPath $scope) -split ';')) {
                $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim())
                if (-not $dir -or (ConvertTo-NormalPath $dir).StartsWith((ConvertTo-NormalPath $Prefix) + '\')) { continue }
                if (Test-Path -LiteralPath (Join-Path $dir $P.Executable)) {
                    Say "warning: another $($P.Executable) is in the $($scope.ToLower()) PATH: $dir. yuri comes first in PATH, but consider uninstalling that copy." Yellow
                }
            }
        }
    }
}

# ---- main --------------------------------------------------------------

if ($Elevated) {
    try {
        Invoke-Setup $UserSid
        exit 0
    } catch {
        Say "ERROR: $($_.Exception.Message)" Red
        exit 1
    }
}

try {
    Assert-Prerequisites
    Set-UserExecutionPolicy
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    if (Test-IsAdmin) {
        Invoke-Setup $sid
    } else {
        $log = Join-Path ([IO.Path]::GetTempPath()) (New-TempName 'yuri-setup-')
        $log += '.log'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            '-Elevated', '-Prefix', "`"$Prefix`"", '-UserSid', $sid, '-LogFile', "`"$log`"")
        Say 'Asking for administrator rights (a UAC prompt will appear)...'
        try {
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ') -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        } catch {
            throw 'administrator rights are needed once, for the setup. The UAC prompt was cancelled.'
        }
        if (Test-Path -LiteralPath $log) {
            foreach ($line in Get-Content -LiteralPath $log) {
                $color = 'Gray'
                if ($line.StartsWith('warning:')) { $color = 'Yellow' }
                if ($line.StartsWith('ERROR:')) { $color = 'Red' }
                Write-Host $line -ForegroundColor $color
            }
            Remove-Item -LiteralPath $log -Force
        }
        if ($proc.ExitCode -ne 0) {
            Write-Host "ERROR: setup failed (exit code $($proc.ExitCode))" -ForegroundColor Red
            exit $proc.ExitCode
        }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Done. Open a NEW terminal and run:' -ForegroundColor Green
Write-Host '  yuri use node        (installs and activates the latest LTS)'
Write-Host '  yuri doctor          (checks for leftovers of other Node installs)'
