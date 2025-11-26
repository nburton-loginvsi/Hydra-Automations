# Script to set fallback type for Zoom.
# See here for more info: https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064784#h_01HCZGFDCXKZVFYNV0WMSK2TWZ

# Zoom VDI Policy Registry Path
$Path = "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\VDI"

# Create the key if it doesn't exist
If (!(Test-Path $Path)) {
    New-Item -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings" -Name "VDI" -Force | Out-Null
}

# Set FallbackMode = 3 (User gets "unable to join" popup)
New-ItemProperty -Path $Path -Name "FallbackMode" -PropertyType DWord -Value 3 -Force | Out-Null

# Custom message displayed when fallback kicks in
$Message = "Zoom VDI plugin not detected or outdated.`n`nDownload the latest plugin from:`nhttps://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0057842"
New-ItemProperty -Path $Path -Name "ServiceUnavailableTipMsg" -PropertyType String -Value $Message -Force | Out-Null

Write-Host "Zoom VDI FallbackMode set to 3 and user message configured."
