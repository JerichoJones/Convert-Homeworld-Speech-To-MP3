<#
.SYNOPSIS
Extracts Homeworld Remastered speech audio from an encrypted .big archive and converts all FDA files to MP3.

.DESCRIPTION
This PowerShell 7 script automates the full Windows workflow:

1. Downloads or reuses bigDecrypter.
2. Downloads the legacy Relic audio tools package and uses decShell.exe directly to convert Homeworld Remastered FDA files to WAV.
3. Downloads FFmpeg and converts the WAV files to MP3.
4. Finds Archive.exe from the Homeworld Remastered Toolkit, and if missing attempts to trigger the Steam install.
5. Produces a manifest CSV mapping original extracted paths to staged/output filenames.

The script is designed around EnglishSpeech.big, but it can be used with any compatible Homeworld Remastered .big file.

.PARAMETER BigFilePath
Path to the encrypted .big file, such as EnglishSpeech.big.

.PARAMETER WorkingDirectory
Root working folder used for tools, staging, extraction, and logs. Defaults to a short path at <SystemDrive>\HW_Speech_Work.

.PARAMETER OutputDirectory
Final MP3 output folder. Defaults to <WorkingDirectory>\mp3.

.PARAMETER ToolsDirectory
Folder used to cache downloaded tools. Defaults to <WorkingDirectory>\_tools.

.PARAMETER ArchiveExePath
Explicit path to Archive.exe from the Homeworld Remastered Toolkit. When provided, this exact path is used instead of auto-discovery.

.PARAMETER Mp3BitrateKbps
Target MP3 bitrate. Default is 96 kbps.

.PARAMETER Fda2AifcZipUrl
Download URL for the legacy Relic audio tools package that contains decShell.exe.

.PARAMETER KeepIntermediate
Keeps staged FDA/WAV files, extracted content, and decrypted BIG intermediates.

.PARAMETER ForceRedownload
Forces tool re-download and re-runs BIG decryption.

.PARAMETER ForceRestage
Forces the FDA staging step to rebuild the flat working set.

.PARAMETER SkipToolkitInstallAttempt
Do not try to trigger Steam installation of the Homeworld Remastered Toolkit when Archive.exe is missing.

.PARAMETER SkipMp3
Stops after WAV generation and skips the FFmpeg/MP3 conversion step.

.EXAMPLE
.\Convert-HomeworldSpeechToMp3.ps1 -BigFilePath 'D:\Steam\steamapps\common\Homeworld\HomeworldRM\Data\EnglishSpeech.big' -WorkingDirectory 'T:\WorkingDir'

.EXAMPLE
.\Convert-HomeworldSpeechToMp3.ps1 -BigFilePath 'D:\Steam\steamapps\common\Homeworld\HomeworldRM\Data\EnglishSpeech.big' -WorkingDirectory 'T:\WorkingDir' -OutputDirectory 'T:\WorkingDir\mp3' -Mp3BitrateKbps 80

.EXAMPLE
.\Convert-HomeworldSpeechToMp3.ps1 -BigFilePath 'D:\SteamLibrary\steamapps\common\Homeworld\HomeworldRM\Data\EnglishSpeech.big' -WorkingDirectory 'C:\WorkingDir' -ArchiveExePath 'D:\SteamLibrary\steamapps\common\Homeworld 347380\GBXTools\WorkshopTool\Archive.exe'

.NOTES
Author: Jericho Jones
Version: 1.0.14
Requires Windows + PowerShell 7.
Original location of fda2aifc: http://dow.finaldeath.co.uk/files/fda2aifc.zip
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BigFilePath,

    [string]$WorkingDirectory = (Join-Path $env:SystemDrive 'HW_Speech_Work'),

    [string]$OutputDirectory,

    [string]$ToolsDirectory,

    [string]$ArchiveExePath,

    [ValidateRange(32,320)]
    [int]$Mp3BitrateKbps = 96,

    [string]$Fda2AifcZipUrl = 'https://github.com/JerichoJones/Convert-Homeworld-Speech-To-MP3/releases/download/fda2aifc_Tool/fda2aifc.zip',

    [switch]$KeepIntermediate,
    [switch]$ForceRedownload,
    [switch]$ForceRestage,
    [switch]$SkipToolkitInstallAttempt,
    [switch]$SkipMp3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StageManifestNameStrategyVersion = '2'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO ] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Write-Okay {
    param([string]$Message)
    Write-Host "[ OK  ] $Message" -ForegroundColor Green
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Yellow
}

