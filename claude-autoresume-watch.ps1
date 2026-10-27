<#
.SYNOPSIS
  Companion watcher for the interactive Claude Code TUI: auto-resume after a usage limit.

.DESCRIPTION
  Use this when you want to work in the normal Claude Code terminal UI and still get auto-resume.

  You keep running `claude` yourself in your project folder. This script runs in a second
  PowerShell window and tails the session transcript (~/.claude/projects/...). When Claude Code
  records a usage-limit error (for example "5-hour limit reached - resets 3am"), the script:
    1. reads the reset time,
    2. waits until then (+ buffer),
    3. opens a NEW terminal window running `claude --resume <session> "<continue prompt>"`,
       so you keep watching and steering in the TUI.

  The old TUI window is left as is (it is stuck on the limit message): close it when the new
  window appears. If you continue the old window yourself before the reset, the pending
  relaunch is cancelled automatically.

  The watcher does not compact. Claude Code's own auto-compact still works inside the TUI. If you
  want quota-driven compaction, handoff, or unattended runs, use claude-autoresume.ps1 instead.

.PARAMETER WorkDir
  The project folder in which you run `claude` (default: current folder).

.PARAMETER SessionId
  Pin to one session id. By default the most recently modified transcript of the project is
  followed, which survives the new session ids created by --resume.

.PARAMETER LookbackMinutes
  Limit errors recorded up to this many minutes before the watcher started are still handled,
  so you can start the watcher after you already hit the limit.

.EXAMPLE
  # window 1: your normal TUI
  cd D:\proj; claude
  # window 2:
  .\claude-autoresume-watch.ps1 -WorkDir D:\proj

.NOTES
  Requires PowerShell 5.1+ and `claude` on PATH. Telegram (optional): TELEGRAM_BOT_TOKEN and
  TELEGRAM_CHAT_ID. Create <WorkDir>\.claude-autoresume.stop to stop the watcher.
  The transcript format is not a stable interface: check the log line "Watching transcript".
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Get-Location).Path,
    [string]$SessionId,
    [string]$ContinuePrompt = "The usage limit has reset. Continue the unfinished work from where you stopped, following the original goal.",
    [string]$PermissionMode,             # optional, passed to the relaunched claude
    [string]$AllowedTools,               # optional, passed to the relaunched claude
    [string]$Model,                      # optional, passed to the relaunched claude
    [string]$Shell = "powershell.exe",   # shell used for the new window (e.g. pwsh.exe)
    [int]$ResetBufferMinutes = 2,
    [int]$MinWaitSeconds = 60,
    [int]$PollMinutes = 15,              # reset time unreadable: relaunch after N minutes
    [int]$PollSeconds = 10,
    [int]$LookbackMinutes = 60,
    [int]$MaxRelaunches = 20,
    [switch]$NoLaunch,                   # only notify, do not open a window
    [switch]$NoKeepAwake
)

$ErrorActionPreference = 'Continue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

if (-not (Test-Path $WorkDir)) { throw "WorkDir does not exist: $WorkDir" }
$WorkDir = (Resolve-Path $WorkDir).Path.TrimEnd('\')
$LogFile  = Join-Path $WorkDir ".claude-autoresume-watch.log"
$StopFile = Join-Path $WorkDir ".claude-autoresume.stop"

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    for ($i = 0; $i -lt 5; $i++) {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 200 }
    }
}

function Send-Notify([string]$msg) {
    if ($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID) {
        try {
            Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" `
                -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = "[claude-autoresume-watch] $msg" } | Out-Null
        } catch { Write-Log "Telegram send failed: $($_.Exception.Message)" }
    }
}

function Get-ResetTime([string]$s) {
    # Old form: "Claude AI usage limit reached|1760000000"
    if ($s -match '\|\s*(\d{10})\b') {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime
    }
    $now = Get-Date
    # Weekly form: "resets Oct 30, 3am" / "resets Oct 30 at 10:30pm"
    if ($s -match '(?i)resets?\s+(?:on\s+)?([a-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)') {
        try {
            $mo = [datetime]::ParseExact($Matches[1], 'MMM', [System.Globalization.CultureInfo]::InvariantCulture).Month
            $d = [int]$Matches[2]; $h = [int]$Matches[3]; $m = 0
            if ($Matches[4]) { $m = [int]$Matches[4] }
            $ap = $Matches[5].ToLower()
            if ($ap -eq 'pm' -and $h -lt 12) { $h += 12 }
            if ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
            $t = Get-Date -Month $mo -Day $d -Hour $h -Minute $m -Second 0 -Millisecond 0
            if ($t -le $now) { $t = $t.AddYears(1) }
            return $t
        } catch {}
    }
    $h = $null; $m = 0
    # New form: "resets 3am" / "resets at 10:30pm"
    if ($s -match '(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)') {
        $h = [int]$Matches[1]
        if ($Matches[2]) { $m = [int]$Matches[2] }
        $ap = $Matches[3].ToLower()
        if ($ap -eq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
    }
    elseif ($s -match '(?i)resets?\s+(?:at\s+)?(\d{1,2}):(\d{2})\b') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
    }
    if ($null -eq $h -or $h -gt 23 -or $m -gt 59) { return $null }
    $t = Get-Date -Hour $h -Minute $m -Second 0 -Millisecond 0
    if ($t -le $now) { $t = $t.AddDays(1) }
    return $t
}

