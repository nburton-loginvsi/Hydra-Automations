#requires -Version 5.1

<#
    FSLogix profile cleanup/archive helper

    - Scans multiple FSLogix roots.
    - Resolves a likely username from each profile folder name.
    - Uses LDAP/ADSI (.NET DirectoryServices), not RSAT/AD PowerShell modules.
    - Flags profiles whose user does not exist.
    - Optionally flags profiles whose VHD/VHDX has not been modified in X days.
    - Can report only, move/archive, or delete.

    Review the configuration block below before running.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ShareDriveMap = @{}

# =========================
# Configuration
# =========================

# Safe default: report only. Valid values: Report, Move, Delete
$ActionMode = 'Report'

# FSLogix parent folder to scan.
$FslogixRoots = @(
    '\\share1\fslogix',
	'\\share2\fslogix'
)

# When ActionMode = Move, profiles are moved under this root.
# Each source root gets its own subfolder below the archive share.
$ArchiveRoot = '\\server3\FSLogixArchive'

# Optional log file. Leave blank to disable transcript-style output file.
$LogPath = ''

# Optional CSV report path. Leave blank to disable.
$CsvPath = ''

# If $true, write per-folder/per-user lookup detail to the console and log.
$VerboseLogging = $true

# If $true, flag a profile when the newest VHD/VHDX in the profile folder
# has not been modified in $VhdStaleDays days.
$CleanupIfVhdStale = $false

# Threshold in days for stale VHD/VHDX cleanup.
$VhdStaleDays = 90

# Optional: authenticate to UNC shares with the Hydra service account credential.
# Useful when the script runs as SYSTEM and must reach file shares.
$UseHydraServiceAccountForShares = $false

# Optional explicit credential override. Leave as $null unless using from Hydra
# $global:Hydra_ServiceAccount_PSC only when share auth is enabled.
$HydraShareCredential = $null
# $HydraShareCredential = $global:Hydra_ServiceAccount_PSC

# Search behavior:
# - If SearchBase is blank, the current domain naming context is used.
# - Use an LDAP DN such as 'OU=Users,DC=contoso,DC=com' to limit scope.
$SearchBase = ''

# If $true, search the Global Catalog (GC) instead of the current domain naming context.
# Useful in multi-domain forests. Disabled-account detection still works.
$UseGlobalCatalog = $false

# Folder selection:
# - Only direct child folders of each FSLogix root are processed.
# - Set to $true to skip empty folders.
$SkipEmptyFolders = $false

# FSLogix folder-name format. Valid values:
# - UsernameOnly        -> username
# - UsernameSid         -> username_S-1-5-21-...
# - SidUsername         -> S-1-5-21-..._username
# - CustomPatterns      -> use $FolderNamePatterns exactly as provided below
$FolderNameFormat = 'UsernameSid'

# Delimiter used by UsernameSid / SidUsername formats.
# Common values are '_' or nothing at all.
$UsernameSidDelimiter = '_'

# Custom folder-name parsing patterns, used only when $FolderNameFormat = 'CustomPatterns'.
# The script tries these patterns in order until one yields a username.
# The capture group must be named "User".
$FolderNamePatterns = @(
    '^(?:S-\d-\d+(?:-\d+)+)_(?<User>[^\\]+)$',
    '^(?<User>[^\\]+)_(?:S-\d-\d+(?:-\d+)+)$',
    '^(?<User>[^\\]+)$'
)

# Optional cleanup applied after extracting the username candidate.
# Examples:
# - Remove a domain prefix: '^[^_\\]+\\'
# - Remove a UPN suffix: '@contoso\.com$'
# - Remove FSLogix suffix text: '\.OLD$'
$UsernameCleanupRegexes = @(
)

# AD lookup preference order. Valid values: sAMAccountName, userPrincipalName, mail
$LookupAttributes = @(
    'sAMAccountName',
    'userPrincipalName'
)

# When a folder resolves to multiple AD users, choose how to handle it.
# Valid values: Skip, FirstMatch
$MultipleMatchMode = 'Skip'

# Exclusions
$ExcludedFolderNames = @(
    'Temp',
    'Archive'
)