function Assert-PowerShell7 {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "This script requires PowerShell 7 or newer. Current version: $($PSVersionTable.PSVersion)"
    }
}

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-FileHashString {
    param(
        [Parameter(Mandatory)][string]$InputString,
        [string]$Algorithm = 'SHA1'
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try {
        return ([System.BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $hasher) {
            $hasher.Dispose()
        }
    }
}

function Invoke-Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$DestinationPath,
        [hashtable]$Headers
    )

    Write-Info "Downloading: $Uri"
    $parent = Split-Path -Path $DestinationPath -Parent
    if ($parent) {
        New-Directory -Path $parent | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $invokeParams = @{
        Uri                = $Uri
        OutFile            = $DestinationPath
        MaximumRedirection = 10
    }
    if ($Headers) {
        $invokeParams['Headers'] = $Headers
    }
    Invoke-WebRequest @invokeParams
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        throw "Download failed: $Uri"
    }
    return (Resolve-Path -LiteralPath $DestinationPath).Path
}

function Expand-ZipFile {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Path $DestinationPath -Force
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestinationPath -Force
    return (Resolve-Path -LiteralPath $DestinationPath).Path
}

function Get-FirstFileMatch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    foreach ($pattern in $Patterns) {
        $match = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } |
            Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

function Get-GitHubLatestReleaseAssetUrl {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$AssetRegex
    )

    $headers = @{
        'User-Agent' = 'PowerShell/HomeworldSpeechConverter'
        'Accept'     = 'application/vnd.github+json'
    }

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $asset = $release.assets |
        Where-Object { $_.browser_download_url -match $AssetRegex -or $_.name -match $AssetRegex } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a GitHub release asset for $Repository matching regex: $AssetRegex"
    }

    return [string]$asset.browser_download_url
}

function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $candidateRegistryPaths = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($regPath in $candidateRegistryPaths) {
        try {
            $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
            foreach ($propertyName in @('SteamPath', 'InstallPath')) {
                if ($item.PSObject.Properties.Name -contains $propertyName) {
                    $value = [string]$item.$propertyName
                    if ($value) {
                        $normalized = $value.Replace('/', '\').Trim('"')
                        if (-not $roots.Contains($normalized)) {
                            $roots.Add($normalized)
                        }
                    }
                }
            }
        }
        catch {
        }
    }

    $defaultPaths = New-Object System.Collections.Generic.List[string]
    if (${env:ProgramFiles(x86)}) {
        $defaultPaths.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) | Out-Null
    }
    if ($env:ProgramFiles) {
        $defaultPaths.Add((Join-Path $env:ProgramFiles 'Steam')) | Out-Null
    }

    foreach ($defaultPath in $defaultPaths) {
        if ($defaultPath -and (Test-Path -LiteralPath $defaultPath -PathType Container) -and -not $roots.Contains($defaultPath)) {
            $roots.Add($defaultPath)
        }
    }

    $expandedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        if (-not $expandedRoots.Contains($root)) {
            $expandedRoots.Add($root)
        }

        $libraryVdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryVdf -PathType Leaf) {
            $content = Get-Content -LiteralPath $libraryVdf -Raw
            $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
            foreach ($match in $matches) {
                $libraryPath = $match.Groups[1].Value.Replace('\\\\', '\')
                if ($libraryPath -and (Test-Path -LiteralPath $libraryPath -PathType Container) -and -not $expandedRoots.Contains($libraryPath)) {
                    $expandedRoots.Add($libraryPath)
                }
            }
        }
    }

    return $expandedRoots.ToArray()
}

function Find-SteamExe {
    foreach ($root in Get-SteamRoots) {
        $steamExe = Join-Path $root 'steam.exe'
        if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
            return $steamExe
        }
    }

    $registryExe = $null
    try {
        $registryExe = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe
    }
    catch {
    }

    if ($registryExe) {
        $normalized = $registryExe.Replace('/', '\').Trim('"')
        if (Test-Path -LiteralPath $normalized -PathType Leaf) {
            return $normalized
        }
    }

    return $null
}