# ---------- transcript access ----------
function Get-ProjectDir {
    $base = $env:CLAUDE_CONFIG_DIR
    if (-not $base) { $base = Join-Path $env:USERPROFILE '.claude' }
    $root = Join-Path $base 'projects'
    if (-not (Test-Path $root)) { return $null }
    # Claude Code names the folder after the working directory with every non-alphanumeric char replaced by '-'
    $enc = ($WorkDir -replace '[^A-Za-z0-9]', '-')
    $dir = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $enc } | Select-Object -First 1
    if ($dir) { return $dir.FullName }
    return $null
}

function Find-Transcript {
    $dir = Get-ProjectDir
    if (-not $dir) { return $null }
    if ($SessionId) {
        $p = Join-Path $dir "$SessionId.jsonl"
        if (Test-Path $p) { return $p }
        return $null
    }
    $f = Get-ChildItem -Path $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# Reads complete new lines from $path starting at $script:Offset
function Read-NewLines([string]$path) {
    $out = @()
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt $script:Offset) { $script:Offset = 0 }   # file was rewritten
            $fs.Seek($script:Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $n = [int]($fs.Length - $script:Offset)
            if ($n -le 0) { return $out }
            $buf = New-Object byte[] $n
            $read = $fs.Read($buf, 0, $n)
            if ($read -le 0) { return $out }
            $last = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
            if ($last -lt 0) { return $out }                            # no complete line yet
            $script:Offset += ($last + 1)
            $out = @($utf8.GetString($buf, 0, $last + 1) -split "\r?\n" | Where-Object { $_.Trim() -ne '' })
        } finally { $fs.Dispose() }
    } catch { Write-Log "Could not read transcript: $($_.Exception.Message)" }
    return $out
}

