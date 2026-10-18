# Command line: dispatch, commands and help.

$script:YuriExitCode = 0

function Invoke-Yuri {
    param([object[]]$Arguments)
    $script:YuriExitCode = 0
    $argv = @($Arguments | ForEach-Object { [string]$_ })
    try {
        if ($argv.Count -eq 0) { Show-YuriHelp; return }
        $command = $argv[0].ToLowerInvariant()
        $rest = @()
        if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

        if (@($argv | Where-Object { $_ -in '-h', '--help', '/?' }).Count -gt 0) { $command = 'help' }

        switch ($command) {
            'use'       { Invoke-UseCommand $rest }
            'install'   { Invoke-InstallCommand $rest }
            'list'      { Invoke-ListCommand $rest }
            'ls-remote' { Invoke-LsRemoteCommand $rest }
            'current'   { Invoke-CurrentCommand $rest }
            'which'     { Invoke-WhichCommand $rest }
            'uninstall' { Invoke-UninstallCommand $rest }
            'doctor'    { Invoke-DoctorCommand $rest }
            'help'      { Show-YuriHelp }
            default     { throw "unknown command '$($argv[0])'. Run 'yuri help'." }
        }
    } catch {
        $Host.UI.WriteErrorLine("yuri: $($_.Exception.Message)")
        if ($env:YURI_DEBUG) { $Host.UI.WriteErrorLine($_.ScriptStackTrace) }
        $script:YuriExitCode = 1
    }
}

function Get-ProviderArgs([string[]]$Argv, [string]$Usage) {
    if ($Argv.Count -gt 1) { throw "usage: $Usage" }
    if ($Argv.Count -eq 0) { return Get-YuriProviders }
    if ($Argv[0].Contains('@')) { throw "usage: $Usage" }
    Get-YuriProvider $Argv[0]
}

# Warns when this terminal was opened before the setup changed PATH.
function Test-SessionPath($P) {
    $dir = Get-BinDir $P (Get-CurrentLink $P)
    if (-not (Test-PathListHas $env:PATH $dir)) {
        Write-Warn "this terminal's PATH does not include $dir. Open a new terminal. If that does not help, run install.ps1 again."
    }
}

function Use-ToolVersion($P, [string]$Version) {
    # Re-applying PostInstall is cheap and repairs settings that got lost.
    if ($P.PostInstall) { $null = & $P.PostInstall (Get-InstallDir $P $Version) $Version }
    $previous = Get-ActiveVersion $P
    if ($previous -eq $Version) {
        Write-Host "$($P.Name) $Version is already active"
    } else {
        Set-ActiveVersion $P $Version
        $was = ''
        if ($previous) { $was = " (was $previous)" }
        Write-Host "Now using $($P.Name) $Version$was" -ForegroundColor Green
    }
    Test-SessionPath $P
}

# ---- commands ----------------------------------------------------------

function Invoke-UseCommand([string[]]$Argv) {
    if ($Argv.Count -gt 1) { throw 'usage: yuri use <tool>[@<version>]' }
    if ($Argv.Count -eq 0) {
        $request = Find-VersionFileRequest
        if (-not $request) {
            $files = @(Get-YuriProviders | ForEach-Object { $_.VersionFiles }) -join ', '
            throw "no version given, and no version file ($files) in this folder or its parents. Usage: yuri use <tool>[@<version>]"
        }
        Write-Note "Found $($request.Source): $($request.Spec)"
    } else {
        $request = Read-ToolRequest $Argv[0]
    }
    $P = $request.Provider
    $version = Resolve-UseVersion $P (Get-SpecInfo $P $request.Spec)
    Install-ToolVersion $P $version
    Use-ToolVersion $P $version
}