function Find-ArchiveExe {
    param(
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        try {
            $resolvedExplicitPath = (Resolve-Path -LiteralPath $ExplicitPath -ErrorAction Stop).Path
        }
        catch {
            throw "The supplied -ArchiveExePath does not exist: $ExplicitPath"
        }

        if (-not (Test-Path -LiteralPath $resolvedExplicitPath -PathType Leaf)) {
            throw "The supplied -ArchiveExePath is not a file: $resolvedExplicitPath"
        }

        if ([IO.Path]::GetFileName($resolvedExplicitPath) -ine 'Archive.exe') {
            Write-Warn "The supplied -ArchiveExePath does not end with Archive.exe, but it will be used anyway: $resolvedExplicitPath"
        }
        else {
            Write-Info "Using supplied -ArchiveExePath: $resolvedExplicitPath"
        }

        return $resolvedExplicitPath
    }

    foreach ($root in Get-SteamRoots) {
        foreach ($relative in @(
            'steamapps\common\Homeworld\GBXTools\WorkshopTool\Archive.exe',
            'steamapps\common\Homeworld 347380\GBXTools\WorkshopTool\Archive.exe',
            'steamapps\common\Homeworld Remastered Toolkit\GBXTools\WorkshopTool\Archive.exe',
            'steamapps\common\Homeworld Remastered Collection\GBXTools\WorkshopTool\Archive.exe'
        )) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    foreach ($root in Get-SteamRoots) {
        $commonRoot = Join-Path $root 'steamapps\common'
        if (-not (Test-Path -LiteralPath $commonRoot -PathType Container)) {
            continue
        }

        $candidate = Get-ChildItem -Path $commonRoot -Recurse -File -Filter 'Archive.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]GBXTools[\\/]WorkshopTool[\\/]Archive\.exe$' } |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    return $null
}

function Wait-ForArchiveExe {
    param(
        [string]$ExplicitPath,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    do {
        $attempt++
        $archiveExe = Find-ArchiveExe -ExplicitPath $ExplicitPath
        if ($archiveExe) {
            return $archiveExe
        }

        $remaining = [Math]::Max(0, [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
        Write-Info "Waiting for Archive.exe to appear... attempt $attempt, checking again in $PollSeconds seconds, $remaining seconds remaining."
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Ensure-ArchiveExe {
    param(
        [string]$ArchiveExePath,
        [switch]$SkipToolkitInstallAttempt
    )

    $archiveExe = Find-ArchiveExe -ExplicitPath $ArchiveExePath
    if ($archiveExe) {
        Write-Okay "Found Archive.exe: $archiveExe"
        return $archiveExe
    }

    if ($SkipToolkitInstallAttempt) {
        throw "Archive.exe was not found, and -SkipToolkitInstallAttempt was specified. Install the Homeworld Remastered Toolkit in Steam, or supply -ArchiveExePath, then rerun the script."
    }

    $steamExe = Find-SteamExe
    if (-not $steamExe) {
        throw "Archive.exe was not found, and Steam could not be located automatically. Install the Homeworld Remastered Toolkit (AppID 347380) in Steam, or supply -ArchiveExePath, then rerun the script."
    }

    Write-Warn "Archive.exe was not found. Attempting to trigger Homeworld Remastered Toolkit install through Steam (steam://install/347380)."
    Start-Process 'steam://install/347380' | Out-Null
    Write-Info 'If Steam prompted for installation, complete the install. The script will keep polling for Archive.exe.'

    $archiveExe = Wait-ForArchiveExe -ExplicitPath $ArchiveExePath -TimeoutSeconds 900 -PollSeconds 10
    if (-not $archiveExe) {
        throw "The script triggered the Steam install, but Archive.exe still was not found within the timeout window. Finish installing 'Homeworld Remastered Toolkit' in Steam, then rerun the script, or supply -ArchiveExePath explicitly."
    }

    Write-Okay "Found Archive.exe after Steam install attempt: $archiveExe"
    return $archiveExe
}

function Ensure-BigDecrypter {
    param(
        [Parameter(Mandatory)][string]$ToolsRoot,
        [switch]$ForceRedownload
    )

    $existing = Get-FirstFileMatch -Root $ToolsRoot -Patterns @('bigDecrypter.exe')
    if ($existing -and -not $ForceRedownload) {
        Write-Okay "Using existing bigDecrypter.exe: $existing"
        return $existing
    }

    $downloadUrl = Get-GitHubLatestReleaseAssetUrl -Repository 'mon/bigDecrypter' -AssetRegex '(?i)bigdecrypter.*\.(zip|exe)$'
    $assetFileName = [IO.Path]::GetFileName(([System.Uri]$downloadUrl).LocalPath)
    if ([string]::IsNullOrWhiteSpace($assetFileName)) {
        $assetFileName = 'bigDecrypter_asset.zip'
    }
    $downloadPath = Join-Path $ToolsRoot ("downloads\{0}" -f $assetFileName)
    $downloaded = Invoke-Download -Uri $downloadUrl -DestinationPath $downloadPath

    $extension = [IO.Path]::GetExtension($downloaded)
    if ($extension -ieq '.zip') {
        $extractRoot = Expand-ZipFile -ZipPath $downloaded -DestinationPath (Join-Path $ToolsRoot 'bigDecrypter')
        $exe = Get-FirstFileMatch -Root $extractRoot -Patterns @('bigDecrypter.exe')
        if (-not $exe) {
            throw "Downloaded bigDecrypter archive, but bigDecrypter.exe was not found after extraction."
        }
        Write-Okay "Downloaded bigDecrypter.exe: $exe"
        return $exe
    }

    if ($extension -ieq '.exe') {
        $targetDir = New-Directory -Path (Join-Path $ToolsRoot 'bigDecrypter')
        $targetExe = Join-Path $targetDir 'bigDecrypter.exe'
        Copy-Item -LiteralPath $downloaded -Destination $targetExe -Force
        Write-Okay "Downloaded bigDecrypter.exe: $targetExe"
        return $targetExe
    }

    throw "Downloaded bigDecrypter asset has an unsupported extension: $extension"
}

function Ensure-RelicAudioTools {
    param(
        [Parameter(Mandatory)][string]$ToolsRoot,
        [Parameter(Mandatory)][string]$ZipUrl,
        [switch]$ForceRedownload
    )

    $existingDecShell = Get-FirstFileMatch -Root $ToolsRoot -Patterns @('decShell.exe')
    $existingFda2Aifc = Get-FirstFileMatch -Root $ToolsRoot -Patterns @('fda2aifc.exe')

    if ($existingDecShell -and $existingFda2Aifc -and -not $ForceRedownload) {
        Write-Okay "Using existing decShell.exe: $existingDecShell"
        Write-Okay "Using existing fda2aifc.exe: $existingFda2Aifc"
        return [PSCustomObject]@{
            DecShellExe = $existingDecShell
            Fda2AifcExe = $existingFda2Aifc
        }
    }

    Write-Warn "The legacy Relic audio package is being fetched from a legacy HTTP mirror: $ZipUrl"
    $zipPath = Join-Path $ToolsRoot 'downloads\fda2aifc.zip'
    $downloaded = Invoke-Download -Uri $ZipUrl -DestinationPath $zipPath
    $extractRoot = Expand-ZipFile -ZipPath $downloaded -DestinationPath (Join-Path $ToolsRoot 'fda2aifc')

    $decShellExe = Get-FirstFileMatch -Root $extractRoot -Patterns @('decShell.exe')
    if (-not $decShellExe) {
        throw "Downloaded fda2aifc package, but decShell.exe was not found after extraction."
    }

    $fda2AifcExe = Get-FirstFileMatch -Root $extractRoot -Patterns @('fda2aifc.exe')
    if (-not $fda2AifcExe) {
        throw "Downloaded fda2aifc package, but fda2aifc.exe was not found after extraction."
    }

    Write-Okay "Downloaded decShell.exe: $decShellExe"
    Write-Okay "Downloaded fda2aifc.exe: $fda2AifcExe"

    return [PSCustomObject]@{
        DecShellExe = $decShellExe
        Fda2AifcExe = $fda2AifcExe
    }
}

function Ensure-Ffmpeg {
    param(
        [Parameter(Mandatory)][string]$ToolsRoot,
        [switch]$ForceRedownload
    )

    $existing = Get-FirstFileMatch -Root $ToolsRoot -Patterns @('ffmpeg.exe')
    if ($existing -and -not $ForceRedownload) {
        Write-Okay "Using existing ffmpeg.exe: $existing"
        return $existing
    }

    $downloadUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    $zipPath = Join-Path $ToolsRoot 'downloads\ffmpeg-release-essentials.zip'
    $downloaded = Invoke-Download -Uri $downloadUrl -DestinationPath $zipPath
    $extractRoot = Expand-ZipFile -ZipPath $downloaded -DestinationPath (Join-Path $ToolsRoot 'ffmpeg')
    $exe = Get-FirstFileMatch -Root $extractRoot -Patterns @('ffmpeg.exe')
    if (-not $exe) {
        throw "Downloaded FFmpeg archive, but ffmpeg.exe was not found after extraction."
    }

    Write-Okay "Downloaded ffmpeg.exe: $exe"
    return $exe
}


function Get-BigHeaderText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ByteCount = 16
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] $ByteCount
        $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -le 0) {
            return ''
        }

        return ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)).Trim([char]0)
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-NativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )

    $displayArgs = if ($ArgumentList.Count -gt 0) { $ArgumentList -join ' ' } else { '' }
    Write-Info ("Running: {0} {1}" -f $FilePath, $displayArgs)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($arg in $ArgumentList) {
        $null = $psi.ArgumentList.Add($arg)
    }

    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        $null = $process.Start()
        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($stdOut) {
            Write-Host $stdOut.TrimEnd()
        }
        if ($stdErr) {
            Write-Host $stdErr.TrimEnd()
        }

        if ($process.ExitCode -ne 0) {
            throw "Command failed with exit code $($process.ExitCode): $FilePath"
        }

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdOut
            StdErr   = $stdErr
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-FlattenedOutputName {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][hashtable]$UsedNames
    )

    $relative = [IO.Path]::GetRelativePath($RootPath, $SourcePath)
    $stem = [IO.Path]::ChangeExtension($relative, $null)

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($rawSegment in ($stem -split '[\/]+' )) {
        $segment = ($rawSegment -replace '[<>:"/\|?*]', '_')
        $segment = ($segment -replace '\s+', '_')
        $segment = ($segment -replace '_+', '_').Trim(' ', '_', '.')
        if (-not [string]::IsNullOrWhiteSpace($segment)) {
            $segments.Add($segment)
        }
    }

    $baseName = (($segments.ToArray()) -join '_')
    $baseName = ($baseName -replace '_+', '_').Trim(' ', '_', '.')

    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'audio'
    }

    if ($baseName.Length -gt 180) {
        $hash = Get-FileHashString -InputString $relative
        $prefixLength = [Math]::Min(140, $baseName.Length)
        $baseName = ('{0}_{1}' -f $baseName.Substring(0, $prefixLength), $hash.Substring(0, 12)).Trim(' ', '_', '.')
    }

    $normalizedExtension = '.' + $Extension.Trim().TrimStart('.')
    $candidateBaseName = $baseName.TrimEnd('.')
    $candidate = '{0}{1}' -f $candidateBaseName, $normalizedExtension
    $candidateKey = $candidate.ToLowerInvariant()

    if ($UsedNames.ContainsKey($candidateKey)) {
        $hash = Get-FileHashString -InputString $relative
        $candidate = '{0}_{1}{2}' -f $candidateBaseName, $hash.Substring(0, 8), $normalizedExtension
        $candidateKey = $candidate.ToLowerInvariant()

        $hashLength = 9
        while ($UsedNames.ContainsKey($candidateKey)) {
            $candidate = '{0}_{1}{2}' -f $candidateBaseName, $hash.Substring(0, [Math]::Min($hashLength, $hash.Length)), $normalizedExtension
            $candidateKey = $candidate.ToLowerInvariant()
            $hashLength++
        }
    }

    $UsedNames[$candidateKey] = $true
    return $candidate
}