# Returns @{ Kind = 'limit'|'activity'; Text; Ts } for an assistant transcript line, or $null
function Get-AssistantEvent([string]$line) {
    if ($line -notmatch '"type"\s*:\s*"assistant"') { return $null }
    try { $o = $line | ConvertFrom-Json } catch { return $null }
    if ($o.type -ne 'assistant' -or $o.isSidechain) { return $null }
    $ts = $null
    if ($o.timestamp -is [datetime]) { $ts = $o.timestamp.ToUniversalTime() }
    elseif ($o.timestamp) {
        try { $ts = [DateTimeOffset]::Parse([string]$o.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime } catch {}
    }
    $text = ''
    foreach ($c in @($o.message.content)) { if ($c.type -eq 'text' -and $c.text) { $text += [string]$c.text + "`n" } }
    # Client-generated error messages are flagged isApiErrorMessage and/or use the synthetic model name
    $isSynthetic = [bool]$o.isApiErrorMessage -or ($o.message.model -eq '<synthetic>')
    if ($isSynthetic) {
        if ($text -match '(?i)(usage limit|limit reached|hit your limit)') { return @{ Kind = 'limit'; Text = $text.Trim(); Ts = $ts } }
        return $null
    }
    return @{ Kind = 'activity'; Text = $text; Ts = $ts }
}

# ---------- relaunch ----------
function Start-ResumeWindow([string]$sid) {
    $parts = @("'--resume'", "'$sid'")
    if ($PermissionMode) { $parts += @("'--permission-mode'", "'" + ($PermissionMode -replace "'", "''") + "'") }
    if ($AllowedTools)   { $parts += @("'--allowedTools'", "'" + ($AllowedTools -replace "'", "''") + "'") }
    if ($Model)          { $parts += @("'--model'", "'" + ($Model -replace "'", "''") + "'") }
    $parts += "'" + ($ContinuePrompt -replace "'", "''") + "'"
    $cmd = "Set-Location -LiteralPath '" + ($WorkDir -replace "'", "''") + "'; & claude @(" + ($parts -join ',') + ")"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath $Shell -ArgumentList @('-NoExit', '-EncodedCommand', $enc) -WorkingDirectory $WorkDir | Out-Null
}

# Returns $true to relaunch, $false if cancelled / stopped
function Wait-ForReset([datetime]$target, $limitTs, [string]$path) {
    Write-Log ("Waiting until {0}" -f $target.ToString('yyyy-MM-dd HH:mm'))
    $lastLog = Get-Date
    while ((Get-Date) -lt $target) {
        if (Test-Path $StopFile) { Write-Log "Stop file found."; return $false }
        Start-Sleep -Seconds 15
        # If you continue in the old TUI yourself, there will be newer successful assistant output: cancel
        foreach ($l in (Read-NewLines $path)) {
            $e = Get-AssistantEvent $l
            if ($e -and $e.Kind -eq 'activity' -and $e.Ts -and $limitTs -and $e.Ts -gt $limitTs.AddSeconds(2)) {
                Write-Log "New activity in the session while waiting, cancelling the relaunch."
                return $false
            }
        }
        if (((Get-Date) - $lastLog).TotalMinutes -ge 30) {
            Write-Log ("About {0} minutes left" -f [int]($target - (Get-Date)).TotalMinutes)
            $lastLog = Get-Date
        }
    }
    return $true
}

# ---------- main ----------
if (-not $NoKeepAwake) {
    try {
        Add-Type -Namespace Win32 -Name Power -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction Stop
        [void][Win32.Power]::SetThreadExecutionState([uint32]2147483649)
        Write-Log "Keep-awake enabled."
    } catch { Write-Log "Could not enable keep-awake: $($_.Exception.Message)" }
}
Remove-Item -Path $StopFile -ErrorAction SilentlyContinue

try {
    $minTs = (Get-Date).ToUniversalTime().AddMinutes(-$LookbackMinutes)
    $cur = $null
    $script:Offset = 0
    $relaunches = 0
    $warnedNoDir = $false
    Write-Log "Watching for usage limits in $WorkDir (Ctrl+C or create $StopFile to stop)."

    while ($true) {
        if (Test-Path $StopFile) { Write-Log "Stop file found, stopping."; break }

        $t = Find-Transcript
        if (-not $t) {
            if (-not $warnedNoDir) { Write-Log "No transcript found yet for this folder. Start `claude` in $WorkDir ..."; $warnedNoDir = $true }
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($t -ne $cur) {
            $cur = $t
            $script:Offset = 0
            Write-Log "Watching transcript: $cur"
        }

        $limitEvent = $null
        foreach ($l in (Read-NewLines $cur)) {
            $e = Get-AssistantEvent $l
            if (-not $e) { continue }
            if ($e.Ts -and $e.Ts -lt $minTs) { continue }   # old history (or a copy made by --resume)
            if ($e.Kind -eq 'limit') { $limitEvent = $e }
            elseif ($e.Kind -eq 'activity') { $limitEvent = $null }   # later successful output supersedes an earlier limit
        }

        if ($limitEvent) {
            $sid = [System.IO.Path]::GetFileNameWithoutExtension($cur)
            $preview = $limitEvent.Text.Substring(0, [Math]::Min(160, $limitEvent.Text.Length))
            Write-Log ("Usage limit detected in session {0}: {1}" -f $sid, $preview)

            if ($relaunches -ge $MaxRelaunches) {
                Write-Log "Reached MaxRelaunches=$MaxRelaunches, stopping."
                Send-Notify "Stopped: reached MaxRelaunches."
                break
            }

            $reset = Get-ResetTime $limitEvent.Text
            $minTarget = (Get-Date).AddSeconds($MinWaitSeconds)
            if ($reset) {
                $target = $reset.AddMinutes($ResetBufferMinutes)
                Write-Log ("Reset time read: {0}" -f $reset.ToString('yyyy-MM-dd HH:mm'))
                if (($reset - (Get-Date)).TotalHours -gt 6) { Write-Log "Note: more than 6 hours away - this may be the weekly limit." }
            } else {
                $target = (Get-Date).AddMinutes($PollMinutes)
                Write-Log "Could not read the reset time -> relaunching in $PollMinutes minutes."
            }
            if ($target -lt $minTarget) { $target = $minTarget }
            Send-Notify ("Limit hit, will resume at {0}" -f $target.ToString('HH:mm dd/MM'))

            if (-not (Wait-ForReset $target $limitEvent.Ts $cur)) {
                if (Test-Path $StopFile) { break }
                $minTs = (Get-Date).ToUniversalTime()
                continue
            }

            if ($NoLaunch) {
                Write-Log "Reset time reached (-NoLaunch: not opening a window). Resume with: claude --resume $sid"
                Send-Notify "Limit reset. Resume with: claude --resume $sid"
            } else {
                Write-Log "Opening a new window: claude --resume $sid"
                Start-ResumeWindow $sid
                Send-Notify "Resumed session $sid in a new window."
            }
            $relaunches++
            $minTs = (Get-Date).ToUniversalTime()
            $SessionId = $null     # --resume creates a new session id: follow the newest transcript again
            $cur = $null
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if (-not $NoKeepAwake) { try { [void][Win32.Power]::SetThreadExecutionState([uint32]2147483648) } catch {} }
}
