# Automatically Creates the Service Principal with all graph permissions, custom roles, and applies permissions to the given sub or RG.

# Example Usage for RG: Add-HydraTenantServicePrincipal -tenantId 1234-1234-1234-1234 -ScopeType ResourceGroup -SubscriptionId 1234-1234-1234-1234 -ResourceGroupName "RGName" -ApplyConstrainedRoleAssignmentCondition -ConfigureGraphApplicationPermissions -ServicePrincipalDisplayName "svc-Hydra"
# Example Usage for sub: Add-HydraTenantServicePrincipal -tenantId 1234-1234-1234-1234 -ScopeType Subscription -SubscriptionId 1234-1234-1234-1234 -ApplyConstrainedRoleAssignmentCondition -ConfigureGraphApplicationPermissions -ServicePrincipalDisplayName "svc-Hydra"

# Requires Az.Accounts, Az.Resources, Microsoft.Graph.Authentication, and Microsoft.Graph.Applications
# Run Install-Module Az.Accounts,Az.Resources,Microsoft.Graph.Authentication,Microsoft.Graph.Applications -Scope CurrentUser
# WARNING IF USING PS 5.1 - there is currently a known bug with the Microsoft.Graph.Authentication module v2.34. Rollback to 2.33 if you get a GetTokenAsync error.
# See here for more details: https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3479

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Subscription","ResourceGroup")]
    [string]$ScopeType,

    # If ScopeType=Subscription, provide SubscriptionId (or it will prompt/select current)
    [string]$SubscriptionId,

    # If ScopeType=ResourceGroup, provide both SubscriptionId and ResourceGroupName
    [string]$ResourceGroupName,

    [string]$ServicePrincipalDisplayName = "svc-Hydra",

    [string]$HydraRolesArmTemplateUrl = "https://raw.githubusercontent.com/MarcelMeurer/WVD-Hydra/refs/heads/main/Hydra-CustomRoles.json",

    # RBAC roles Hydra will assign to OTHER principals (role-assignment condition feature).
    
    [string[]]$ConstrainAssignableRoles = @(
        "Desktop Virtualization User",
        "Virtual Machine User Login",
        "Virtual Machine Administrator Login",
        "Desktop Virtualization Power On Off Contributor"
    ),

    [switch]$ApplyConstrainedRoleAssignmentCondition,

    # Adds Graph APPLICATION permissions and grants admin consent via app role assignments
    [switch]$ConfigureGraphApplicationPermissions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host "==== $title ====" -ForegroundColor Cyan
}

function Ensure-Module([string]$name) {
    if (-not (Get-Module -ListAvailable -Name $name)) {
        throw "Missing module '$name'. Install it first (Install-Module $name)."
    }
    Import-Module $name -ErrorAction Stop
}

function Download-Json([string]$url) {
    $tmp = Join-Path $env:TEMP ("hydra_roles_{0}.json" -f ([Guid]::NewGuid().ToString("N")))
    Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $tmp
    return $tmp
}

function Extract-RoleResourcesFromArmTemplate([object]$arm) {
    # Expecting ARM template with .resources[] where type == Microsoft.Authorization/roleDefinitions
    if ($null -eq $arm.resources) { return @() }

    $roleRes = @()
    foreach ($r in $arm.resources) {
        if ($null -ne $r.type -and $r.type -eq "Microsoft.Authorization/roleDefinitions") {
            $roleRes += $r
        }
    }
    return $roleRes
}