# =========================
# Helper functions
# =========================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }

        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Write-VerboseLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($VerboseLogging) {
        Write-Log -Level 'INFO' -Message $Message
    }
}

function Get-UncShareRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $match = [regex]::Match($Path, '^(\\\\[^\\]+\\[^\\]+)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-AccessiblePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $UseHydraServiceAccountForShares) {
        return $Path
    }

    $shareRoot = Get-UncShareRoot -Path $Path
    if ([string]::IsNullOrWhiteSpace($shareRoot)) {
        return $Path
    }

    if ($null -eq $script:ShareDriveMap) {
        $script:ShareDriveMap = @{}
    }

    if (-not $script:ShareDriveMap.ContainsKey($shareRoot)) {
        $driveName = 'HFS{0}' -f ($script:ShareDriveMap.Count + 1)
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot -Credential $HydraShareCredential -Scope Script | Out-Null
        $script:ShareDriveMap[$shareRoot] = $driveName
        Write-Log -Message ('Authenticated share mapped: {0} -> {1}:' -f $shareRoot, $driveName)
    }

    $relativePath = $Path.Substring($shareRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return '{0}:\' -f $script:ShareDriveMap[$shareRoot]
    }

    return '{0}:\{1}' -f $script:ShareDriveMap[$shareRoot], $relativePath
}

function Remove-AuthenticatedShareMappings {
    if (-not $UseHydraServiceAccountForShares) {
        return
    }

    if ($null -eq $script:ShareDriveMap -or $script:ShareDriveMap.Count -eq 0) {
        return
    }

    foreach ($driveName in ($script:ShareDriveMap.Values | Sort-Object -Unique)) {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Scope Script -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SanitizedPathLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $label = $Text.Trim('\')
    $label = $label -replace '^[\\/]+', ''
    $label = $label -replace '[:*?"<>|]', '_'
    $label = $label -replace '[\\/]+', '_'
    return $label
}

function Get-ResolvedUserFromFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )

    $sidPattern = 'S-\d-\d+(?:-\d+)+'
    $escapedDelimiter = [regex]::Escape($UsernameSidDelimiter)
    $effectivePatterns = switch ($FolderNameFormat) {
        'UsernameOnly' {
            @(
                '^(?<User>[^\\]+)$'
            )
        }

        'UsernameSid' {
            if ([string]::IsNullOrEmpty($UsernameSidDelimiter)) {
                @(
                    '^(?<User>.+?)' + '(?:' + $sidPattern + ')$'
                )
            }
            else {
                @(
                    '^(?<User>[^\\]+)' + $escapedDelimiter + '(?:' + $sidPattern + ')$'
                )
            }
        }

        'SidUsername' {
            if ([string]::IsNullOrEmpty($UsernameSidDelimiter)) {
                @(
                    '^(?:' + $sidPattern + ')' + '(?<User>.+)$'
                )
            }
            else {
                @(
                    '^(?:' + $sidPattern + ')' + $escapedDelimiter + '(?<User>[^\\]+)$'
                )
            }
        }

        'CustomPatterns' {
            $FolderNamePatterns
        }

        default {
            throw "Unsupported FolderNameFormat: $FolderNameFormat"
        }
    }

    foreach ($pattern in $effectivePatterns) {
        $match = [regex]::Match($FolderName, $pattern)
        if (-not $match.Success) {
            continue
        }

        $candidate = $match.Groups['User'].Value.Trim()
        foreach ($cleanupRegex in $UsernameCleanupRegexes) {
            $candidate = [regex]::Replace($candidate, $cleanupRegex, '')
        }

        $candidate = $candidate.Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return $null
}

function New-LdapSearcher {
    $root = [ADSI]'LDAP://RootDSE'

    if ($UseGlobalCatalog) {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        $gcName = $forest.FindGlobalCatalog().Name
        $entryPath = if ([string]::IsNullOrWhiteSpace($SearchBase)) {
            'GC://{0}' -f $gcName
        }
        else {
            'GC://{0}/{1}' -f $gcName, $SearchBase
        }
    }
    else {
        $baseDn = if ([string]::IsNullOrWhiteSpace($SearchBase)) {
            [string]$root.defaultNamingContext
        }
        else {
            $SearchBase
        }

        $entryPath = 'LDAP://{0}' -f $baseDn
    }

    $entry = New-Object System.DirectoryServices.DirectoryEntry($entryPath)
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
    $searcher.PageSize = 1000
    $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $null = $searcher.PropertiesToLoad.Add('distinguishedName')
    $null = $searcher.PropertiesToLoad.Add('sAMAccountName')
    $null = $searcher.PropertiesToLoad.Add('userPrincipalName')
    return $searcher
}

function Get-AdUserByIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity
    )

    $searcher = New-LdapSearcher
    $safeIdentity = $Identity.Replace('\', '\5c').Replace('(', '\28').Replace(')', '\29').Replace('*', '\2a')

    $filterParts = foreach ($attribute in $LookupAttributes) {
        '({0}={1})' -f $attribute, $safeIdentity
    }

    $searcher.Filter = '(&(objectCategory=person)(objectClass=user)(|{0}))' -f ($filterParts -join '')
    Write-VerboseLog -Message ('AD query for identity "{0}" using filter: {1}' -f $Identity, $searcher.Filter)
    $results = $searcher.FindAll()

    if ($results.Count -eq 0) {
        Write-VerboseLog -Message ('AD query result for "{0}": no matches found.' -f $Identity)
        return [pscustomobject]@{
            Status        = 'Missing'
            Identity      = $Identity
            Distinguished = $null
            SamAccount    = $null
            Upn           = $null
            MatchCount    = 0
        }
    }

    if ($results.Count -gt 1 -and $MultipleMatchMode -eq 'Skip') {
        Write-VerboseLog -Message ('AD query result for "{0}": multiple matches found ({1}); configured to skip.' -f $Identity, $results.Count)
        return [pscustomobject]@{
            Status        = 'MultipleMatches'
            Identity      = $Identity
            Distinguished = $null
            SamAccount    = $null
            Upn           = $null
            MatchCount    = $results.Count
        }
    }

    $result = $results[0]
    $distinguishedName = [string]($result.Properties['distinguishedname'][0])
    $samAccountName = if ($result.Properties['samaccountname'].Count -gt 0) { [string]$result.Properties['samaccountname'][0] } else { $null }
    $userPrincipalName = if ($result.Properties['userprincipalname'].Count -gt 0) { [string]$result.Properties['userprincipalname'][0] } else { $null }
    Write-VerboseLog -Message ('AD query result for "{0}": status=Found; samAccountName={1}; upn={2}; dn={3}' -f $Identity, $samAccountName, $userPrincipalName, $distinguishedName)

    return [pscustomobject]@{
        Status        = 'Found'
        Identity      = $Identity
        Distinguished = $distinguishedName
        SamAccount    = $samAccountName
        Upn           = $userPrincipalName
        MatchCount    = $results.Count
    }
}

