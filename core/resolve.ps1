# Version specs, the remote version index (cached), and resolution rules.
#
# Spec kinds:
#   exact   22.23.2           that version
#   range   22, 22.23, lts/x  'use' prefers the newest installed match,
#                             otherwise the newest published match
#   moving  latest, lts       always the newest published match

$script:IndexMaxAgeMinutes = 60
$script:IndexFromCache = $false

$script:FilterExact = { param($e, $a) $e.Version -eq $a }
$script:FilterPrefix = { param($e, $a) $e.Version.StartsWith($a) }
$script:FilterAll = { param($e, $a) $true }

# Splits "node@22" into provider and spec. Without "@", the provider's default spec is used.
function Read-ToolRequest([string]$Text) {
    $t = $Text.Trim()
    $at = $t.IndexOf('@')
    if ($at -ge 0) { $name = $t.Substring(0, $at); $spec = $t.Substring($at + 1) }
    else { $name = $t; $spec = '' }

    if ($t -match '^(v?\d|lts|latest)') {
        $names = @($script:YuriProviders.Keys)
        $hint = ''
        if ($names.Count -eq 1) { $hint = " Did you mean '$($names[0])@$t'?" }
        throw "missing tool name in '$t'.$hint"
    }
    $P = Get-YuriProvider $name
    if ($at -ge 0 -and -not $spec) { throw "missing version after '@' in '$t'" }

    $explicit = [bool]$spec
    if (-not $spec) { $spec = $P.DefaultSpec }
    @{ Provider = $P; Spec = $spec; Explicit = $explicit; Source = '' }
}

# Looks for a version file (.node-version, .nvmrc, ...) here and in parent folders.
function Find-VersionFileRequest {
    $dir = (Get-Location).ProviderPath
    while ($dir) {
        foreach ($P in Get-YuriProviders) {
            foreach ($fileName in $P.VersionFiles) {
                $file = Join-Path $dir $fileName
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
                $spec = Get-Content -LiteralPath $file |
                    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
                    Where-Object { $_ } | Select-Object -First 1
                if (-not $spec) { throw "$file is empty" }
                return @{ Provider = $P; Spec = $spec; Explicit = $true; Source = $file }
            }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $null
}

function Get-SpecInfo($P, [string]$Spec) {
    $s = $Spec.Trim().ToLowerInvariant()
    if ($s -match '^v\d') { $s = $s.Substring(1) }
    $info = $null
    if ($s -match '^\d+\.\d+\.\d+$') {
        $info = @{ Kind = 'exact'; Filter = $script:FilterExact; Arg = $s; NeedsIndex = $false }
    } elseif ($s -match '^\d+(\.\d+)?$') {
        $info = @{ Kind = 'range'; Filter = $script:FilterPrefix; Arg = "$s."; NeedsIndex = $false }
    } elseif ($s -eq 'latest') {
        $info = @{ Kind = 'moving'; Filter = $script:FilterAll; Arg = $null; NeedsIndex = $true }
    } elseif ($P.ResolveNamed) {
        $info = & $P.ResolveNamed $s
        if ($info -and -not $info.ContainsKey('NeedsIndex')) { $info.NeedsIndex = $true }
    }
    if (-not $info) {
        throw "invalid version '$Spec' for $($P.Name). Use something like $($P.SpecExamples)."
    }
    $info.Text = $s
    $info
}

function Select-Matching($Entries, $Info) {
    @($Entries | Where-Object { & $Info.Filter $_ $Info.Arg })
}

# ---- remote index ------------------------------------------------------

function Get-IndexFile($P) { Get-YuriPath 'cache', "$($P.Name)-versions.tsv" }

function Read-IndexFile([string]$File) {
    foreach ($line in [IO.File]::ReadAllLines($File)) {
        if (-not $line) { continue }
        $f = $line.Split("`t")
        [pscustomobject]@{ Version = $f[0]; Lts = $f[1]; Date = $f[2] }
    }
}

# Published versions for this system, newest first. Cached for an hour;
# a stale copy is used when the network is down.
function Get-RemoteIndex {
    param($P, [switch]$Refresh, [switch]$AllowStale)
    $file = Get-IndexFile $P
    $exists = Test-Path -LiteralPath $file
    if ($exists -and -not $Refresh) {
        $age = (Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime
        if ($AllowStale -or $age.TotalMinutes -lt $script:IndexMaxAgeMinutes) {
            $script:IndexFromCache = $true
            return @(Read-IndexFile $file)
        }
    }

    Write-Note "Fetching the $($P.Name) version index..."
    try {
        $entries = @(& $P.ListRemote)
        if ($entries.Count -eq 0) { throw 'the index is empty' }
    } catch {
        if ($exists) {
            Write-Warn "could not refresh the $($P.Name) version index ($($_.Exception.Message)); using the cached copy"
            $script:IndexFromCache = $true
            return @(Read-IndexFile $file)
        }
        throw "could not get the $($P.Name) version index: $($_.Exception.Message)"
    }

    $entries = @($entries | Sort-Object -Property { [version]$_.Version } -Descending)
    $lines = foreach ($e in $entries) { "$($e.Version)`t$($e.Lts)`t$($e.Date)" }
    New-Dir (Split-Path -Parent $file)
    [IO.File]::WriteAllLines($file, [string[]]$lines)
    $script:IndexFromCache = $false
    $entries
}

# Version -> index entry, from the cache only (never goes to the network).
function Get-CachedIndexMap($P) {
    $map = @{}
    $file = Get-IndexFile $P
    if (Test-Path -LiteralPath $file) {
        foreach ($e in Read-IndexFile $file) { $map[$e.Version] = $e }
    }
    $map
}

# Published matches, newest first. A cached index that has no match is
# refreshed once, in case the version was released in the last hour.
function Find-Remote($P, $Info) {
    $found = Select-Matching @(Get-RemoteIndex $P) $Info
    if ($found.Count -eq 0 -and $script:IndexFromCache) {
        $found = Select-Matching @(Get-RemoteIndex $P -Refresh) $Info
    }
    $found
}

# Installed matches, newest first.
function Find-Installed($P, $Info) {
    $versions = @(Get-InstalledVersions $P)
    if ($versions.Count -eq 0) { return }
    $meta = @{}
    if ($Info.NeedsIndex) {
        foreach ($e in @(Get-RemoteIndex $P -AllowStale)) { $meta[$e.Version] = $e }
    }
    $entries = foreach ($v in $versions) {
        if ($meta.ContainsKey($v)) { $meta[$v] }
        else { [pscustomobject]@{ Version = $v; Lts = ''; Date = '' } }
    }
    Select-Matching @($entries) $Info
}

function Resolve-RemoteVersion($P, $Info) {
    $found = @(Find-Remote $P $Info)
    if ($found.Count -eq 0) {
        throw "no $($P.Name) version matches '$($Info.Text)' for this system. See 'yuri ls-remote $($P.Name)'."
    }
    $found[0].Version
}

# For 'use': installed beats published, except for moving specs (latest, lts).
function Resolve-UseVersion($P, $Info) {
    if ($Info.Kind -eq 'exact') {
        if (Test-Installed $P $Info.Arg) { return $Info.Arg }
    } elseif ($Info.Kind -eq 'range') {
        $found = @(Find-Installed $P $Info)
        if ($found.Count -gt 0) { return $found[0].Version }
    }
    Resolve-RemoteVersion $P $Info
}
