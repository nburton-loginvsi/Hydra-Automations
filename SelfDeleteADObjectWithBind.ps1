param(
  [string]$Server,
  [switch]$UseSSL,
  [switch]$WhatIf
)

# Force WhatIf regardless of parameters (comment out as needed)
# $WhatIf = $true

# --- Required: your PSCredential in a global var ---
if (-not $global:Hydra_ServiceAccount_PSC -or `
    -not ($global:Hydra_ServiceAccount_PSC -is [System.Management.Automation.PSCredential])) {
  throw "Global variable 'Hydra_ServiceAccount_PSC' is not set to a PSCredential."
}

# Convenience
$UserName = $global:Hydra_ServiceAccount_PSC.UserName
$PlainPwd = $global:Hydra_ServiceAccount_PSC.GetNetworkCredential().Password

function Get-TargetServer {
  if ($Server) { return $Server }
  if ($env:LOGONSERVER) { return ($env:LOGONSERVER -replace '^[\\]+','') }
  if ($env:USERDNSDOMAIN) { return $env:USERDNSDOMAIN }
  throw "Unable to determine a domain controller. Specify -Server."
}

$Target = Get-TargetServer
Write-Host "Using server: $Target"
Write-Host "Bind account (credential): $UserName"

# Load assemblies
$ProtocolsLoaded = $false
try {
  Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
  $ProtocolsLoaded = $true
} catch {
  try {
    [void][Reflection.Assembly]::LoadWithPartialName("System.DirectoryServices.Protocols")
    if ([type]::GetType("System.DirectoryServices.Protocols.LdapConnection")) {
      $ProtocolsLoaded = $true
    }
  } catch { $ProtocolsLoaded = $false }
}
try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop } catch {}

# Helpers
function Get-RootDSEInfo {
  param([string]$Target,[string]$User,[string]$Pwd,[switch]$UseSSL)

  $rootPath = if ($UseSSL) { "LDAP://$Target:636/RootDSE" } else { "LDAP://$Target/RootDSE" }
  $root = New-Object System.DirectoryServices.DirectoryEntry($rootPath,$User,$Pwd)

  $null = $root.NativeObject  # force bind
  Write-Host "Bound successfully as: $User"

  $dnsHostName  = $root.Properties["dnsHostName"].Value
  $serverNameDN = $root.Properties["serverName"].Value
  if ($dnsHostName) {
    Write-Host ("Bound DC: {0}  (serverName DN: {1})" -f $dnsHostName, $serverNameDN)
  }

  $defaultNC = $root.Properties["defaultNamingContext"].Value
  if (-not $defaultNC) { throw "Could not read defaultNamingContext from RootDSE at $Target." }

  [pscustomobject]@{
    defaultNamingContext = $defaultNC
    dnsHostName          = $dnsHostName
    serverNameDN         = $serverNameDN
  }
}

function Get-ComputerDN {
  param([string]$BaseDN,[string]$Target,[string]$User,[string]$Pwd,[switch]$UseSSL)

  $basePath = if ($UseSSL) { "LDAP://$Target:636/$BaseDN" } else { "LDAP://$Target/$BaseDN" }
  $de = New-Object System.DirectoryServices.DirectoryEntry($basePath,$User,$Pwd)
  $null = $de.NativeObject  # force bind

  $ds = New-Object System.DirectoryServices.DirectorySearcher($de)
  $sam = "$($env:COMPUTERNAME)$"
  $ds.Filter = "(&(objectClass=computer)(sAMAccountName=$sam))"
  $ds.SearchScope = "Subtree"
  $ds.PropertiesToLoad.Clear()
  $ds.PropertiesToLoad.Add("distinguishedName") | Out-Null

  $res = $ds.FindAll()
  if ($res.Count -eq 0) { throw "Computer object not found for '$sam' in '$BaseDN'." }
  if ($res.Count -gt 1) { throw "Multiple computer objects found for '$sam'." }
  return $res[0].Properties["distinguishedname"][0]
}

function Delete-WithProtocols {
  param([string]$Target,[string]$DN,[string]$User,[string]$Pwd,[switch]$UseSSL)

  $ldap = New-Object System.DirectoryServices.Protocols.LdapConnection($Target)
  $ldap.SessionOptions.ProtocolVersion = 3
  $ldap.SessionOptions.Sealing = $true
  $ldap.SessionOptions.Signing  = $true
  if ($UseSSL) { $ldap.SessionOptions.SecureSocketLayer = $true }
  $ldap.AuthType  = [System.DirectoryServices.Protocols.AuthType]::Negotiate
  $ldap.Credential = New-Object System.Net.NetworkCredential($User,$Pwd)

  $ldap.Bind()
  $req = New-Object System.DirectoryServices.Protocols.DeleteRequest($DN)
  $resp = $ldap.SendRequest($req)
  if ($resp.ResultCode -ne [System.DirectoryServices.Protocols.ResultCode]::Success) {
    throw "LDAP delete failed: $($resp.ResultCode) - $($resp.ErrorMessage)"
  }
}

function Delete-WithDirectoryEntry {
  param([string]$Target,[string]$DN,[string]$User,[string]$Pwd,[switch]$UseSSL)

  $objPath = if ($UseSSL) { "LDAP://$Target:636/$DN" } else { "LDAP://$Target/$DN" }
  $obj = New-Object System.DirectoryServices.DirectoryEntry($objPath,$User,$Pwd)
  $null = $obj.NativeObject  # force bind

  $obj.DeleteTree()
  $obj.CommitChanges()
}

# --- Flow with automatic SSL failover ---
try {
  # First try RootDSE with the requested (or default) scheme
  try {
    $rootInfo = Get-RootDSEInfo -Target $Target -User $UserName -Pwd $PlainPwd -UseSSL:$UseSSL
  } catch {
    if (-not $UseSSL) {
      Write-Host "Plain LDAP bind failed — retrying with SSL (LDAPS:636)..."
      $rootInfo = Get-RootDSEInfo -Target $Target -User $UserName -Pwd $PlainPwd -UseSSL:$true
      $UseSSL = $true
      Write-Host "Switched to SSL for the remainder of the operation."
    } else {
      throw
    }
  }

  Write-Host "defaultNamingContext: $($rootInfo.defaultNamingContext)"

  # Search target DN using whichever transport is active now
  $dn = Get-ComputerDN -BaseDN $rootInfo.defaultNamingContext -Target $Target -User $UserName -Pwd $PlainPwd -UseSSL:$UseSSL
  Write-Host "Computer DN: $dn"

  if ($WhatIf) {
    Write-Host "[WhatIf] Would delete: $dn"
    return
  }

  if ($ProtocolsLoaded) {
    Write-Host ("Deleting via System.DirectoryServices.Protocols over {0}..." -f ($(if ($UseSSL) {"LDAPS"} else {"LDAP"})))
    try {
      Delete-WithProtocols -Target $Target -DN $dn -User $UserName -Pwd $PlainPwd -UseSSL:$UseSSL
    } catch {
      if (-not $UseSSL) {
        Write-Host "Delete over plain LDAP failed — retrying with SSL..."
        Delete-WithProtocols -Target $Target -DN $dn -User $UserName -Pwd $PlainPwd -UseSSL:$true
        $UseSSL = $true
        Write-Host "Switched to SSL for delete."
      } else {
        throw
      }
    }
  } else {
    Write-Host ("Deleting via System.DirectoryServices over {0}..." -f ($(if ($UseSSL) {"LDAPS"} else {"LDAP"})))
    try {
      Delete-WithDirectoryEntry -Target $Target -DN $dn -User $UserName -Pwd $PlainPwd -UseSSL:$UseSSL
    } catch {
      if (-not $UseSSL) {
        Write-Host "Delete over plain LDAP failed — retrying with SSL..."
        Delete-WithDirectoryEntry -Target $Target -DN $dn -User $UserName -Pwd $PlainPwd -UseSSL:$true
        $UseSSL = $true
        Write-Host "Switched to SSL for delete."
      } else {
        throw
      }
    }
  }

  Write-Host "Success: computer object deleted."
}
catch {
  Write-Host "Delete failed: $($_.Exception.Message)"
  if ($_.Exception.InnerException) {
    Write-Host "Inner: $($_.Exception.InnerException.Message)"
  }
}