function Get-LatestProfileDiskInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    $disks = @(
        Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.vhd', '.vhdx') }
    )

    if ($disks.Count -eq 0) {
        return [pscustomobject]@{
            Found         = $false
            Path          = $null
            LastWriteTime = $null
            AgeDays       = $null
            IsStale       = $false
        }
    }

    $latestDisk = $disks | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    $ageDays = [math]::Floor(((Get-Date) - $latestDisk.LastWriteTime).TotalDays)
    $isStale = $CleanupIfVhdStale -and ($ageDays -ge $VhdStaleDays)

    return [pscustomobject]@{
        Found         = $true
        Path          = $latestDisk.FullName
        LastWriteTime = $latestDisk.LastWriteTime
        AgeDays       = $ageDays
        IsStale       = $isStale
    }
}

function Get-UniqueMoveDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDestination
    )

    if (-not (Test-Path -LiteralPath $BaseDestination)) {
        return $BaseDestination
    }

    $parent = Split-Path -Path $BaseDestination -Parent
    $leaf = Split-Path -Path $BaseDestination -Leaf
    $counter = 1

    do {
        $candidate = Join-Path -Path $parent -ChildPath ('{0}_{1:000}' -f $leaf, $counter)
        $counter++
    } while (Test-Path -LiteralPath $candidate)

    return $candidate
}