function Convert-ArmRoleResourceToRoleDefinitionJson(
    [object]$roleResource,
    [string]$scopeId
) {
    # ARM roleDefinition resource shape:
    # name: <guid>
    # properties: { roleName, description, permissions:[{actions,notActions,dataActions,notDataActions}], assignableScopes:[...] }
    $guid = [string]$roleResource.name
    if ([string]::IsNullOrWhiteSpace($guid)) { throw "Role resource missing .name (GUID)." }

    $p = $roleResource.properties
    if ($null -eq $p) { throw "Role resource '$guid' missing .properties." }

    $roleName = [string]$p.roleName
    if ([string]::IsNullOrWhiteSpace($roleName)) { throw "Role resource '$guid' missing properties.roleName." }

    $desc = [string]$p.description

    $perm0 = $null
    if ($null -ne $p.permissions -and $p.permissions.Count -ge 1) { $perm0 = $p.permissions[0] }
    if ($null -eq $perm0) { throw "Role '$roleName' missing permissions[0]." }

    $actions     = @(); if ($null -ne $perm0.actions)     { $actions     = @($perm0.actions) }
    $notActions  = @(); if ($null -ne $perm0.notActions)  { $notActions  = @($perm0.notActions) }
    $dataActions = @(); if ($null -ne $perm0.dataActions) { $dataActions = @($perm0.dataActions) }
    $notDataActions = @(); if ($null -ne $perm0.notDataActions) { $notDataActions = @($perm0.notDataActions) }

    # Force assignableScopes to the scope you are deploying to, plus keep any existing scopes if you want.
    # Hydra generally needs assignableScopes to include where you assign the role.
    $assignable = @($scopeId)

    $roleDef = [ordered]@{
    Name            = $roleName
    Id              = $guid
    IsCustom        = $true
    Description     = $desc
    Actions         = $actions
    NotActions      = $notActions
    DataActions     = $dataActions
    NotDataActions  = $notDataActions
    AssignableScopes= $assignable
}


    return @{
        RoleName = $roleName
        Guid     = $guid
        RoleDef  = $roleDef
    }
}

function Get-ScopeId([string]$scopeType, [string]$subId, [string]$rgName) {
    if ($scopeType -eq "Subscription") {
        return "/subscriptions/$subId"
    }
    return "/subscriptions/$subId/resourceGroups/$rgName"
}

function Try-GetRoleDefinitionByName([string]$roleName) {
    try {
        return Get-AzRoleDefinition -Name $roleName -ErrorAction Stop
    } catch {
        return $null
    }
}

function Ensure-CustomRole([hashtable]$converted) {
    $roleName = $converted.RoleName
    $existing = Try-GetRoleDefinitionByName -roleName $roleName
    if ($null -ne $existing) {
        Write-Host "Exists: $roleName" -ForegroundColor Yellow
        return $existing
    }

    $tmp = Join-Path $env:TEMP ("roledef_{0}.json" -f ([Guid]::NewGuid().ToString("N")))
    ($converted.RoleDef | ConvertTo-Json -Depth 20) | Out-File -FilePath $tmp -Encoding utf8

    New-AzRoleDefinition -InputFile $tmp | Out-Null
    Write-Host "Created: $roleName" -ForegroundColor Green

    return (Get-AzRoleDefinition -Name $roleName)
}

function Ensure-ServicePrincipal([string]$displayName) {
    $sp = $null
    try {
        $sp = Get-AzADServicePrincipal -DisplayName $displayName -ErrorAction Stop
    } catch { $sp = $null }

    if ($null -eq $sp) {
        $sp = New-AzADServicePrincipal -DisplayName $displayName
        Write-Host "Created Service Principal: $displayName" -ForegroundColor Green
    } else {
        Write-Host "Service Principal already exists: $displayName" -ForegroundColor Yellow
    }
    return $sp
}

function Ensure-SpSecret([string]$spObjectId) {
    # Create a new client secret (password credential). Output value.
    $end  = (Get-Date).AddYears(2)
    $cred = New-AzADSpCredential -ObjectId $spObjectId -EndDate $end

    return [pscustomobject]@{
        SecretValue = $cred.SecretText   # This is what Hydra needs - what's crazy is it does not match the value in Azure Portal
        SecretId    = $cred.KeyId        
        Expires     = $end
    }
}

function Ensure-RoleAssignment([string]$objectId, [string]$roleName, [string]$scopeId, [string]$condition, [string]$conditionVersion) {
    $rd = Get-AzRoleDefinition -Name $roleName -ErrorAction Stop

    $existing = Get-AzRoleAssignment -ObjectId $objectId -Scope $scopeId -RoleDefinitionId $rd.Id -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Host "Already assigned: $roleName" -ForegroundColor Yellow
        return
    }

    $params = @{
        ObjectId          = $objectId
        RoleDefinitionId  = $rd.Id
        Scope             = $scopeId
    }

    if (-not [string]::IsNullOrWhiteSpace($condition)) {
        $params["Condition"] = $condition
        $params["ConditionVersion"] = $conditionVersion
    }

    New-AzRoleAssignment @params | Out-Null
    Write-Host "Assigned: $roleName" -ForegroundColor Green
}



