# Installed versions, the "current" junctions, and installing from an archive.

function Sort-VersionsDesc([string[]]$Versions) {
    @($Versions | Sort-Object -Property { [version]$_ } -Descending)
}

function Test-Installed($P, [string]$Version) {
    $exe = Join-Path (Get-BinDir $P (Get-InstallDir $P $Version)) $P.Executable
    Test-Path -LiteralPath $exe -PathType Leaf
}

# Version folders, newest first. Folders starting with "." are leftovers.
function Get-InstalledVersions($P) {
    $root = Get-ToolInstallRoot $P
    if (-not (Test-Path -LiteralPath $root)) { return }
    $names = @(Get-ChildItem -LiteralPath $root -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and (Test-Installed $P $_.Name) } |
            ForEach-Object { $_.Name })
    Sort-VersionsDesc $names
}

# ---- junctions ---------------------------------------------------------

# Attributes of the path itself, without following a junction. $null if missing.
function Get-LinkAttributes([string]$Path) {
    try { [IO.File]::GetAttributes($Path) } catch { $null }
}

function Test-IsLink([string]$Path) {
    $attr = Get-LinkAttributes $Path
    ($null -ne $attr) -and (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-LinkTarget([string]$Path) {
    if (-not (Test-IsLink $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    $target = @($item.Target)[0]
    if ($target) { $target = $target -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', '' }
    $target
}

# Removes a junction, never what it points to.
function Remove-Link([string]$Path) {
    $attr = Get-LinkAttributes $Path
    if ($null -eq $attr) { return }
    if (($attr -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "$Path is a real folder, not a link. Move it somewhere else and try again."
    }
    [IO.Directory]::Delete($Path)
}

function Get-ActiveVersion($P) {
    $target = Get-LinkTarget (Get-CurrentLink $P)
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { return $null }
    Split-Path -Leaf $target
}

function Set-ActiveVersion($P, [string]$Version) {
    $link = Get-CurrentLink $P
    New-Dir (Split-Path -Parent $link)
    Remove-Link $link
    $null = New-Item -ItemType Junction -Path $link -Value (Get-InstallDir $P $Version)
}

# ---- install / uninstall ----------------------------------------------

function New-TempName([string]$Prefix) {
    $Prefix + [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Install-ToolVersion($P, [string]$Version) {
    if (Test-Installed $P $Version) { return }
    $root = Get-ToolInstallRoot $P
    $dest = Get-InstallDir $P $Version
    New-Dir $root
    if (Test-Path -LiteralPath $dest) { Remove-DirectorySafe $dest }   # broken leftover
    $downloads = Get-YuriPath 'cache', 'downloads'
    New-Dir $downloads

    Write-Host "Installing $($P.Name) $Version"
    $artifact = & $P.GetArtifact $Version
    $archive = Join-Path $downloads $artifact.FileName
    $staging = Join-Path $root (New-TempName '.staging-')
    $done = $false
    $moved = $false   # only delete $dest if this process created it
    try {
        Write-Note "  $($artifact.Url)"
        Save-Url $artifact.Url $archive -Progress
        $algo = 'SHA256'
        $expected = $artifact.Sha256
        if ($artifact.Sha512) { $algo = 'SHA512'; $expected = $artifact.Sha512 }
        if ($expected) {
            $actual = (Get-FileHash -LiteralPath $archive -Algorithm $algo).Hash
            if ($actual -ne $expected) {
                throw "checksum mismatch for $($artifact.FileName): expected $expected, got $actual. The download was discarded."
            }
            Write-Note "  $algo checksum ok"
        } else {
            Write-Warn "no checksum available for $($artifact.FileName); it was not verified"
        }

        Write-Note '  extracting...'
        New-Dir $staging
        $code = Invoke-Exe 'tar.exe' @('-xf', $archive, '-C', $staging)
        if ($code -ne 0) { throw "could not extract $($artifact.FileName) (tar exit code $code)" }

        # Most archives wrap everything in one top folder; use what is inside it.
        $items = @(Get-ChildItem -LiteralPath $staging -Force)
        $source = $staging
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $source = $items[0].FullName }
        [IO.Directory]::Move($source, $dest)
        $moved = $true

        if (-not (Test-Installed $P $Version)) {
            throw "the archive does not contain $($P.Executable) where expected"
        }
        if ($P.PostInstall) { $null = & $P.PostInstall $dest $Version }
        $done = $true
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        Remove-DirectorySafe $staging
        if ($moved -and -not $done) { Remove-DirectorySafe $dest }
    }
    Write-Host "Installed $($P.Name) $Version"
}

# First program file (exe, dll, native addon) that a running process holds
# open, or $null. Does not walk into junctions (npm link creates them).
function Find-LockedFile([string]$Dir) {
    $pending = New-Object System.Collections.Stack
    $pending.Push($Dir)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($sub in [IO.Directory]::GetDirectories($current)) {
            if (-not (Test-IsLink $sub)) { $pending.Push($sub) }
        }
        foreach ($file in [IO.Directory]::GetFiles($current)) {
            if ([IO.Path]::GetExtension($file) -notin '.exe', '.dll', '.node') { continue }
            if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReadOnly) -ne 0) { continue }
            try {
                [IO.File]::Open($file, 'Open', 'ReadWrite', 'None').Close()
            } catch {
                return $file
            }
        }
    }
    $null
}

function Uninstall-ToolVersion($P, [string]$Version) {
    $dir = Get-InstallDir $P $Version
    $locked = Find-LockedFile $dir
    if ($locked) {
        throw "cannot remove $($P.Name) ${Version}: $locked is in use. Close programs running from it and try again."
    }
    # Renaming first also fails cleanly if a terminal is open inside the folder.
    $trash = Join-Path (Get-ToolInstallRoot $P) (New-TempName ".removing-$Version-")
    try {
        [IO.Directory]::Move($dir, $trash)
    } catch {
        throw "cannot remove $($P.Name) ${Version}: some of its files are in use. Close programs running from it and try again."
    }
    $target = Get-LinkTarget (Get-CurrentLink $P)
    if ($target -and (Split-Path -Leaf $target) -eq $Version) {
        Remove-Link (Get-CurrentLink $P)
        Write-Warn "$($P.Name) $Version was the active version. No $($P.Name) version is active now; run 'yuri use $($P.Name)@<version>'."
    }
    Remove-DirectorySafe $trash
}