function New-SequentialStageFileName {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Extension
    )

    return ('f{0:D6}{1}' -f $Index, $Extension)
}

function Stage-FdaFiles {
    param(
        [Parameter(Mandatory)][string]$ExtractRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [switch]$ForceRestage
    )

    $manifestPath = Join-Path $StageRoot 'manifest.csv'
    if ((-not $ForceRestage) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $existingRows = @(Import-Csv -LiteralPath $manifestPath)
        $requiredColumns = @('NameStrategyVersion', 'StagedFdaPath', 'StagedFdaName', 'StagedAifcPath', 'StagedWavPath', 'OutputBaseName', 'OutputMp3Path')
        $columnsPresent = $true
        $nameStrategyMatches = $true
        if ($existingRows.Count -gt 0) {
            foreach ($column in $requiredColumns) {
                if (-not ($existingRows[0].PSObject.Properties.Name -contains $column)) {
                    $columnsPresent = $false
                    break
                }
            }

            if ($columnsPresent) {
                $nameStrategyMatches = ([string]$existingRows[0].NameStrategyVersion -eq $script:StageManifestNameStrategyVersion)
            }
        }

        if ($columnsPresent -and $nameStrategyMatches) {
            Write-Okay "Using existing staged FDA set: $StageRoot"
            return [PSCustomObject]@{
                ManifestPath = $manifestPath
                FdaCount     = $existingRows.Count
            }
        }

        Write-Warn "Existing manifest schema or naming strategy is from an older script revision. Rebuilding the staged FDA set."
    }

    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }
    New-Directory -Path $StageRoot | Out-Null

    $fdaFiles = @(Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter '*.fda' | Sort-Object FullName)
    if ($fdaFiles.Count -eq 0) {
        throw "No FDA files were found under extracted content: $ExtractRoot"
    }

    $manifestRows = New-Object System.Collections.Generic.List[object]
    $outputNameMap = @{}
    $counter = 0

    foreach ($file in $fdaFiles) {
        $counter++
        $stageName = New-SequentialStageFileName -Index $counter -Extension '.fda'
        $outputName = New-FlattenedOutputName -SourcePath $file.FullName -RootPath $ExtractRoot -Extension '.mp3' -UsedNames $outputNameMap
        $outputBaseName = [IO.Path]::GetFileNameWithoutExtension($outputName)
        $destPath = Join-Path $StageRoot $stageName

        Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force

        $manifestRows.Add([PSCustomObject]@{
            NameStrategyVersion = $script:StageManifestNameStrategyVersion
            SourceFullPath      = $file.FullName
            SourceRelativePath  = [IO.Path]::GetRelativePath($ExtractRoot, $file.FullName)
            StagedFdaPath       = $destPath
            StagedFdaName       = $stageName
            StagedAifcPath      = (Join-Path $StageRoot ($stageName -replace '\.fda$', '.aifc'))
            StagedWavPath       = (Join-Path $StageRoot ($stageName -replace '\.fda$', '.wav'))
            OutputBaseName      = $outputBaseName
            OutputMp3Path       = (Join-Path $OutputRoot ($outputBaseName + '.mp3'))
        }) | Out-Null

        if (($counter % 250) -eq 0) {
            Write-Info "Staged $counter / $($fdaFiles.Count) FDA files..."
        }
    }

    $manifestRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    Write-Okay "Staged $counter FDA files into: $StageRoot"

    return [PSCustomObject]@{
        ManifestPath = $manifestPath
        FdaCount     = $counter
    }
}