function Build-ConstrainRoleAssignmentCondition([string[]]$roleNames, [string]$scopeId) {
    # Portal-style "Constrain roles" condition:
    # - Allow everything except roleAssignments/write
    # - For roleAssignments/write, only allow assigning specific RoleDefinitionId GUIDs

    $guids = @()

    foreach ($rn in $roleNames) {
        $rd = Get-AzRoleDefinition -Name $rn -ErrorAction Stop

        # $rd.Id is usually:
        # /subscriptions/<sub>/providers/Microsoft.Authorization/roleDefinitions/<guid>
        # Extract the GUID only (portal condition uses GuidEquals <guid>)
        $m = [regex]::Match($rd.Id, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
        if (-not $m.Success) {
            throw "Could not extract role definition GUID from Id: $($rd.Id) for role '$rn'"
        }

        $guids += $m.Groups[1].Value.ToLowerInvariant()
    }

    if ($guids.Count -lt 1) {
        throw "No roles provided to constrain."
    }

    $orBlock = ($guids | ForEach-Object {
        "  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] GuidEquals $_"
    }) -join "`n  OR`n"

    $cond = @"
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
$orBlock
 )
)
"@.Trim()

    return $cond
}



function Ensure-GraphAppPermissionsAndConsent([string]$tenantId, [string]$appId) {
    Write-Section "Configure Microsoft Graph application permissions + admin consent"

    Ensure-Module "Microsoft.Graph.Authentication"
    Ensure-Module "Microsoft.Graph.Applications"
   

    $scopes = @(
        "Application.ReadWrite.All",
        "Directory.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All"
    )

    Connect-MgGraph -TenantId $tenantId -Scopes $scopes | Out-Null

    $app = Get-MgApplication -Filter "appId eq '$appId'"
    if ($null -eq $app) { throw "Could not find MgApplication for appId $appId" }

    $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
    if ($null -eq $graphSp) { throw "Could not find Microsoft Graph service principal in tenant." }

    # Graph permissions required
    $needed = @(
        "Group.Read.All",
        "User.Read.All",
        "CloudPC.ReadWrite.All"
    )

    $appRoleIds = @()
    foreach ($perm in $needed) {
        $role = $graphSp.AppRoles | Where-Object {
            $_.Value -eq $perm -and ($_.AllowedMemberTypes -contains "Application")
        } | Select-Object -First 1

        if ($null -eq $role) {
            throw "Could not resolve Graph app role for permission '$perm' (Application)."
        }
        $appRoleIds += $role.Id
    }

    # Update requiredResourceAccess on the application
    $req = @(
        @{
            ResourceAppId = "00000003-0000-0000-c000-000000000000"
            ResourceAccess = @(
                $appRoleIds | ForEach-Object { @{ Id = $_; Type = "Role" } }
            )
        }
    )

    Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess $req
    Write-Host "Set requiredResourceAccess on application." -ForegroundColor Green

    # Grant admin consent by appRoleAssignments on the service principal for this app
    $mySp = Get-MgServicePrincipal -Filter "appId eq '$appId'"
    if ($null -eq $mySp) { throw "Could not find ServicePrincipal for appId $appId" }

    foreach ($rid in $appRoleIds) {
        try {
            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $mySp.Id `
                -PrincipalId $mySp.Id `
                -ResourceId $graphSp.Id `
                -AppRoleId $rid | Out-Null

            Write-Host "Granted admin consent for app role id: $rid" -ForegroundColor Green
        } catch {
            # If it already exists, Graph may throw an error; continue anyway
            Write-Host "Admin consent failed - likely permissions or consent already present for app role id: $rid" -ForegroundColor Yellow
        }
    }

    # Output resolved permissions
    Write-Host ""
    Write-Host "Graph application permissions configured:" -ForegroundColor Cyan
    foreach ($p in $needed) { Write-Host " - $p" }
}

# --- Load Az modules ---
Write-Section "Load modules"
Ensure-Module "Az.Accounts"
Ensure-Module "Az.Resources"

# --- Auth & scope selection ---
Write-Section "Authenticate (Az) and determine scope"
Connect-AzAccount -Tenant $TenantId | Out-Null

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    # Let user pick if multiple; Az will prompt
    $ctx = Get-AzContext
    if ($null -eq $ctx -or [string]::IsNullOrWhiteSpace($ctx.Subscription.Id)) {
        throw "No subscription selected. Re-run and select a subscription."
    }
    $SubscriptionId = $ctx.Subscription.Id
} else {
    Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null
}

if ($ScopeType -eq "ResourceGroup") {
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "ScopeType=ResourceGroup requires -ResourceGroupName."
    }
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
}

$scopeId = Get-ScopeId -scopeType $ScopeType -subId $SubscriptionId -rgName $ResourceGroupName
Write-Host "Scope: $scopeId"

# --- Download ARM template and extract roles ---
Write-Section "Download Hydra custom roles ARM template"
$templatePath = Download-Json -url $HydraRolesArmTemplateUrl
$arm = Get-Content -Raw -Path $templatePath | ConvertFrom-Json

$roleResources = Extract-RoleResourcesFromArmTemplate -arm $arm
Write-Host ("Role definition resources found in template: {0}" -f $roleResources.Count)

if ($roleResources.Count -lt 1) {
    throw "No Microsoft.Authorization/roleDefinitions resources found in the ARM template."
}

# --- Create roles if missing ---
Write-Section "Create custom roles if missing"
$createdOrFoundRoles = @()
foreach ($rr in $roleResources) {
    $converted = Convert-ArmRoleResourceToRoleDefinitionJson -roleResource $rr -scopeId $scopeId
    $rd = Ensure-CustomRole -converted $converted
    $createdOrFoundRoles += $rd
}

# --- Create/Get SP + secret ---
Write-Section "Create or reuse Service Principal + client secret"
$sp = Ensure-ServicePrincipal -displayName $ServicePrincipalDisplayName

# App registration object (different from enterprise app object)
$app = Get-AzADApplication -ApplicationId $sp.AppId -ErrorAction Stop

$secret = Ensure-SpSecret -spObjectId $sp.Id

Write-Host ""
Write-Host "SERVICE PRINCIPAL OUTPUT FOR HYDRA (copy this):" -ForegroundColor Cyan
Write-Host ("TenantId                : {0}" -f $TenantId)
Write-Host ("ApplicationId           : {0}" -f $sp.AppId)
Write-Host ("SecretValue             : {0}" -f $secret.SecretValue)
Write-Host ("SecretExpires           : {0}" -f $secret.Expires)
Write-Host ""
Write-Host ("Scope                   : {0}" -f $scopeId)


# --- Assign RBAC roles to SP ---
Write-Section "Assign RBAC roles at scope"
# Names as defined in the ARM template:
$hydraRoleNames = @(
    "Hydra - Resource Access Role",
    "Hydra - Change Permissions Role"
)

# Optional constrained role assignment condition (applies to the Change Permissions role assignment)
$condition = $null
$conditionVersion = "2.0"

if ($ApplyConstrainedRoleAssignmentCondition) {
    $condition = Build-ConstrainRoleAssignmentCondition -roleNames $ConstrainAssignableRoles -scopeId $scopeId
    Write-Host "Role assignment condition will be applied to: Hydra - Change Permissions Role"
    Write-Host "Condition:"
    Write-Host $condition
    Write-Host ""
} else {
    Write-Host "Role assignment condition: not applied (use -ApplyConstrainedRoleAssignmentCondition to enable)." -ForegroundColor Yellow
}

foreach ($rName in $hydraRoleNames) {
    if ($rName -eq "Hydra - Change Permissions Role" -and -not [string]::IsNullOrWhiteSpace($condition)) {
        try {
            Ensure-RoleAssignment -objectId $sp.Id -roleName $rName -scopeId $scopeId -condition $condition -conditionVersion $conditionVersion
        } catch {
            Write-Host "Failed assigning '$rName' WITH condition. Azure said BadRequest? Then your tenant/scope likely doesn't support conditions via Az yet." -ForegroundColor Red
            Write-Host "Retrying assignment WITHOUT condition..." -ForegroundColor Yellow
            Ensure-RoleAssignment -objectId $sp.Id -roleName $rName -scopeId $scopeId -condition $null -conditionVersion $null
        }
    } else {
        Ensure-RoleAssignment -objectId $sp.Id -roleName $rName -scopeId $scopeId -condition $null -conditionVersion $null
    }
}

# --- Optional Graph permissions ---
if ($ConfigureGraphApplicationPermissions) {
    Ensure-GraphAppPermissionsAndConsent -tenantId $TenantId -appId $sp.AppId
} else {
    Write-Section "Graph application permissions"
    Write-Host "Skipped. Re-run with -ConfigureGraphApplicationPermissions if you want the Graph app perms + admin consent set automatically." -ForegroundColor Yellow
}


Write-Section "Done"
