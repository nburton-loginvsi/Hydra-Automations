# ================== CONFIGURATION ==================
$LogName = "RemoteDesktopServices"
$SearchTerms      = @("Session Consolidation")  # Wildcards supported, e.g. "*auth*"
$RequireAll       = $false        # $true: all terms must match; $false: any term
$CaseSensitive    = $false        # $true uses -clike; $false uses -like

$IntervalSeconds  = 30            # Polling interval (seconds)
$Hours            = 8             # Total runtime (hours)
$SinceMinutes     = 5             # Initial lookback window (minutes)

$LogoffDelaySeconds = 900          # Countdown before logoff after a match
$WhatIf           = $false         # $true = DRY RUN: show who would be logged off, but don't logoff
$OutCsv           = ""  # "" to disable CSV writing
$Quiet            = $true         # $true = no console table output

# Optional: which session states to target for logoff (Active/Disc). Leave as-is for both.
$TargetStates     = @("Active","Disc")
# ===================================================

$ErrorActionPreference = 'Stop'

# --- Prep CSV if needed ---
if ($OutCsv -and -not [string]::IsNullOrWhiteSpace($OutCsv)) {
  $dir = Split-Path -Parent $OutCsv
  if ([string]::IsNullOrWhiteSpace($dir)) { $dir = "." }
  if (-not (Test-Path -Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  if (-not (Test-Path $OutCsv)) {
    @() | Select TimeCreated,ProviderName,Id,LevelDisplayName,RecordId,MachineName,Message |
      Export-Csv -Path $OutCsv -NoTypeInformation
  }
}

# --- Helper: wildcard message matcher (no regex) ---
function Test-MessageMatch {
  param(
    [Parameter(Mandatory=$true)][string]$Message
  )
  if (-not $Message) { return $false }

  $ops = if ($CaseSensitive) { '-clike' } else { '-like' }

  if ($RequireAll) {
    foreach ($t in $SearchTerms) {
      $pat = if ($t -match '[\*\?]') { $t } else { "*$t*" }
      if (-not (Invoke-Expression "`$Message $ops `"$pat`"")) { return $false }
    }
    return $true
  } else {
    foreach ($t in $SearchTerms) {
      $pat = if ($t -match '[\*\?]') { $t } else { "*$t*" }
      if (Invoke-Expression "`$Message $ops `"$pat`"") { return $true }
    }
    return $false
  }
}

# --- Helper: enumerate user sessions (quser parser) ---
function Get-UserSessions {
  # Uses 'quser' for reliability under SYSTEM/non-interactive contexts
  $raw = & quser 2>$null
  if (-not $raw) { return @() }

  $lines = $raw | Select-Object -Skip 1
  $sessions = @()

  foreach ($line in $lines) {
    # Normalize potential leading ">" for current session rows
    $clean = $line.Trim() -replace '^\>',''

    # Columns are space-aligned; collapse runs of whitespace
    $parts = $clean -replace '\s+',' ' -split ' '

    # Heuristic mapping:
    # USERNAME [0], SESSIONNAME [1] (may be "console" or "rdp-tcp#X"), ID [2], STATE [3], IDLE [4..-2], LOGON [last..]
    if ($parts.Count -ge 4) {
      $user  = $parts[0]
      $id    = $parts[2]
      $state = $parts[3]
      # Try to recover session name (may be blank in some edge cases)
      $sessName = $parts[1]

      # Only numeric IDs are valid for 'logoff'
      if ($id -match '^\d+$') {
        $sessions += [pscustomobject]@{
          UserName    = $user
          SessionId   = [int]$id
          State       = $state
          SessionName = $sessName
        }
      }
    }
  }

  return $sessions
}

# --- Helper: logoff users by SessionId ---
function Invoke-LogoffAllUsers {
  param(
    [Parameter(Mandatory=$true)][pscustomobject[]]$Sessions,
    [switch]$WhatIf
  )

  if (-not $Sessions -or $Sessions.Count -eq 0) {
    Write-Host "No sessions matched logoff criteria."
    return
  }

  Write-Host "Targets:" -ForegroundColor Yellow
  $Sessions | Sort-Object SessionId | Format-Table UserName,SessionName,State,SessionId -AutoSize
  Write-Host ""

  if ($WhatIf) {
    Write-Host "[WhatIf] Would logoff $($Sessions.Count) session(s)."
    return
  }

  foreach ($s in $Sessions) {
    try {
      Write-Host ("Logging off SessionId {0} ({1})..." -f $s.SessionId, $s.UserName)
      & logoff $s.SessionId /server:localhost 2>$null
    } catch {
      Write-Warning "Failed to logoff SessionId $($s.SessionId): $($_.Exception.Message)"
    }
  }
}

# --- Main watcher ---
$endTime      = (Get-Date).AddHours($Hours)
$lastStart    = (Get-Date).AddMinutes(-1 * [math]::Abs($SinceMinutes))
$lastRecordId = 0

Write-Host "== Watching log '$LogName'"
Write-Host "   Terms : $($SearchTerms -join ', ') (wildcard mode; CaseSensitive=$CaseSensitive; RequireAll=$RequireAll)"
Write-Host "   Every : $IntervalSeconds second(s) | For: $Hours hour(s)"
Write-Host "   Since : $lastStart (initial lookback)"
Write-Host "   Upon  : FIRST MATCH -> Delay $LogoffDelaySeconds s -> Logoff ALL user sessions (WhatIf=$WhatIf)"
if ($OutCsv) { Write-Host "   CSV   : $OutCsv" }
Write-Host ""

$matchedEvent = $null

while ((Get-Date) -lt $endTime) {
  try {
    $events = Get-WinEvent -FilterHashtable @{ LogName=$LogName; StartTime=$lastStart }

    if ($lastRecordId -gt 0) {
      $events = $events | Where-Object { $_.RecordId -gt $lastRecordId }
    }

    if ($events) {
      $events = $events | Sort-Object RecordId

      foreach ($ev in $events) {
        if (Test-MessageMatch -Message $ev.Message) {
          $matchedEvent = [pscustomobject]@{
            TimeCreated      = $ev.TimeCreated
            ProviderName     = $ev.ProviderName
            Id               = $ev.Id
            LevelDisplayName = $ev.LevelDisplayName
            RecordId         = $ev.RecordId
            MachineName      = $ev.MachineName
            Message          = $ev.Message
          }
          break
        }
      }

      # Advance bookmarks with newest event seen
      $lastRecordId = ($events | Select-Object -Last 1).RecordId
      $lastStart    = ($events | Select-Object -Last 1).TimeCreated
    }

    if ($matchedEvent) {
      if (-not $Quiet) {
        Write-Host "=== MATCHED EVENT ===" -ForegroundColor Green
        $matchedEvent | Format-List
        Write-Host ""
      }
      if ($OutCsv) {
        $matchedEvent | Export-Csv -Path $OutCsv -Append -NoTypeInformation
      }

      # Delay (countdown) before logoff
      if ($LogoffDelaySeconds -gt 0) {
        for ($i=$LogoffDelaySeconds; $i -gt 0; $i--) {
          Write-Host ("Logoff in {0}s... (WhatIf={1})" -f $i, $WhatIf) -NoNewline
          Start-Sleep -Seconds 1
          Write-Host "`r" -NoNewline
        }
        Write-Host ""
      }

      # Enumerate and optionally log off sessions (exclude non-user/system sessions by target state)
      $sessions = Get-UserSessions | Where-Object { $_.State -in $TargetStates }

      Invoke-LogoffAllUsers -Sessions $sessions -WhatIf:$WhatIf

      Write-Host "Action complete. Exiting watcher."
	  
      break
    }

  } catch {
    Write-Warning "Polling error: $($_.Exception.Message)"
  }

  # Sleep between polls
  Start-Sleep -Seconds $IntervalSeconds
}

if (-not $matchedEvent) {
  Write-Host "Finished without matches. Ended at $(Get-Date)."
}
