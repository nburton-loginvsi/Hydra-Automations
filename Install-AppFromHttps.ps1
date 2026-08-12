# HTTPS URL to the installer package. Supported downloads are .exe, .msi, and .zip.
$InstallerUrl = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.7/npp.8.9.7.Installer.x64.exe"

# Arguments passed to the installer. For MSI files, these are appended after msiexec.exe /i "installer.msi".
$InstallerArguments = "/S"

# Local working folder for downloads and ZIP extraction. The script creates this folder if it does not exist.
$TempDirectory = "C:\temp"

# Optional local file name for the download. Leave blank to use the file name from the HTTPS URL.
# Set this when the URL does not end with a usable file name, such as https://example.com/download?id=123.
$DownloadFileName = ""

# Folder name created under $TempDirectory when the downloaded file is a ZIP.
$ExtractDirectoryName = "installer_extract"

# Search patterns used only after ZIP extraction. Use a specific name to target one installer, or leave fallbacks.
# The first matching installer is selected alphabetically by full path.
$InstallerSearchPatterns = @("*.exe", "*.msi")

$ErrorActionPreference = "Stop"

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $formattedMessage = "[Install-FromHttps] $Message"

    if (Get-Command -Name OutputWriter -ErrorAction SilentlyContinue) {
        OutputWriter $formattedMessage
    }
    else {
        Write-Host $formattedMessage
    }
}

function Get-DownloadFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [string]$ConfiguredFileName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredFileName)) {
        return $ConfiguredFileName
    }

    $uri = [System.Uri]::new($Url)
    $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)

    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Unable to determine a file name from the URL. Set `$DownloadFileName at the top of the script."
    }

    return $fileName
}

function Find-Installer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $match = Get-ChildItem -LiteralPath $SearchPath -Recurse -File -Filter $pattern |
            Sort-Object FullName |
            Select-Object -First 1

        if ($null -ne $match) {
            return $match.FullName
        }
    }

    throw "No executable installer was found in '$SearchPath'. Looked for: $($Patterns -join ', ')"
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $false)]
        [string]$Arguments
    )

    $extension = [System.IO.Path]::GetExtension($InstallerPath).ToLowerInvariant()

    switch ($extension) {
        ".exe" {
            Write-Step "Running EXE installer: $InstallerPath"
            $process = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
        }
        ".msi" {
            Write-Step "Running MSI installer: $InstallerPath"
            $msiArguments = "/i `"$InstallerPath`" $Arguments".Trim()
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArguments -Wait -PassThru
        }
        default {
            throw "Unsupported installer type '$extension'. Expected .exe or .msi."
        }
    }

    if ($process.ExitCode -ne 0) {
        throw "Installer failed with exit code $($process.ExitCode)."
    }

    Write-Step "Installer completed successfully."
}

if (-not $InstallerUrl.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallerUrl must use HTTPS."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $TempDirectory -PathType Container)) {
    Write-Step "Creating temp directory: $TempDirectory"
    New-Item -Path $TempDirectory -ItemType Directory -Force | Out-Null
}

$resolvedTempDirectory = (Resolve-Path -LiteralPath $TempDirectory).Path
$downloadedFileName = Get-DownloadFileName -Url $InstallerUrl -ConfiguredFileName $DownloadFileName
$downloadPath = Join-Path -Path $resolvedTempDirectory -ChildPath $downloadedFileName

Write-Step "Downloading installer from $InstallerUrl"
Invoke-WebRequest -Uri $InstallerUrl -OutFile $downloadPath -UseBasicParsing

$downloadExtension = [System.IO.Path]::GetExtension($downloadPath).ToLowerInvariant()

switch ($downloadExtension) {
    ".zip" {
        $extractPath = Join-Path -Path $resolvedTempDirectory -ChildPath $ExtractDirectoryName

        if (Test-Path -LiteralPath $extractPath) {
            $extractPath = Join-Path -Path $resolvedTempDirectory -ChildPath "$ExtractDirectoryName-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }

        Write-Step "Extracting ZIP to $extractPath"
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force

        $installerPath = Find-Installer -SearchPath $extractPath -Patterns $InstallerSearchPatterns
        Invoke-Installer -InstallerPath $installerPath -Arguments $InstallerArguments
    }
    ".exe" {
        Invoke-Installer -InstallerPath $downloadPath -Arguments $InstallerArguments
    }
    ".msi" {
        Invoke-Installer -InstallerPath $downloadPath -Arguments $InstallerArguments
    }
    default {
        throw "Unsupported downloaded file type '$downloadExtension'. Expected .exe, .msi, or .zip."
    }
}
