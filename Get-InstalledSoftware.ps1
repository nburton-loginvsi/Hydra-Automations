<#
.SYNOPSIS
Lists installed software with version and install date, optionally exporting to CSV.

.NOTES
Reads the standard Windows uninstall registry keys for both 64-bit and 32-bit
applications, including per-machine and current-user installs.
#>

# -----------------------------
# User-configurable settings
# -----------------------------
$ExportToCsv = $true
$ExportDirectory = 'C:\temp'

# Leave blank to auto-name the file with the generation date/time.
# Example override: 'InstalledSoftware.csv'
$CsvFileNameOverride = ''

# -----------------------------
# Script logic
# -----------------------------
$RegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Convert-InstallDate {
    param(
        [AllowNull()]
        [string]$InstallDate
    )

    if ([string]::IsNullOrWhiteSpace($InstallDate)) {
        return $null
    }

    $parsedDate = [datetime]::MinValue
    if ([datetime]::TryParseExact(
            $InstallDate,
            'yyyyMMdd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )) {
        return $parsedDate.ToString('yyyy-MM-dd')
    }

    return $InstallDate
}

$InstalledSoftware = foreach ($path in $RegistryPaths) {
    Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.DisplayName) -and
            $_.SystemComponent -ne 1 -and
            $_.ReleaseType -notin @('Hotfix', 'Security Update', 'Update Rollup')
        } |
        ForEach-Object {
            [pscustomobject]@{
                SoftwareName = $_.DisplayName
                Version = $_.DisplayVersion
                InstallDate = Convert-InstallDate -InstallDate $_.InstallDate
                Publisher = $_.Publisher
                RegistryPath = $_.PSPath
            }
        }
}

$InstalledSoftware = $InstalledSoftware |
    Sort-Object SoftwareName, Version, InstallDate -Unique

$InstalledSoftware |
    Select-Object SoftwareName, Version, InstallDate |
    Format-Table -AutoSize

if ($ExportToCsv) {
    if (-not (Test-Path -Path $ExportDirectory -PathType Container)) {
        New-Item -Path $ExportDirectory -ItemType Directory -Force | Out-Null
    }

    $csvFileName = if ([string]::IsNullOrWhiteSpace($CsvFileNameOverride)) {
        'InstalledSoftware_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    else {
        $CsvFileNameOverride
    }

    if ([System.IO.Path]::GetExtension($csvFileName) -ne '.csv') {
        $csvFileName = '{0}.csv' -f $csvFileName
    }

    $csvPath = Join-Path -Path $ExportDirectory -ChildPath $csvFileName

    $InstalledSoftware |
        Select-Object SoftwareName, Version, InstallDate |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host "CSV exported to: $csvPath"
}