function Convert-StagedFdaToWav {
    param(
        [Parameter(Mandatory)][string]$Fda2AifcExe,
        [Parameter(Mandatory)][string]$DecShellExe,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $rows = @(Import-Csv -LiteralPath $ManifestPath)
    if ($rows.Count -eq 0) {
        throw "The stage manifest is empty: $ManifestPath"
    }

    $preExistingAifc = @(Get-ChildItem -Path $StageRoot -File -Filter '*.aifc' -ErrorAction SilentlyContinue)
    if ($preExistingAifc.Count -gt 0) {
        Write-Info "Removing $($preExistingAifc.Count) existing AIFC files from stage root before conversion."
        $preExistingAifc | Remove-Item -Force
    }

    $preExistingWav = @(Get-ChildItem -Path $StageRoot -File -Filter '*.wav' -ErrorAction SilentlyContinue)
    if ($preExistingWav.Count -gt 0) {
        Write-Info "Removing $($preExistingWav.Count) existing WAV files from stage root before conversion."
        $preExistingWav | Remove-Item -Force
    }

    $missingFdas = @($rows | Where-Object { -not (Test-Path -LiteralPath $_.StagedFdaPath -PathType Leaf) })
    if ($missingFdas.Count -gt 0) {
        $sample = ($missingFdas | Select-Object -First 3 | ForEach-Object { $_.StagedFdaPath }) -join '; '
        throw "The stage manifest references FDA files that are missing from the stage root. Sample: $sample"
    }

    Write-Info "Running decShell.exe directly against staged FDA files in: $StageRoot"
    try {
        Invoke-NativeCommand -FilePath $DecShellExe -WorkingDirectory $StageRoot -ArgumentList @('*.fda') | Out-Null
    }
    catch {
        throw "decShell.exe failed while converting staged FDA files. $($_.Exception.Message)"
    }

    $missingWav = @($rows | Where-Object { -not (Test-Path -LiteralPath $_.StagedWavPath -PathType Leaf) })
    if ($missingWav.Count -gt 0) {
        $sample = ($missingWav | Select-Object -First 5 | ForEach-Object { $_.StagedFdaName }) -join ', '
        throw "decShell.exe completed, but not all expected WAV files were produced. Missing sample(s): $sample"
    }

    $converted = foreach ($row in $rows) {
        [PSCustomObject]@{
            FdaPath = $row.StagedFdaPath
            WavPath = $row.StagedWavPath
        }
    }

    Write-Okay "Converted $($rows.Count) FDA files to WAV through decShell.exe."
    return $converted
}

function Convert-WavToMp3 {
    param(
        [Parameter(Mandatory)][string]$FfmpegExe,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][int]$BitrateKbps
    )

    New-Directory -Path $OutputRoot | Out-Null
    $rows = @(Import-Csv -LiteralPath $ManifestPath)
    if ($rows.Count -eq 0) {
        throw "The stage manifest is empty: $ManifestPath"
    }

    $missingWav = @($rows | Where-Object { -not (Test-Path -LiteralPath $_.StagedWavPath -PathType Leaf) })
    if ($missingWav.Count -gt 0) {
        $sample = ($missingWav | Select-Object -First 5 | ForEach-Object { $_.StagedWavPath }) -join '; '
        throw "No WAV conversion can proceed because expected WAV files are missing. Sample: $sample"
    }

    $converted = New-Object System.Collections.Generic.List[object]
    $total = $rows.Count
    $index = 0
    $bitrate = '{0}k' -f $BitrateKbps

    foreach ($row in $rows) {
        $index++
        $outPath = Join-Path $OutputRoot ($row.OutputBaseName + '.mp3')

        Write-Progress -Activity 'Converting WAV to MP3' -Status "$index / $total" -PercentComplete (($index / $total) * 100)
        Invoke-NativeCommand -FilePath $FfmpegExe -WorkingDirectory $StageRoot -ArgumentList @(
            '-y',
            '-hide_banner',
            '-loglevel', 'error',
            '-i', $row.StagedWavPath,
            '-vn',
            '-codec:a', 'libmp3lame',
            '-b:a', $bitrate,
            '-map_metadata', '-1',
            '-id3v2_version', '3',
            $outPath
        ) | Out-Null

        if (-not (Test-Path -LiteralPath $outPath -PathType Leaf)) {
            throw "FFmpeg reported success, but the MP3 was not created: $outPath"
        }

        $row.OutputMp3Path = $outPath
        $converted.Add([PSCustomObject]@{
            WavPath = $row.StagedWavPath
            Mp3Path = $outPath
        }) | Out-Null
    }

    $rows | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8

    Write-Progress -Activity 'Converting WAV to MP3' -Completed
    Write-Okay "Converted $($converted.Count) WAV files to MP3."

    return $converted
}

