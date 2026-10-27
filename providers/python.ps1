# Python provider. Everything specific to Python lives in this file.
#
# Uses the python.org NuGet packages (a full install with pip and venv; the
# embeddable zip has neither). Their zip layout is tools\python.exe.

$script:PythonNuGetFlat = 'https://api.nuget.org/v3-flatcontainer'

# NuGet package id per CPU: python (x64), pythonx86, pythonarm64.
function Get-PythonPackageId {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'ARM64' { return 'pythonarm64' }
        'x86' { return 'pythonx86' }
        default { return 'python' }
    }
}

Register-YuriProvider @{
    Name         = 'python'
    Executable   = 'python.exe'
    BinSubdir    = 'tools'
    DefaultSpec  = 'latest'
    VersionFiles = @('.python-version')
    SpecExamples = '3.12.3, 3.12, 3 or latest'

    # Stable releases only (3.12.3); NuGet also lists 3.13.0-rc1 and 3.5.2.1.
    ListRemote   = {
        $id = Get-PythonPackageId
        $file = Get-YuriPath 'cache', 'python-index.json'
        Save-Url "$script:PythonNuGetFlat/$id/index.json" $file
        try {
            $index = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        foreach ($v in $index.versions) {
            if ($v -match '^\d+\.\d+\.\d+$') { [pscustomobject]@{ Version = $v; Lts = ''; Date = '' } }
        }
    }

    # The package checked against the SHA512 that nuget.org publishes for it.
    GetArtifact  = {
        param([string]$Version)
        $id = Get-PythonPackageId
        $meta = Get-YuriPath 'cache', 'downloads', "python-$Version-meta.xml"
        Save-Url "https://www.nuget.org/api/v2/Packages(Id='$id',Version='$Version')" $meta
        try {
            $xml = [IO.File]::ReadAllText($meta)
        } finally {
            Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
        }
        if ($xml -notmatch '<d:PackageHash>([^<]+)</d:PackageHash>' -or
            $xml -notmatch '<d:PackageHashAlgorithm>SHA512</d:PackageHashAlgorithm>') {
            throw "no SHA512 checksum for $id $Version on nuget.org"
        }
        $null = $xml -match '<d:PackageHash>([^<]+)</d:PackageHash>'
        $hex = [BitConverter]::ToString([Convert]::FromBase64String($Matches[1])).Replace('-', '')
        @{
            Url      = "$script:PythonNuGetFlat/$id/$Version/$id.$Version.nupkg"
            FileName = "$id.$Version.nupkg"
            Sha512   = $hex
        }
    }
}