function Invoke-InstallCommand([string[]]$Argv) {
    if ($Argv.Count -eq 0) {
        $request = Find-VersionFileRequest
        if (-not $request) { throw 'usage: yuri install <tool>[@<version>] ...' }
        Write-Note "Found $($request.Source): $($request.Spec)"
        $requests = @($request)
    } else {
        $requests = @($Argv | ForEach-Object { Read-ToolRequest $_ })
    }
    foreach ($request in $requests) {
        $P = $request.Provider
        $info = Get-SpecInfo $P $request.Spec
        if ($info.Kind -eq 'exact' -and (Test-Installed $P $info.Arg)) {
            $version = $info.Arg
        } else {
            $version = Resolve-RemoteVersion $P $info
        }
        if (Test-Installed $P $version) {
            Write-Host "$($P.Name) $version is already installed"
        } else {
            Install-ToolVersion $P $version
        }
        if (Get-ActiveVersion $P) {
            if ((Get-ActiveVersion $P) -ne $version) { Write-Note "To switch to it: yuri use $($P.Name)@$version" }
        } else {
            Use-ToolVersion $P $version
        }
    }
}

function Invoke-ListCommand([string[]]$Argv) {
    $providers = @(Get-ProviderArgs $Argv 'yuri list [<tool>]')
    $withHeader = $providers.Count -gt 1
    foreach ($P in $providers) {
        if ($withHeader) { Write-Output "$($P.Name):" }
        $versions = @(Get-InstalledVersions $P)
        if ($versions.Count -eq 0) {
            Write-Host "  no $($P.Name) versions installed. Try: yuri use $($P.Name)" -ForegroundColor DarkGray
            continue
        }
        $active = Get-ActiveVersion $P
        $meta = Get-CachedIndexMap $P
        foreach ($v in $versions) {
            $mark = ' '
            if ($v -eq $active) { $mark = '*' }
            $lts = ''
            if ($meta.ContainsKey($v) -and $meta[$v].Lts) { $lts = "($($meta[$v].Lts))" }
            Write-Output ('{0} {1,-10} {2}' -f $mark, $v, $lts).TrimEnd()
        }
    }
}

function Invoke-LsRemoteCommand([string[]]$Argv) {
    if ($Argv.Count -ne 1) { throw 'usage: yuri ls-remote <tool>[@<version>]' }
    $request = Read-ToolRequest $Argv[0]
    $P = $request.Provider
    if ($request.Explicit) {
        $info = Get-SpecInfo $P $request.Spec
        $entries = @(Find-Remote $P $info)
        if ($entries.Count -eq 0) { throw "no $($P.Name) version matches '$($info.Text)' for this system" }
    } else {
        $entries = @(Get-RemoteIndex $P)
    }
    $installed = @(Get-InstalledVersions $P)
    $active = Get-ActiveVersion $P
    # Oldest first, so the newest ends up right above the prompt.
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i]
        $mark = ' '
        $state = ''
        if ($e.Version -eq $active) { $mark = '*'; $state = 'active' }
        elseif ($installed -contains $e.Version) { $state = 'installed' }
        $lts = ''
        if ($e.Lts) { $lts = $e.Lts }
        Write-Output ('{0} {1,-10} {2,-11} {3,-10} {4}' -f $mark, $e.Version, $e.Date, $lts, $state).TrimEnd()
    }
}

function Invoke-CurrentCommand([string[]]$Argv) {
    foreach ($P in @(Get-ProviderArgs $Argv 'yuri current [<tool>]')) {
        $v = Get-ActiveVersion $P
        if (-not $v) { $v = 'none' }
        if ($Argv.Count -eq 0) { Write-Output "$($P.Name) $v" } else { Write-Output $v }
    }
}

function Invoke-WhichCommand([string[]]$Argv) {
    if ($Argv.Count -ne 1) { throw 'usage: yuri which <tool>[@<version>]' }
    $request = Read-ToolRequest $Argv[0]
    $P = $request.Provider
    if ($request.Explicit) {
        $info = Get-SpecInfo $P $request.Spec
        $found = @(Find-Installed $P $info)
        if ($found.Count -eq 0) { throw "no installed $($P.Name) version matches '$($info.Text)'" }
        $v = $found[0].Version
    } else {
        $v = Get-ActiveVersion $P
        if (-not $v) { throw "no active $($P.Name) version. Run 'yuri use $($P.Name)'." }
    }
    Write-Output (Join-Path (Get-BinDir $P (Get-InstallDir $P $v)) $P.Executable)
}