function Update-ManifestWithMp3Paths {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $rows = Import-Csv -LiteralPath $ManifestPath
    foreach ($row in $rows) {
        $row.OutputMp3Path = Join-Path $OutputRoot ($row.OutputBaseName + '.mp3')
    }

    $rows | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8
    return $rows
}

function Remove-IntermediateArtifacts {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

Assert-PowerShell7

$resolvedBigFilePath = (Resolve-Path -LiteralPath $BigFilePath).Path
$WorkingDirectory = New-Directory -Path $WorkingDirectory

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $WorkingDirectory 'mp3'
}
$OutputDirectory = New-Directory -Path $OutputDirectory

if (-not $ToolsDirectory) {
    $ToolsDirectory = Join-Path $WorkingDirectory '_tools'
}
$ToolsDirectory = New-Directory -Path $ToolsDirectory

$stageRoot = New-Directory -Path (Join-Path $WorkingDirectory '_stage')
$bigStageRoot = New-Directory -Path (Join-Path $stageRoot 'big')
$extractRoot = Join-Path $stageRoot 'extracted'
$fdaStageRoot = Join-Path $stageRoot 'fda'

Write-Step 'Locate / download required tools'
$bigDecrypterExe = Ensure-BigDecrypter -ToolsRoot $ToolsDirectory -ForceRedownload:$ForceRedownload
$relicAudioTools = Ensure-RelicAudioTools -ToolsRoot $ToolsDirectory -ZipUrl $Fda2AifcZipUrl -ForceRedownload:$ForceRedownload
$fda2AifcExe = $relicAudioTools.Fda2AifcExe
$decShellExe = $relicAudioTools.DecShellExe
$ffmpegExe = $null
if (-not $SkipMp3) {
    $ffmpegExe = Ensure-Ffmpeg -ToolsRoot $ToolsDirectory -ForceRedownload:$ForceRedownload
}
$archiveExe = Ensure-ArchiveExe -ArchiveExePath $ArchiveExePath -SkipToolkitInstallAttempt:$SkipToolkitInstallAttempt