function Invoke-ProfileDisposition {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Folder,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    switch ($ActionMode) {
        'Report' {
            Write-Log -Level 'ACTION' -Message ('Report only: {0} [{1}]' -f $Folder.FullName, $Reason)
        }

        'Move' {
            if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
                throw 'ActionMode is Move, but $ArchiveRoot is blank.'
            }

            $sourceLabel = Get-SanitizedPathLabel -Text $SourceRoot
            $accessibleArchiveRoot = Get-AccessiblePath -Path $ArchiveRoot
            $destinationParent = Join-Path -Path $accessibleArchiveRoot -ChildPath $sourceLabel
            $destinationBase = Join-Path -Path $destinationParent -ChildPath $Folder.Name
            $destination = Get-UniqueMoveDestination -BaseDestination $destinationBase

            Write-Log -Level 'ACTION' -Message ('Move: {0} -> {1} [{2}]' -f $Folder.FullName, $destination, $Reason)

            if (-not (Test-Path -LiteralPath $destinationParent)) {
                New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
            }

            Move-Item -LiteralPath $Folder.FullName -Destination $destination
        }

        'Delete' {
            Write-Log -Level 'ACTION' -Message ('Delete: {0} [{1}]' -f $Folder.FullName, $Reason)
            Remove-Item -LiteralPath $Folder.FullName -Recurse -Force
        }

        default {
            throw "Unsupported ActionMode: $ActionMode"
        }
    }
}

