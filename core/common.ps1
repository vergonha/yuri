# Shared helpers: provider registry, paths, output, files, downloads.

$script:YuriVersion = '0.1.0'
$script:YuriProviders = [ordered]@{}

# Provider contract.
#   Required: Name, Executable, ListRemote, GetArtifact (returns Url, FileName
#             and Sha256 or Sha512)
#   Optional: BinSubdir, DefaultSpec, VersionFiles, SpecExamples,
#             ResolveNamed, PostInstall, Doctor
function Register-YuriProvider {
    param([Parameter(Mandatory = $true)][hashtable]$Provider)
    foreach ($key in 'Name', 'Executable', 'ListRemote', 'GetArtifact') {
        if (-not $Provider.ContainsKey($key)) { throw "provider is missing the required field '$key'" }
    }
    $defaults = @{
        BinSubdir    = ''
        DefaultSpec  = 'latest'
        VersionFiles = @()
        SpecExamples = '1.2.3, 1.2, 1 or latest'
        ResolveNamed = $null
        PostInstall  = $null
        Doctor       = $null
    }
    foreach ($key in $defaults.Keys) {
        if (-not $Provider.ContainsKey($key)) { $Provider[$key] = $defaults[$key] }
    }
    $script:YuriProviders[$Provider.Name] = $Provider
}

function Get-YuriProviders { @($script:YuriProviders.Values) }

function Get-YuriProvider([string]$Name) {
    $key = $Name.ToLowerInvariant()
    if (-not $script:YuriProviders.Contains($key)) {
        throw "unknown tool '$Name'. Available: $(@($script:YuriProviders.Keys) -join ', ')"
    }
    $script:YuriProviders[$key]
}

# ---- paths -------------------------------------------------------------

function Get-YuriPath {
    param([string[]]$Parts)
    $path = $script:YuriHome
    foreach ($part in $Parts) { $path = Join-Path $path $part }
    $path
}

function Get-ToolInstallRoot($P) { Get-YuriPath 'installs', $P.Name }
function Get-InstallDir($P, [string]$Version) { Join-Path (Get-ToolInstallRoot $P) $Version }
function Get-CurrentLink($P) { Get-YuriPath 'current', $P.Name }

function Get-BinDir($P, [string]$Dir) {
    if ($P.BinSubdir) { Join-Path $Dir $P.BinSubdir } else { $Dir }
}

# Folders that must be in PATH: bin plus one "current" folder per provider.
function Get-YuriPathEntries {
    @(Join-Path $script:YuriRoot 'bin')
    foreach ($P in Get-YuriProviders) { Get-BinDir $P (Get-CurrentLink $P) }
}

# ---- output ------------------------------------------------------------

function Write-Note([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "warning: $Message" -ForegroundColor Yellow }

# Runs a native program and returns its exit code. Its stdout is discarded;
# stderr (curl's progress bar) goes to the console. When the caller redirects
# streams, PowerShell 5.1 wraps stderr lines in errors, so 'Stop' is relaxed here.
function Invoke-Exe([string]$FilePath, [string[]]$ArgumentList) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $FilePath @ArgumentList
        $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
}

# ---- files -------------------------------------------------------------

function New-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

# Remove-Item -Recurse in PowerShell 5.1 follows junctions and deletes
# their targets. cmd's rmdir /s does not, so it is the only one used here.
function Remove-DirectorySafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $null = Invoke-Exe 'cmd.exe' @('/d', '/c', 'rmdir', '/s', '/q', $Path)
    if (Test-Path -LiteralPath $Path) {
        throw "could not fully delete $Path. Close programs that use it and try again."
    }
}

# ---- downloads ---------------------------------------------------------

# curl.exe ships with Windows and is much faster than Invoke-WebRequest,
# whose progress bar slows downloads down a lot in PowerShell 5.1.
function Save-Url {
    param([string]$Url, [string]$OutFile, [switch]$Progress)
    if (-not (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'curl.exe not found. It ships with Windows 10 1803 and later.'
    }
    New-Dir (Split-Path -Parent $OutFile)
    $part = "$OutFile.part"
    $curlArgs = @('-fL', '--retry', '3', '--connect-timeout', '30', '-o', $part)
    if ($Progress) { $curlArgs += '-#' } else { $curlArgs += '-sS' }
    $code = Invoke-Exe 'curl.exe' ($curlArgs + $Url)
    if ($code -ne 0) {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        throw "download failed: $Url (curl exit code $code)"
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
}