function Invoke-UninstallCommand([string[]]$Argv) {
    if ($Argv.Count -eq 0) { throw 'usage: yuri uninstall <tool>@<version> ...' }
    foreach ($arg in $Argv) {
        $request = Read-ToolRequest $arg
        $P = $request.Provider
        if (-not $request.Explicit) {
            throw "say which version to remove, for example: yuri uninstall $($P.Name)@20.11.0"
        }
        $info = Get-SpecInfo $P $request.Spec
        $found = @(Find-Installed $P $info)
        if ($found.Count -eq 0) { throw "$($P.Name) $($info.Text) is not installed" }
        if ($found.Count -gt 1) {
            throw "'$arg' matches several installed versions ($(@($found | ForEach-Object { $_.Version }) -join ', ')). Give the exact one."
        }
        $v = $found[0].Version
        Write-Host "Removing $($P.Name) $v"
        Uninstall-ToolVersion $P $v
        Write-Host "Removed $($P.Name) $v"
    }
}

# ---- doctor ------------------------------------------------------------

function New-Finding([string]$Level, [string]$Message) {
    [pscustomobject]@{ Level = $Level; Message = $Message }
}

function Write-Findings($Findings) {
    foreach ($f in @($Findings)) {
        switch ($f.Level) {
            'ok'   { Write-Host '  ok    ' -ForegroundColor Green -NoNewline }
            'warn' { Write-Host '  warn  ' -ForegroundColor Yellow -NoNewline; $script:DoctorWarnings++ }
            'fail' { Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline; $script:DoctorFailures++ }
            default { Write-Host '        ' -NoNewline }
        }
        Write-Host $f.Message
    }
}

function Get-SetupFindings {
    $cache = Get-YuriPath 'cache'
    try {
        New-Dir $cache
        $probe = Join-Path $cache ".write-test-$PID"
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        New-Finding ok "can write to $script:YuriHome"
    } catch {
        New-Finding fail "cannot write to $script:YuriHome. Run install.ps1 again to fix the permissions."
    }

    foreach ($tool in 'curl.exe', 'tar.exe') {
        if (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue) { New-Finding ok "$tool found" }
        else { New-Finding fail "$tool not found. It ships with Windows 10 1803 and later." }
    }

    $policy = Get-PolicyWithoutProcess
    if (Test-PolicyAllowsScripts $policy.Policy) {
        New-Finding ok "execution policy: $($policy.Policy)"
    } else {
        New-Finding warn "execution policy is $($policy.Policy), so 'yuri' and 'npm' fail in PowerShell. Fix: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
    }

    $machinePath = Get-RawPath Machine
    foreach ($dir in Get-YuriPathEntries) {
        if (Test-PathListHas $machinePath $dir) { New-Finding ok "machine PATH has $dir" }
        else { New-Finding fail "machine PATH is missing $dir. Run install.ps1." }
        if (-not (Test-PathListHas $env:PATH $dir)) {
            New-Finding warn "this terminal's PATH is missing $dir. Open a new terminal."
        }
    }

    $yuri = @(Get-Command yuri -ErrorAction SilentlyContinue)
    $bin = ConvertTo-NormalPath (Join-Path $script:YuriRoot 'bin')
    if ($yuri.Count -gt 0 -and (ConvertTo-NormalPath (Split-Path -Parent $yuri[0].Path)) -eq $bin) {
        New-Finding ok "'yuri' runs $($yuri[0].Path)"
    } elseif ($yuri.Count -gt 0) {
        New-Finding warn "'yuri' runs $($yuri[0].Path), not the copy in $script:YuriRoot\bin"
    }
}

