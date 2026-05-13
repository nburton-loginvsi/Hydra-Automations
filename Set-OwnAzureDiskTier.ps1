#requires -Version 5.1

<#
    Sets an Azure VM's managed disk performance tier.

    In Self mode, the script uses Azure Instance Metadata Service (IMDS) to
    identify the current VM from inside the guest OS. In Named mode, it targets
    the VM named in the variables block. It authenticates to Azure Resource
    Manager with the Hydra service account PSCredential, finds the managed disk,
    and updates its performance tier.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================
# Variables only edit zone
# =========================

# Desired disk performance tier. Examples: P10, P20, P30, P40, P50.
$TargetDiskTier = 'P20'

# VM targeting mode. Valid values:
# - Self  -> discover the VM this script is running inside by using Azure IMDS.
# - Named -> use the explicit VM variables below.
$TargetVmMode = 'Self'

# Used only when $TargetVmMode = 'Named'.
$TargetSubscriptionId = ''
$TargetResourceGroupName = ''
$TargetVmName = ''

# Tenant ID for the service principal stored in $global:Hydra_ServiceAccount_PSC.
# Required for client_credentials authentication.
$TenantId = ''

# Disk to update. Valid values:
# - OS
# - Data
$DiskKind = 'OS'

# Used only when $DiskKind = 'Data'.
$DataDiskLun = 0

# Set to $true to print the planned change without sending the PATCH request.
$WhatIf = $false

# Azure public cloud endpoints.
$AzureAuthorityHost = 'https://login.microsoftonline.com'
$AzureResourceManagerEndpoint = 'https://management.azure.com'

# REST API versions.
$ImdsApiVersion = '2021-02-01'
$VmApiVersion = '2023-09-01'
$DiskApiVersion = '2023-10-02'

# How long to wait for Azure to report the disk update as complete.
$PollIntervalSeconds = 10
$PollTimeoutSeconds = 600

# Use the Hydra PSCredential object. UserName must be the service principal app/client ID.
# $HydraCredential = $global:Hydra_ServiceAccount_PSC
$HydraCredential = Get-Credential

# =========================
# Script logic below
# =========================

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

function Assert-Configuration {
    if (-not $HydraCredential) {
        throw 'Hydra credential was not found. Define $global:Hydra_ServiceAccount_PSC before running this script.'
    }

    if ($TenantId -eq '00000000-0000-0000-0000-000000000000' -or [string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'Set $TenantId in the variables block before running this script.'
    }

    if ($TargetDiskTier -notmatch '^P\d+$') {
        throw "TargetDiskTier must look like P10, P20, P30, etc. Current value: '$TargetDiskTier'."
    }

    if ($TargetVmMode -notin @('Self', 'Named')) {
        throw "TargetVmMode must be 'Self' or 'Named'. Current value: '$TargetVmMode'."
    }

    if ($TargetVmMode -eq 'Named') {
        if ([string]::IsNullOrWhiteSpace($TargetSubscriptionId)) {
            throw "Set `$TargetSubscriptionId when TargetVmMode is 'Named'."
        }

        if ([string]::IsNullOrWhiteSpace($TargetResourceGroupName)) {
            throw "Set `$TargetResourceGroupName when TargetVmMode is 'Named'."
        }

        if ([string]::IsNullOrWhiteSpace($TargetVmName)) {
            throw "Set `$TargetVmName when TargetVmMode is 'Named'."
        }
    }

    if ($DiskKind -notin @('OS', 'Data')) {
        throw "DiskKind must be 'OS' or 'Data'. Current value: '$DiskKind'."
    }

    if ($DiskKind -eq 'Data' -and $DataDiskLun -lt 0) {
        throw 'DataDiskLun must be 0 or greater.'
    }
}

function ConvertTo-JsonBody {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $InputObject | ConvertTo-Json -Depth 20 -Compress
}

function Get-ArmAccessToken {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $clientSecret = Get-PlainTextPassword -Credential $Credential
    $tokenUri = "$AzureAuthorityHost/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id     = $Credential.UserName
        client_secret = $clientSecret
        grant_type    = 'client_credentials'
        scope         = "$AzureResourceManagerEndpoint/.default"
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    finally {
        $clientSecret = $null
    }

    if (-not $response.access_token) {
        throw 'Azure AD token response did not contain an access_token.'
    }

    $response.access_token
}

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [object]$Body
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
    }

    $request = @{
        Method          = $Method
        Uri             = $Uri
        Headers         = $headers
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = ConvertTo-JsonBody -InputObject $Body
        $request.ContentType = 'application/json'
    }

    try {
        $response = Invoke-WebRequest @request
    }
    catch {
        $webResponse = $_.Exception.Response
        if (-not $webResponse) {
            throw
        }

        $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
        $details = $reader.ReadToEnd()
        throw "Azure ARM request failed. Method: $Method. Uri: $Uri. Status: $([int]$webResponse.StatusCode) $($webResponse.StatusDescription). Details: $details"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    $response.Content | ConvertFrom-Json
}

function Get-InstanceMetadata {
    $uri = "http://169.254.169.254/metadata/instance?api-version=$ImdsApiVersion"

    Invoke-RestMethod `
        -Method Get `
        -Uri $uri `
        -Headers @{ Metadata = 'true' } `
        -TimeoutSec 10 `
        -ErrorAction Stop
}

function Join-ArmUri {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$ApiVersion
    )

    "$AzureResourceManagerEndpoint$ResourceId`?api-version=$ApiVersion"
}