Write-Step 'Stage the BIG file'
$stagedBigPath = Join-Path $bigStageRoot (Split-Path -Path $resolvedBigFilePath -Leaf)
Copy-Item -LiteralPath $resolvedBigFilePath -Destination $stagedBigPath -Force
Write-Okay "Copied source BIG to: $stagedBigPath"

$decryptedBigPath = Join-Path $bigStageRoot ('{0}_decrypted{1}' -f [IO.Path]::GetFileNameWithoutExtension($stagedBigPath), [IO.Path]::GetExtension($stagedBigPath))
$bigHeaderText = Get-BigHeaderText -Path $stagedBigPath

if ($bigHeaderText -like '_ARCHIVE*') {
    $decryptedBigPath = $stagedBigPath
    Write-Info "BIG file begins with _ARCHIVE; skipping decryption because the file is already plaintext."
}
else {
    if ((-not (Test-Path -LiteralPath $decryptedBigPath -PathType Leaf)) -or $ForceRedownload) {
        Write-Step 'Decrypt BIG file'
        Invoke-NativeCommand -FilePath $bigDecrypterExe -ArgumentList @($stagedBigPath, $decryptedBigPath) | Out-Null
    }

    if (-not (Test-Path -LiteralPath $decryptedBigPath -PathType Leaf)) {
        throw "Decryption step completed, but the decrypted BIG file was not found: $decryptedBigPath"
    }
}

