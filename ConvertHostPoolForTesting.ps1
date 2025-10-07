LogWriter("Downloading Logon EXE")

# Base FQDN of the appliance
$applianceFQDN = 'https://fqdnOfLEappliance.company.com'

# URL of the ZIP file to download
$url = "$applianceFQDN/contentDelivery/api/logonApp"

# Arguments to pass to the EXE (adjust as needed)
$arguments = $applianceFQDN

# Define temp paths
$tempDir    = 'C:\LoginVSI'
$zipName    = [IO.Path]::GetFileName($url)                    
$zipPath    = Join-Path $tempDir "$zipName.zip"                      
$extractDir = Join-Path $tempDir ([IO.Path]::GetFileNameWithoutExtension($zipName))

# Define shortcut properties

# Define target executable and Startup shortcut paths
$targetPath = 'C:\LoginVSI\logonApp\LoginPI.Logon.exe'
$shortcutPath = "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\Startup\LoginPI_Logon.lnk"

# Ensure the extract directory exists (or recreate it)
if (Test-Path $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
}
New-Item -ItemType Directory -Path $extractDir | Out-Null

try {
    # Download the ZIP file
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

    # Extract the ZIP into $extractDir; -Force will overwrite if files already exist
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # Find the first .exe in the extracted folder (recursively)
    $exe = Get-ChildItem -Path $extractDir -Filter '*.exe' -Recurse |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

    if (-not $exe) {
        throw "No executable (.exe) found in '$extractDir'."
    }

    # Create the shortcut

try {
    
    # Verify the target executable exists
    if (-not (Test-Path -Path $targetPath -PathType Leaf)) {
        throw "Target executable not found: $targetPath"
    }

    # Ensure the Startup folder exists (it should, but just in case)
    $startupFolder = Split-Path -Parent $shortcutPath
    if (-not (Test-Path -Path $startupFolder -PathType Container)) {
        throw "Startup folder does not exist: $startupFolder"
    }

    # Create the WScript.Shell COM object
    try {
        $WshShell = New-Object -ComObject WScript.Shell
    }
    catch {
        throw "Unable to create WScript.Shell COM object: $_"
    }

    # Create the shortcut
    $shortcut = $WshShell.CreateShortcut($shortcutPath)

    # Assign properties to the shortcut
    $shortcut.TargetPath       = $targetPath
    $shortcut.Arguments        = $arguments
    $shortcut.WorkingDirectory = Split-Path -Parent $targetPath

    # Save the shortcut to disk
    $shortcut.Save()

    Write-Host "Shortcut successfully created at: $shortcutPath"
    LogWriter("Shortcut created!")
}
catch {
    Write-Error "Failed to create shortcut: $_"
   LogWriter("Failed to create shortcut! $_")
}


}
catch {
    Write-Error "An error occurred: $_"
    LogWriter("An error occurred! $_")
}