function Get-CurrentVm {
    param(
        [Parameter(Mandatory)]
        [object]$Metadata,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $subscriptionId = $Metadata.compute.subscriptionId
    $resourceGroupName = $Metadata.compute.resourceGroupName
    $vmName = $Metadata.compute.name

    if (-not $subscriptionId -or -not $resourceGroupName -or -not $vmName) {
        throw 'IMDS response did not include subscriptionId, resourceGroupName, and VM name.'
    }

    $encodedResourceGroup = [Uri]::EscapeDataString($resourceGroupName)
    $encodedVmName = [Uri]::EscapeDataString($vmName)
    $vmResourceId = "/subscriptions/$subscriptionId/resourceGroups/$encodedResourceGroup/providers/Microsoft.Compute/virtualMachines/$encodedVmName"
    $vmUri = Join-ArmUri -ResourceId $vmResourceId -ApiVersion $VmApiVersion

    Write-Host "Discovered VM from IMDS: $vmName"
    Write-Host "  Resource group: $resourceGroupName"
    Write-Host "  Subscription:   $subscriptionId"

    Invoke-ArmRequest -Method GET -Uri $vmUri -AccessToken $AccessToken
}

function Get-NamedVm {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $encodedResourceGroup = [Uri]::EscapeDataString($TargetResourceGroupName)
    $encodedVmName = [Uri]::EscapeDataString($TargetVmName)
    $vmResourceId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$encodedResourceGroup/providers/Microsoft.Compute/virtualMachines/$encodedVmName"
    $vmUri = Join-ArmUri -ResourceId $vmResourceId -ApiVersion $VmApiVersion

    Write-Host "Using named VM target: $TargetVmName"
    Write-Host "  Resource group: $TargetResourceGroupName"
    Write-Host "  Subscription:   $TargetSubscriptionId"

    Invoke-ArmRequest -Method GET -Uri $vmUri -AccessToken $AccessToken
}

function Get-TargetManagedDiskId {
    param(
        [Parameter(Mandatory)]
        [object]$Vm
    )

    if ($DiskKind -eq 'OS') {
        $diskId = $Vm.properties.storageProfile.osDisk.managedDisk.id
        if (-not $diskId) {
            throw 'The current VM OS disk is not a managed disk or the disk ID could not be read.'
        }

        return $diskId
    }

    $matchingDisk = @($Vm.properties.storageProfile.dataDisks | Where-Object { $_.lun -eq $DataDiskLun }) | Select-Object -First 1
    if (-not $matchingDisk) {
        throw "No data disk with LUN $DataDiskLun was found on this VM."
    }

    if (-not $matchingDisk.managedDisk.id) {
        throw "Data disk LUN $DataDiskLun is not a managed disk or the disk ID could not be read."
    }

    $matchingDisk.managedDisk.id
}

function Wait-DiskProvisioning {
    param(
        [Parameter(Mandatory)]
        [string]$DiskUri,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $deadline = (Get-Date).AddSeconds($PollTimeoutSeconds)

    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $disk = Invoke-ArmRequest -Method GET -Uri $DiskUri -AccessToken $AccessToken
        $state = $disk.properties.provisioningState

        Write-Host "Disk provisioning state: $state"

        if ($state -eq 'Succeeded') {
            return $disk
        }

        if ($state -eq 'Failed') {
            throw 'Azure reported that the disk update failed.'
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for disk update after $PollTimeoutSeconds seconds."
}

Assert-Configuration

Write-Host "Authenticating to Azure Resource Manager with Hydra service principal credential."
$accessToken = Get-ArmAccessToken -Credential $HydraCredential

if ($TargetVmMode -eq 'Self') {
    Write-Host 'Reading Azure Instance Metadata Service.'
    $metadata = Get-InstanceMetadata
    $vm = Get-CurrentVm -Metadata $metadata -AccessToken $accessToken
}
else {
    $vm = Get-NamedVm -AccessToken $accessToken
}

$diskId = Get-TargetManagedDiskId -Vm $vm
$diskUri = Join-ArmUri -ResourceId $diskId -ApiVersion $DiskApiVersion
$disk = Invoke-ArmRequest -Method GET -Uri $diskUri -AccessToken $accessToken

$currentTier = $disk.properties.tier
$diskName = $disk.name

Write-Host "Target disk: $diskName"
Write-Host "  Resource ID:  $diskId"
Write-Host "  Current tier: $currentTier"
Write-Host "  Target tier:  $TargetDiskTier"

if ($currentTier -eq $TargetDiskTier) {
    Write-Host "Disk '$diskName' is already set to tier '$TargetDiskTier'. No change needed."
    return
}

if ($WhatIf) {
    Write-Host "WhatIf enabled. Would update disk '$diskName' to tier '$TargetDiskTier'."
    return
}

$patchBody = @{
    properties = @{
        tier = $TargetDiskTier
    }
}

Write-Host "Updating disk '$diskName' to tier '$TargetDiskTier'."
[void](Invoke-ArmRequest -Method PATCH -Uri $diskUri -AccessToken $accessToken -Body $patchBody)
$updatedDisk = Wait-DiskProvisioning -DiskUri $diskUri -AccessToken $accessToken

Write-Host "Disk '$($updatedDisk.name)' tier update complete."
Write-Host "  New tier: $($updatedDisk.properties.tier)"
