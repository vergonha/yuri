# Self-check for the riskiest logic: machine PATH editing and version resolution.
# Run: powershell -ExecutionPolicy Bypass -File tests\selfcheck.ps1
# Uses a temp folder and a fake provider; no network, no registry writes.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($f in Get-ChildItem (Join-Path $root 'core') -Filter '*.ps1') { . $f.FullName }

function Check([bool]$Ok, [string]$What) { if (-not $Ok) { throw "FAILED: $What" } }

# PATH: %VARS% stay as text, our entries go first, no duplicates, idempotent.
$raw = '%SystemRoot%\system32;C:\Program Files\nodejs\;;C:\yuri\bin\;%USERPROFILE%\x'
$ours = @('C:\yuri\bin', 'C:\yuri\current\node')
$new = Add-PathEntries $raw $ours
Check ($new -ceq 'C:\yuri\bin;C:\yuri\current\node;%SystemRoot%\system32;C:\Program Files\nodejs\;%USERPROFILE%\x') "Add-PathEntries: $new"
Check ((Add-PathEntries $new $ours) -ceq $new) 'Add-PathEntries is not idempotent'

# Resolution, with a fake provider and a fake install folder.
$script:YuriHome = Join-Path ([IO.Path]::GetTempPath()) ('yuri-selfcheck-' + [guid]::NewGuid().ToString('N'))
$script:YuriRoot = $script:YuriHome
try {
    Register-YuriProvider @{
        Name = 'fake'; Executable = 'fake.exe'
        GetArtifact = { throw 'no downloads in the self-check' }
        ListRemote = {
            [pscustomobject]@{ Version = '22.10.0'; Lts = 'Jod'; Date = '' }
            [pscustomobject]@{ Version = '22.9.0'; Lts = 'Jod'; Date = '' }
            [pscustomobject]@{ Version = '23.1.0'; Lts = ''; Date = '' }
            [pscustomobject]@{ Version = '2.0.0'; Lts = ''; Date = '' }
        }
        ResolveNamed = {
            param($Spec)
            if ($Spec -eq 'lts') { return @{ Kind = 'moving'; Filter = { param($e, $a) [bool]$e.Lts }; Arg = $null } }
        }
    }
    $P = Get-YuriProvider 'fake'
    function Use([string]$Spec) { Resolve-UseVersion $P (Get-SpecInfo $P $Spec) }

    Check ((Use '22') -eq '22.10.0') '22 with nothing installed -> newest published 22.x (numeric, not text, sort)'
    Check ((Use '2') -eq '2.0.0') '2 must not match 22.x'
    Check ((Use 'latest') -eq '23.1.0') 'latest'
    Check ((Use 'lts') -eq '22.10.0') 'lts'

    $dir = Get-InstallDir $P '22.9.0'
    New-Dir $dir
    [IO.File]::WriteAllText((Join-Path $dir 'fake.exe'), '')
    Check ((Use '22') -eq '22.9.0') '22 -> installed 22.x wins over newer published'
    Check ((Use 'lts') -eq '22.10.0') 'lts is moving: newest published even if an older one is installed'
    Check ((Use 'v22.9.0') -eq '22.9.0') 'leading v'
} finally {
    Remove-DirectorySafe $script:YuriHome
}
Write-Host 'selfcheck ok' -ForegroundColor Green
