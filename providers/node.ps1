# Node.js provider. Everything specific to Node lives in this file.

$script:NodeDistUrl = 'https://nodejs.org/dist'

function Get-NodeArch {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'ARM64' { return 'arm64' }
        'x86' { return 'x86' }
        default { return 'x64' }
    }
}

# The "prefix" line of npm's builtin config (node_modules\npm\npmrc), or $null.
function Get-NodeNpmPrefix([string]$Dir) {
    $rc = Join-Path $Dir 'node_modules\npm\npmrc'
    if (-not (Test-Path -LiteralPath $rc)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($rc)) {
        if ($line -match '^\s*prefix\s*=\s*(.*?)\s*$') { return $Matches[1] }
    }
    $null
}

Register-YuriProvider @{
    Name         = 'node'
    Executable   = 'node.exe'
    BinSubdir    = ''
    DefaultSpec  = 'lts'
    VersionFiles = @('.node-version', '.nvmrc')
    SpecExamples = '22.23.2, 22.23, 22, latest, lts or lts/jod'

    # https://nodejs.org/dist/index.json lists every release and its files.
    ListRemote   = {
        $file = Get-YuriPath 'cache', 'node-index.json'
        Save-Url "$script:NodeDistUrl/index.json" $file
        try {
            $index = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        $key = 'win-{0}-zip' -f (Get-NodeArch)
        foreach ($e in $index) {
            if ($e.files -notcontains $key) { continue }
            $lts = ''
            if ($e.lts) { $lts = [string]$e.lts }
            [pscustomobject]@{ Version = $e.version.TrimStart('v'); Lts = $lts; Date = [string]$e.date }
        }
    }

    # The official zip, checked against SHASUMS256.txt from the same folder.
    GetArtifact  = {
        param([string]$Version)
        $name = 'node-v{0}-win-{1}.zip' -f $Version, (Get-NodeArch)
        $base = "$script:NodeDistUrl/v$Version"
        $sums = Get-YuriPath 'cache', 'downloads', "node-v$Version-SHASUMS256.txt"
        Save-Url "$base/SHASUMS256.txt" $sums
        try {
            $lines = [IO.File]::ReadAllLines($sums)
        } finally {
            Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue
        }
        $hash = $null
        foreach ($line in $lines) {
            $parts = @($line.Trim() -split '\s+')
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $name) { $hash = $parts[0]; break }
        }
        if (-not $hash) { throw "no checksum for $name in $base/SHASUMS256.txt" }
        @{ Url = "$base/$name"; FileName = $name; Sha256 = $hash }
    }

    ResolveNamed = {
        param([string]$Spec)
        if ($Spec -in 'lts', 'lts/*') {
            return @{ Kind = 'moving'; Filter = { param($e, $a) [bool]$e.Lts }; Arg = $null }
        }
        if ($Spec -eq 'node') {   # what nvm writes in .nvmrc for "newest"
            return @{ Kind = 'moving'; Filter = { param($e, $a) $true }; Arg = $null }
        }
        if ($Spec -match '^lts/([a-z]+)$') {
            return @{ Kind = 'range'; Filter = { param($e, $a) $e.Lts -eq $a }; Arg = $Matches[1] }
        }
        $null
    }

    # Global packages (npm i -g) go into the version folder, which is
    # already in PATH through the junction, and stay separate per version.
    PostInstall  = {
        param([string]$Dir, [string]$Version)
        $npmDir = Join-Path $Dir 'node_modules\npm'
        if (-not (Test-Path -LiteralPath $npmDir)) { return }
        if ((Get-NodeNpmPrefix $Dir) -eq $Dir) { return }
        $rc = Join-Path $npmDir 'npmrc'
        $lines = @()
        if (Test-Path -LiteralPath $rc) {
            $lines = @([IO.File]::ReadAllLines($rc) | Where-Object { $_ -notmatch '^\s*prefix\s*=' })
        }
        $lines += "prefix=$Dir"
        [IO.File]::WriteAllLines($rc, [string[]]$lines)
    }

    Doctor       = {
        param($P)
        foreach ($v in @(Get-InstalledVersions $P)) {
            $dir = Get-InstallDir $P $v
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'node_modules\npm'))) {
                New-Finding warn "node ${v}: npm is missing from $dir"
                continue
            }
            $prefix = Get-NodeNpmPrefix $dir
            if ($prefix -and (ConvertTo-NormalPath $prefix) -eq (ConvertTo-NormalPath $dir)) {
                New-Finding ok "node ${v}: global npm packages go to its own folder"
            } else {
                New-Finding warn "node ${v}: npm's prefix setting is missing (an npm self-update removes it). Fix: yuri use node@$v"
            }
        }

        $oldGlobals = Join-Path $env:APPDATA 'npm'
        if (Test-Path -LiteralPath $oldGlobals) {
            New-Finding warn "$oldGlobals exists. It holds global packages from a Node installed without yuri; delete it if you no longer use that Node."
        }
        if (Test-PathListHas (Get-RawPath User) $oldGlobals) {
            New-Finding warn "your user PATH contains $oldGlobals. Commands left there can conflict with yuri's; remove that entry."
        }
        $userRc = Join-Path $env:USERPROFILE '.npmrc'
        if ((Test-Path -LiteralPath $userRc) -and @(Get-Content -LiteralPath $userRc | Where-Object { $_ -match '^\s*prefix\s*=' }).Count -gt 0) {
            New-Finding warn "$userRc sets 'prefix', which overrides yuri's per-version setting. Remove that line."
        }
        if ($env:NPM_CONFIG_PREFIX) {
            New-Finding warn "NPM_CONFIG_PREFIX is set ($env:NPM_CONFIG_PREFIX), which overrides yuri's per-version setting."
        }
    }
}