function Get-ProviderFindings($P) {
    $installed = @(Get-InstalledVersions $P)
    $link = Get-CurrentLink $P
    $target = Get-LinkTarget $link
    $active = Get-ActiveVersion $P
    if ($active) {
        New-Finding ok "active version: $active ($($installed.Count) installed)"
    } elseif ($target) {
        New-Finding fail "$link points to a missing folder ($target). Fix: yuri use $($P.Name)@<version>"
    } else {
        New-Finding warn "no active version ($($installed.Count) installed). Run: yuri use $($P.Name)"
    }

    $binDir = ConvertTo-NormalPath (Get-BinDir $P $link)
    $seen = @{}
    $found = @(Get-Command $P.Executable -CommandType Application -All -ErrorAction SilentlyContinue |
            Where-Object { $key = ConvertTo-NormalPath $_.Path; if ($seen.ContainsKey($key)) { $false } else { $seen[$key] = 1; $true } })
    for ($i = 0; $i -lt $found.Count; $i++) {
        $path = $found[$i].Path
        $ours = (ConvertTo-NormalPath (Split-Path -Parent $path)) -eq $binDir
        if ($i -eq 0 -and $ours) {
            New-Finding ok "'$($P.Executable)' resolves to yuri's version"
        } elseif ($i -eq 0) {
            $level = 'warn'
            if ($active) { $level = 'fail' }
            New-Finding $level "'$($P.Executable)' resolves to $path, outside yuri. Uninstall that copy or move its folder after $(Get-BinDir $P $link) in PATH."
        } elseif (-not $ours) {
            New-Finding warn "another $($P.Executable) is in PATH: $path"
        }
    }

    $root = Get-ToolInstallRoot $P
    if (Test-Path -LiteralPath $root) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name.StartsWith('.') })) {
            New-Finding warn "leftover folder from an interrupted install or uninstall: $($d.FullName). Delete it with: rmdir /s /q `"$($d.FullName)`""
        }
    }
}

function Invoke-DoctorCommand([string[]]$Argv) {
    if ($Argv.Count -gt 0) { throw 'usage: yuri doctor' }
    $script:DoctorFailures = 0
    $script:DoctorWarnings = 0
    Write-Host "yuri $script:YuriVersion"
    Write-Host "  home: $script:YuriHome"
    Write-Host ''
    Write-Host 'setup'
    Write-Findings @(Get-SetupFindings)
    foreach ($P in Get-YuriProviders) {
        Write-Host ''
        Write-Host $P.Name
        Write-Findings @(Get-ProviderFindings $P)
        if ($P.Doctor) { Write-Findings @(& $P.Doctor $P) }
    }
    Write-Host ''
    if ($script:DoctorFailures -gt 0) {
        Write-Host "$($script:DoctorFailures) problem(s), $($script:DoctorWarnings) warning(s)" -ForegroundColor Red
        $script:YuriExitCode = 1
    } elseif ($script:DoctorWarnings -gt 0) {
        Write-Host "No problems, $($script:DoctorWarnings) warning(s)" -ForegroundColor Yellow
    } else {
        Write-Host 'No problems found' -ForegroundColor Green
    }
}

# ---- help --------------------------------------------------------------

function Show-YuriHelp {
    $tools = @($script:YuriProviders.Keys) -join ', '
    $files = @(Get-YuriProviders | ForEach-Object { $_.VersionFiles }) -join ' or '
    Write-Output @"
yuri $script:YuriVersion - version manager for Windows

Usage:
  yuri use [<tool>[@<version>]]       Switch to a version, installing it if needed
  yuri install [<tool>[@<version>]]   Install the newest published match
  yuri list [<tool>]                  List installed versions (* = active)
  yuri ls-remote <tool>[@<version>]   List versions available for download
  yuri current [<tool>]               Show the active version
  yuri which <tool>[@<version>]       Show the full path of the executable
  yuri uninstall <tool>@<version>     Remove an installed version
  yuri doctor                         Check the setup for problems
  yuri help                           Show this help

Versions:
  22.23.2    exact version
  22.23, 22  use: newest installed match, otherwise newest published match
  latest     newest published version
  lts        newest published LTS version (node)
  lts/jod    newest version of an LTS line (node)

  'yuri use node' with no version means node@lts.
  'yuri use' with no arguments reads $files
  from the current folder or its parents.

The switch is global: every terminal sees the new version right away.

Tools: $tools
Home:  $script:YuriHome
"@
}