function Test-IsFolderEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $null -eq (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

# =========================
# Main
# =========================

if ($ActionMode -notin @('Report', 'Move', 'Delete')) {
    throw "ActionMode must be one of: Report, Move, Delete. Current value: $ActionMode"
}

if ($MultipleMatchMode -notin @('Skip', 'FirstMatch')) {
    throw "MultipleMatchMode must be one of: Skip, FirstMatch. Current value: $MultipleMatchMode"
}

if ($FolderNameFormat -notin @('UsernameOnly', 'UsernameSid', 'SidUsername', 'CustomPatterns')) {
    throw "FolderNameFormat must be one of: UsernameOnly, UsernameSid, SidUsername, CustomPatterns. Current value: $FolderNameFormat"
}

if ($VhdStaleDays -lt 0) {
    throw "VhdStaleDays must be 0 or greater. Current value: $VhdStaleDays"
}

if ($UseHydraServiceAccountForShares) {
    if ($null -eq $HydraShareCredential) {
        if (Get-Variable -Name 'Hydra_ServiceAccount_PSC' -Scope Global -ErrorAction SilentlyContinue) {
            $HydraShareCredential = $global:Hydra_ServiceAccount_PSC
        }
    }

    if ($null -eq $HydraShareCredential) {
        throw 'UseHydraServiceAccountForShares is enabled, but no credential was provided. Set $HydraShareCredential or define $global:Hydra_ServiceAccount_PSC.'
    }

    if ($HydraShareCredential -isnot [System.Management.Automation.PSCredential]) {
        throw 'UseHydraServiceAccountForShares is enabled, but $HydraShareCredential is not a PSCredential object.'
    }
}

$results = New-Object System.Collections.Generic.List[object]

Write-Log -Message ('Starting scan. ActionMode={0}; UseGlobalCatalog={1}' -f $ActionMode, $UseGlobalCatalog)

try {
    foreach ($root in $FslogixRoots) {
        $accessibleRoot = Get-AccessiblePath -Path $root

        if (-not (Test-Path -LiteralPath $accessibleRoot)) {
            Write-Log -Level 'WARN' -Message ('Root not found, skipping: {0}' -f $root)
            continue
        }

        Write-Log -Message ('Scanning root: {0}' -f $root)
        $folders = Get-ChildItem -LiteralPath $accessibleRoot -Directory -Force

        foreach ($folder in $folders) {
            if ($ExcludedFolderNames -contains $folder.Name) {
                Write-Log -Message ('Excluded folder name, skipping: {0}' -f $folder.FullName)
                continue
            }

            if ($SkipEmptyFolders -and (Test-IsFolderEmpty -Path $folder.FullName)) {
                Write-Log -Message ('Empty folder skipped: {0}' -f $folder.FullName)
                continue
            }

            $resolvedUser = Get-ResolvedUserFromFolderName -FolderName $folder.Name
            if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
                Write-Log -Level 'WARN' -Message ('Could not resolve user from folder name: {0}' -f $folder.FullName)

                $results.Add([pscustomobject]@{
                    Root            = $root
                    FolderPath      = $folder.FullName
                    FolderName      = $folder.Name
                    ResolvedUser    = $null
                    AdStatus        = 'UnresolvedFolderName'
                    VhdFound        = $null
                    VhdPath         = $null
                    VhdLastWriteTime = $null
                    VhdAgeDays      = $null
                    VhdIsStale      = $null
                    MatchCount      = $null
                    Distinguished   = $null
                    ActionTriggered = $false
                    ActionReason    = $null
                })

                continue
            }

            Write-VerboseLog -Message ('Folder "{0}" resolved to identity "{1}"' -f $folder.FullName, $resolvedUser)
            $adUser = Get-AdUserByIdentity -Identity $resolvedUser
            $vhdInfo = Get-LatestProfileDiskInfo -FolderPath $folder.FullName
            $actionTriggered = $false
            $actionReason = $null

            if ($vhdInfo.Found) {
                Write-VerboseLog -Message ('Latest profile disk for "{0}": path={1}; lastWriteTime={2}; ageDays={3}; stale={4}' -f $folder.FullName, $vhdInfo.Path, $vhdInfo.LastWriteTime, $vhdInfo.AgeDays, $vhdInfo.IsStale)
            }
            else {
                Write-VerboseLog -Message ('No VHD/VHDX found under "{0}"' -f $folder.FullName)
            }

            switch ($adUser.Status) {
                'Missing' {
                    $actionTriggered = $true
                    $actionReason = 'AD user not found'
                }

                'MultipleMatches' {
                    Write-Log -Level 'WARN' -Message ('Multiple AD matches for "{0}" from folder {1}; skipping action.' -f $resolvedUser, $folder.FullName)
                }
            }

            if (-not $actionTriggered -and $vhdInfo.IsStale) {
                $actionTriggered = $true
                $actionReason = 'Profile disk is stale'
            }

            Write-VerboseLog -Message ('Decision for folder "{0}": adStatus={1}; vhdFound={2}; vhdAgeDays={3}; vhdIsStale={4}; actionTriggered={5}; actionReason={6}' -f $folder.FullName, $adUser.Status, $vhdInfo.Found, $vhdInfo.AgeDays, $vhdInfo.IsStale, $actionTriggered, $actionReason)

            if ($actionTriggered) {
                Invoke-ProfileDisposition -Folder $folder -Reason $actionReason -SourceRoot $root
            }

            $results.Add([pscustomobject]@{
                Root            = $root
                FolderPath      = $folder.FullName
                FolderName      = $folder.Name
                ResolvedUser    = $resolvedUser
                AdStatus        = $adUser.Status
                VhdFound        = $vhdInfo.Found
                VhdPath         = $vhdInfo.Path
                VhdLastWriteTime = $vhdInfo.LastWriteTime
                VhdAgeDays      = $vhdInfo.AgeDays
                VhdIsStale      = $vhdInfo.IsStale
                MatchCount      = $adUser.MatchCount
                Distinguished   = $adUser.Distinguished
                ActionTriggered = $actionTriggered
                ActionReason    = $actionReason
            })
        }
    }
}
finally {
    Remove-AuthenticatedShareMappings
}

if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
    $csvDir = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDir) -and -not (Test-Path -LiteralPath $csvDir)) {
        New-Item -Path $csvDir -ItemType Directory -Force | Out-Null
    }

    $results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation
    Write-Log -Message ('CSV report written to: {0}' -f $CsvPath)
}

$summary = $results | Group-Object -Property AdStatus | Sort-Object -Property Name
foreach ($item in $summary) {
    Write-Log -Message ('Summary: {0} = {1}' -f $item.Name, $item.Count)
}

$actions = @($results | Where-Object { $_.ActionTriggered }).Count
Write-Log -Message ('Completed. Profiles evaluated={0}; Actions flagged={1}' -f $results.Count, $actions)
