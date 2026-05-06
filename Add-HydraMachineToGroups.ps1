# =========================
# Variables only edit zone
# =========================

# self-fetch domain FQDN (or define it manually here)
$DomainFqdn = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name

# User, computer, or service account to add (or self-fetch it here)
# For computers, the real sAMAccountName usually has a trailing $, e.g. "PC123$".
# If the trailing $ is omitted here, the script will retry the target lookup with it.

$TargetSamAccountName = "$env:COMPUTERNAME`$"

# groups to add the account to
$GroupSamAccountNames = @(
    "Group-One",
    "Group-Two",
    "Group-Three"
)

# Use the Hydra PSCredential object.

$HydraCredential = $global:Hydra_ServiceAccount_PSC

# =========================
# Script logic below
# =========================

function ConvertTo-LdapFilterValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $Value `
        -replace '\\', '\5c' `
        -replace '\*', '\2a' `
        -replace '\(', '\28' `
        -replace '\)', '\29' `
        -replace "`0", '\00'
}

function Get-PlainTextPassword {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function New-LdapEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $password = Get-PlainTextPassword -Credential $Credential

    New-Object System.DirectoryServices.DirectoryEntry(
        $Path,
        $Credential.UserName,
        $password,
        [System.DirectoryServices.AuthenticationTypes]::Secure
    )
}

function Format-SearchDiagnostic {
    param(
        [Parameter(Mandatory)]
        [string]$ObjectLabel,

        [Parameter(Mandatory)]
        [string]$SamAccountName,

        [Parameter(Mandatory)]
        [string]$SearchPath,

        [Parameter(Mandatory)]
        [string]$Filter,

        [string]$ExtraHint
    )

    $message = @(
        "Could not find $ObjectLabel with sAMAccountName '$SamAccountName'.",
        "LDAP search path: $SearchPath",
        "LDAP filter: $Filter",
        "Search scope: Subtree"
    )

    if ($ExtraHint) {
        $message += "Hint: $ExtraHint"
    }

    $message -join [Environment]::NewLine
}

function Find-AdObjectBySam {
    param(
        [Parameter(Mandatory)]
        [string]$SamAccountName,

        [Parameter(Mandatory)]
        [System.DirectoryServices.DirectoryEntry]$SearchRoot,

        [string]$ObjectLabel = "AD object",

        [switch]$RetryAsComputerAccount
    )

    $escapedSam = ConvertTo-LdapFilterValue -Value $SamAccountName

    $searcher = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $searcher.Filter = "(sAMAccountName=$escapedSam)"
    $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $searcher.PageSize = 1000
    [void]$searcher.PropertiesToLoad.Add("distinguishedName")
    [void]$searcher.PropertiesToLoad.Add("objectClass")
    [void]$searcher.PropertiesToLoad.Add("sAMAccountName")

    Write-Host "Searching for $ObjectLabel '$SamAccountName'"
    Write-Host "  Path:   $($SearchRoot.Path)"
    Write-Host "  Filter: $($searcher.Filter)"

    try {
        $result = $searcher.FindOne()
    }
    catch {
        $details = @(
            "LDAP search failed while looking for $ObjectLabel '$SamAccountName'.",
            "LDAP search path: $($SearchRoot.Path)",
            "LDAP filter: $($searcher.Filter)",
            "Error type: $($_.Exception.GetType().FullName)",
            "Error message: $($_.Exception.Message)"
        )

        throw ($details -join [Environment]::NewLine)
    }

    if (-not $result) {
        if ($RetryAsComputerAccount -and -not $SamAccountName.EndsWith('$')) {
            $computerSam = "$SamAccountName`$"
            Write-Warning "No match for '$SamAccountName'. Retrying target lookup as computer sAMAccountName '$computerSam'."

            return Find-AdObjectBySam `
                -SamAccountName $computerSam `
                -SearchRoot $SearchRoot `
                -ObjectLabel $ObjectLabel
        }

        $hint = if (-not $SamAccountName.EndsWith('$')) {
            "If this is a computer account, try '$SamAccountName`$'. AD stores computer sAMAccountName values with a trailing dollar sign."
        }
        else {
            $null
        }

        throw (Format-SearchDiagnostic `
            -ObjectLabel $ObjectLabel `
            -SamAccountName $SamAccountName `
            -SearchPath $SearchRoot.Path `
            -Filter $searcher.Filter `
            -ExtraHint $hint)
    }

    $foundDn = $result.Properties["distinguishedname"][0]
    $foundSam = $result.Properties["samaccountname"][0]
    $foundClasses = @($result.Properties["objectclass"]) -join ", "

    Write-Host "  Found:  $foundDn"
    Write-Host "  sAM:    $foundSam"
    Write-Host "  Class:  $foundClasses"

    $foundDn
}

function Test-DirectGroupMembership {
    param(
        [Parameter(Mandatory)]
        [System.DirectoryServices.DirectoryEntry]$GroupEntry,

        [Parameter(Mandatory)]
        [string]$TargetDistinguishedName
    )

    try {
        $GroupEntry.RefreshCache(@("member"))
    }
    catch {
        Write-Host "  Member cache: empty or unavailable before add ($($_.Exception.Message))"
        return $false
    }

    $memberProperty = $GroupEntry.psbase.Properties["member"]

    if (-not $memberProperty -or $memberProperty.Count -eq 0) {
        Write-Host "  Current members: 0"
        return $false
    }

    Write-Host "  Current members: $($memberProperty.Count)"

    foreach ($member in $memberProperty) {
        if ([string]::Equals($member, $TargetDistinguishedName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $false
}

if (-not $HydraCredential -or $HydraCredential.GetType().FullName -ne "System.Management.Automation.PSCredential") {
    throw '$HydraCredential must be a valid System.Management.Automation.PSCredential object.'
}

$ldapRoot = "LDAP://$DomainFqdn"
$rootEntry = New-LdapEntry -Path $ldapRoot -Credential $HydraCredential

$targetDn = Find-AdObjectBySam `
    -SamAccountName $TargetSamAccountName `
    -SearchRoot $rootEntry `
    -ObjectLabel "target account" `
    -RetryAsComputerAccount

foreach ($groupSam in $GroupSamAccountNames) {
    $groupDn = Find-AdObjectBySam `
        -SamAccountName $groupSam `
        -SearchRoot $rootEntry `
        -ObjectLabel "group"

    try {
        $groupPath = "LDAP://$DomainFqdn/$groupDn"
        Write-Host "Binding to group: $groupPath"
        $groupEntry = New-LdapEntry -Path $groupPath -Credential $HydraCredential

        if (Test-DirectGroupMembership -GroupEntry $groupEntry -TargetDistinguishedName $targetDn) {
            Write-Host "Already a member: $TargetSamAccountName -> $groupSam"
            continue
        }

        [void]$groupEntry.psbase.Properties["member"].Add($targetDn)
        $groupEntry.CommitChanges()
        Write-Host "Added: $TargetSamAccountName -> $groupSam"
    }
    catch {
        Write-Warning "Failed to add '$TargetSamAccountName' to '$groupSam': $($_.Exception.Message)"
    }
}
