# ============================
# FSLogix App Masking Rule Deploy
# ============================
# Define your settings here.

$ZipUrl          = "https://github.com/nburton-loginvsi/misc/raw/refs/heads/main/fslogix/appMaskingRules.zip"
$RulesDir        = "C:\Program Files\FSLogix\Apps\Rules"
$BackupExisting  = $true      # makes a timestamped backup folder under $RulesDir
$ForceOverwrite  = $true      # overwrite existing .fxr/.fxa with same name
$Cleanup         = $true      # delete temp download/extract folder
$RestartService  = $false     # optional; rules apply at next user logon anyway

# Optional: "sync" mode deletes existing .fxr/.fxa not present in the ZIP
# WARNING: Turn this on only if the ZIP is the source of truth.
$SyncMode        = $false

# ============================
# Helpers
# ============================

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }
}

function Assert-HttpsUrl([string]$url) {
    $uri = [Uri]$url
    if ($uri.Scheme -ne "https") {
        throw "ZipUrl must use HTTPS. Got: $($uri.Scheme)"
    }
}

function Ensure-Directory([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Backup-Rules([string]$rulesDir) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $rulesDir ("Backup-" + $timestamp)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $existing = Get-ChildItem -LiteralPath $rulesDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".fxr", ".fxa" }

    foreach ($f in $existing) {
        Copy-Item -LiteralPath $f.FullName -Destination $backupDir -Force
    }

    Write-Host "Backup created: $backupDir ($($existing.Count) file(s))"
}

function Set-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function Download-File([string]$url, [string]$destPath) {
    Set-Tls
    Write-Host "Downloading ZIP: $url"
    Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing -ErrorAction Stop
}

function Get-FslogixServiceName {
    $candidates = @("frxsvc", "FSLogix Apps Service", "FSLogix Service")
    foreach ($c in $candidates) {
        $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $c -or $_.DisplayName -eq $c }
        if ($svc) { return $svc.Name }
    }
    return $null
}

# ============================
# Main
# ============================

Assert-Admin
Assert-HttpsUrl $ZipUrl
Ensure-Directory $RulesDir

if ($BackupExisting) {
    Backup-Rules $RulesDir
}

$workRoot = Join-Path $env:TEMP ("FSLogixRulesDeploy-" + [Guid]::NewGuid().ToString("N"))
$zipPath  = Join-Path $workRoot "rules.zip"
$extract  = Join-Path $workRoot "extracted"

Ensure-Directory $workRoot
Ensure-Directory $extract

try {
    Download-File $ZipUrl $zipPath

    Write-Host "Extracting ZIP to: $extract"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

    $ruleFiles = Get-ChildItem -LiteralPath $extract -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Extension -in ".fxr", ".fxa" }

    if (-not $ruleFiles -or $ruleFiles.Count -eq 0) {
        throw "No .fxr/.fxa files found in the ZIP."
    }

    Write-Host "Found $($ruleFiles.Count) rule file(s) in ZIP."
    $ruleFiles | ForEach-Object { Write-Host (" - " + $_.Name) }

    # Track names for sync mode
    $zipNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $ruleFiles) { [void]$zipNames.Add($f.Name) }

    $copied = 0
    foreach ($f in $ruleFiles) {
        $dest = Join-Path $RulesDir $f.Name

        if ((Test-Path -LiteralPath $dest) -and (-not $ForceOverwrite)) {
            Write-Host "Skipping (exists): $($f.Name)"
            continue
        }

        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $copied++
        Write-Host "Deployed: $($f.Name)"
    }

    if ($SyncMode) {
        Write-Host "SyncMode enabled: removing rules not present in ZIP..."
        $existing = Get-ChildItem -LiteralPath $RulesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in ".fxr", ".fxa" }

        $removed = 0
        foreach ($f in $existing) {
            if (-not $zipNames.Contains($f.Name)) {
                Remove-Item -LiteralPath $f.FullName -Force
                $removed++
                Write-Host "Removed: $($f.Name)"
            }
        }
        Write-Host "SyncMode complete. Removed $removed file(s)."
    }

    Write-Host "Deployment complete. Copied $copied file(s) to: $RulesDir"

    if ($RestartService) {
        $svcName = Get-FslogixServiceName
        if ($svcName) {
            Write-Host "Restarting service: $svcName"
            Restart-Service -Name $svcName -Force -ErrorAction Stop
            Write-Host "Service restarted."
        } else {
            Write-Host "FSLogix service not found; skipping restart."
        }
    }

    Write-Host "Reminder: App Masking changes apply at user logon. Existing sessions won't update."
}
finally {
    if ($Cleanup -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cleaned up temp folder: $workRoot"
    } else {
        Write-Host "Temp folder preserved: $workRoot"
    }
}