Write-Okay "Decrypted BIG: $decryptedBigPath"

Write-Step 'Extract decrypted BIG'
if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
New-Directory -Path $extractRoot | Out-Null
Invoke-NativeCommand -FilePath $archiveExe -ArgumentList @('-e', $extractRoot, '-a', $decryptedBigPath) | Out-Null
Write-Okay "Extracted decrypted BIG into: $extractRoot"

Write-Step 'Stage all FDA files into a flat working set'
$stagingResult = Stage-FdaFiles -ExtractRoot $extractRoot -StageRoot $fdaStageRoot -OutputRoot $OutputDirectory -ForceRestage:$ForceRestage
Write-Info "FDA files staged: $($stagingResult.FdaCount)"

Write-Step 'Convert FDA to WAV with decShell.exe'
$wavFiles = Convert-StagedFdaToWav -Fda2AifcExe $fda2AifcExe -DecShellExe $decShellExe -StageRoot $fdaStageRoot -ManifestPath $stagingResult.ManifestPath

if (-not $SkipMp3) {
    Write-Step 'Convert WAV to MP3 with FFmpeg'
    $converted = Convert-WavToMp3 -FfmpegExe $ffmpegExe -StageRoot $fdaStageRoot -ManifestPath $stagingResult.ManifestPath -OutputRoot $OutputDirectory -BitrateKbps $Mp3BitrateKbps
    $null = Update-ManifestWithMp3Paths -ManifestPath $stagingResult.ManifestPath -OutputRoot $OutputDirectory
}
else {
    Write-Warn 'Skipping MP3 conversion because -SkipMp3 was specified.'
}

if (-not $KeepIntermediate) {
    Write-Step 'Cleanup intermediate artifacts'
    if (Test-Path -LiteralPath $fdaStageRoot) {
        Get-ChildItem -Path $fdaStageRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.fda', '.aifc', '.wav') } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stagedBigPath -PathType Leaf) {
        Remove-Item -LiteralPath $stagedBigPath -Force -ErrorAction SilentlyContinue
    }
    if (($decryptedBigPath -ne $stagedBigPath) -and (Test-Path -LiteralPath $decryptedBigPath -PathType Leaf)) {
        Remove-Item -LiteralPath $decryptedBigPath -Force -ErrorAction SilentlyContinue
    }
    Write-Okay 'Removed staged FDA/AIFC/WAV files, extracted content, and BIG intermediates.'
}
else {
    Write-Warn "Keeping intermediate artifacts under: $stageRoot"
}

Write-Step 'Done'
Write-Host "MP3 output directory : $OutputDirectory" -ForegroundColor Green
Write-Host "Manifest CSV        : $($stagingResult.ManifestPath)" -ForegroundColor Green
Write-Host "Tools directory     : $ToolsDirectory" -ForegroundColor Green
