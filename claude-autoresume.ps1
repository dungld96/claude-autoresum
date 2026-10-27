<#
.SYNOPSIS
  Auto Compact + Auto Resume for Claude Code (Pro plan) on Windows.

.DESCRIPTION
  Runs Claude Code headless (-p, stream-json) in a loop, a few turns per run (-MaxTurns).

  Goal: do NOT hit the usage limit while the context is large. If the limit is hit at ~80%
  context, the resume after the reset has to reload that whole context and immediately burns
  a chunk of the fresh quota. So the script compacts BEFORE the quota runs out, driven by
  quota signals rather than by wall-clock time.

  Quota signals (in order of reliability):
    1. rate_limit_event in the Claude Code stream-json output:
       - utilization (if present)   -> % of the 5h quota, compact at >= -CompactAtPercent
       - status = allowed_warning on five_hour -> Claude Code says the limit is near, compact now
    2. Estimated cost (total_cost_usd) spent in the window versus the cost at which earlier
       windows hit the limit (learned automatically after the first limit hit)
    3. Context >= -HardCompactTokens (measured from the transcript), even right after a reset
  An optional time trigger is available with -CompactAtMinutes (off by default).
  Small contexts (< -MinCompactTokens) are never compacted because resuming them is cheap.

  /compact is verified: the context size must actually drop afterwards. If /compact does not
  work in -p mode (or does not shrink the context), the script falls back to a "handoff":
  Claude writes HANDOFF.md, then a fresh session reads that file.

  When the limit is hit: read the reset time, sleep until then (+ buffer), then --resume.
  State is kept in .claude-autoresume.json, so stopping and restarting the script continues
  where it left off. The script stops when the last line of an answer is the DoneMarker
  (TASK_DONE by default), when -MaxRuns is reached, or after too many consecutive errors or
  limit waits.

.PARAMETER Prompt
  Task prompt. If given without -SessionId, any previous state in WorkDir is discarded.

.PARAMETER PromptFile
  Read the task prompt from a file (UTF-8).

.PARAMETER UtilizationFormat
  How rate_limit_event.utilization is encoded: 'fraction' (0..1, default) or 'percent' (0..100).
  Check the "rate_limit_event sample" log line on the first run to confirm what your
  Claude Code version returns.

.PARAMETER RunTimeoutMinutes
  Kill a single claude invocation that runs longer than this (0 = no timeout).

.PARAMETER MaxLimitWaits
  Stop after this many consecutive limit waits without a successful run in between.

.EXAMPLE
  .\claude-autoresume.ps1 -WorkDir D:\proj -PromptFile .\task.md `
      -AllowedTools "Bash Edit Write Read Glob Grep"

.EXAMPLE
  .\claude-autoresume.ps1 -WorkDir D:\proj -SessionId <id>

.NOTES
  Requires PowerShell 5.1+ and the `claude` CLI (Claude Code) logged in with a Pro account.
  Telegram notifications (optional): set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.
  The script is ASCII-only, so no special file encoding is needed.
#>
[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$PromptFile,
    [string]$WorkDir = (Get-Location).Path,
    [string]$SessionId,
    [string]$ContinuePrompt = "Continue the unfinished work from where you stopped, following the original goal.",
    [string]$DoneMarker = "TASK_DONE",
    [string]$CompactInstructions = "Keep: the main goal, decisions already made, the list of modified files, current errors, and the remaining steps in order.",
    [int]$MaxRuns = 300,
    [int]$MaxTurns = 15,                 # max turns per run, so the script checks quota often
    [double]$CompactAtPercent = 80,      # compact when the 5h quota >= N% (if utilization is reported)
    [ValidateSet('fraction', 'percent')]
    [string]$UtilizationFormat = 'fraction',
    [double]$CompactAtLimitFraction = 0.85,
    [int]$MinCompactTokens = 40000,      # below this, never compact
    [int]$HardCompactTokens = 140000,    # above this, compact regardless of quota
    [int]$MaxCompactsPerWindow = 3,      # cap on repeated hard compacts within one window
    [double]$CompactMinReduction = 0.30, # compact only counts if the context shrank by >= 30%
    [int]$CompactAtMinutes = 0,          # 0 = time trigger off
    [int]$ResetBufferMinutes = 2,
    [int]$MinWaitSeconds = 60,           # never wait less than this after a limit hit
    [int]$PollMinutes = 15,              # reset time unreadable: retry every N minutes
    [int]$MaxLimitWaits = 12,            # consecutive limit waits before giving up
    [int]$RunTimeoutMinutes = 60,
    [string]$PermissionMode = "acceptEdits",
    [string]$AllowedTools,               # e.g. "Bash Edit Write Read Glob Grep"
    [string]$Model,
    [switch]$NoCompact,
    [switch]$NoKeepAwake
)

$ErrorActionPreference = 'Continue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding  = $utf8
$OutputEncoding = $utf8

if (-not (Test-Path $WorkDir)) { throw "WorkDir does not exist: $WorkDir" }
$StateFile = Join-Path $WorkDir ".claude-autoresume.json"
$LogFile   = Join-Path $WorkDir ".claude-autoresume.log"
$LockFile  = Join-Path $WorkDir ".claude-autoresume.lock"

if ($PromptFile) { $Prompt = Get-Content -Raw -Encoding UTF8 $PromptFile }

$DoneSuffix = "When ALL the work is finished, end your answer with a separate final line containing only: $DoneMarker"
$HandoffPrompt = "Write the state of the work to HANDOFF.md in the project root: the original goal, decisions already made, files created/modified, current errors, and the remaining steps in priority order. Only write this file, do nothing else."
$HandoffResumePrompt = "This is a new session. Read HANDOFF.md in the project root and continue from the remaining steps. $DoneSuffix"

$script:SawQuotaInfo = $false
$script:LoggedSample = $false
$script:WeekPct = -1.0

# ---------- helpers ----------
function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Send-Notify([string]$msg) {
    if ($env:TELEGRAM_BOT_TOKEN -and $env:TELEGRAM_CHAT_ID) {
        try {
            Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" `
                -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = "[claude-autoresume] $msg" } | Out-Null
        } catch { Write-Log "Telegram send failed: $($_.Exception.Message)" }
    }
}

function Get-Now-Unix { [DateTimeOffset]::Now.ToUnixTimeSeconds() }

# Normalize an epoch (seconds or milliseconds) to seconds
function ConvertTo-EpochSeconds($v) {
    if ($null -eq $v) { return 0 }
    $d = 0.0
    if (-not [double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 0 }
    if ($d -gt 100000000000) { $d = $d / 1000 }
    return [long]$d
}

function New-State {
    @{ sessionId = $null; blockStart = $null; compacted = $false; compactCount = 0; blockCost = 0.0; limitCost = 0.0
       quotaPct = -1.0; warn = $false; windowResetAt = 0; pendingPrompt = $null }
}

function Load-State {
    $s = New-State
    if (Test-Path $StateFile) {
        try {
            $j = Get-Content -Raw -Encoding UTF8 $StateFile | ConvertFrom-Json
            $s.sessionId     = $j.sessionId
            $s.blockStart    = $j.blockStart
            $s.compacted     = [bool]$j.compacted
            $s.warn          = [bool]$j.warn
            $s.pendingPrompt = $j.pendingPrompt
            if ($j.compactCount)  { $s.compactCount = [int]$j.compactCount }
            if ($j.blockCost)     { $s.blockCost = [double]$j.blockCost }
            if ($j.limitCost)     { $s.limitCost = [double]$j.limitCost }
            if ($null -ne $j.quotaPct) { $s.quotaPct = [double]$j.quotaPct }
            if ($j.windowResetAt) { $s.windowResetAt = [long]$j.windowResetAt }
        } catch { Write-Log "Could not read state, starting fresh." }
    }
    return $s
}

function Save-State($s) {
    ($s | ConvertTo-Json) | Set-Content -Path $StateFile -Encoding UTF8
}

# Start a fresh 5h window
function Reset-Block($s) {
    $s.blockStart = $null
    $s.compacted = $false
    $s.compactCount = 0
    $s.blockCost = 0.0
    $s.quotaPct = -1.0
    $s.warn = $false
    $s.windowResetAt = 0
}

# ---------- single-instance lock ----------
function Enter-Lock {
    if (Test-Path $LockFile) {
        $old = 0
        [void][int]::TryParse(((Get-Content -Raw -ErrorAction SilentlyContinue $LockFile) + '').Trim(), [ref]$old)
        if ($old -gt 0 -and $old -ne $PID -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
            throw "Another claude-autoresume instance (PID $old) is already running in $WorkDir."
        }
    }
    Set-Content -Path $LockFile -Value $PID -Encoding ASCII
}

function Exit-Lock {
    Remove-Item -Path $LockFile -ErrorAction SilentlyContinue
}

# ---------- measure context from the transcript ----------
$script:TranscriptCache = @{}

function Find-Transcript([string]$sid) {
    if (-not $sid) { return $null }
    $cached = $script:TranscriptCache[$sid]
    if ($cached -and (Test-Path $cached)) { return $cached }
    $base = $env:CLAUDE_CONFIG_DIR
    if (-not $base) { $base = Join-Path $env:USERPROFILE '.claude' }
    $root = Join-Path $base 'projects'
    if (-not (Test-Path $root)) { return $null }
    $f = Get-ChildItem -Path $root -Recurse -Filter "$sid.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $script:TranscriptCache[$sid] = $f.FullName; return $f.FullName }
    return $null
}

# Context size ~ input + cache_creation + cache_read of the latest assistant call
function Get-ContextTokens([string]$sid) {
    $p = Find-Transcript $sid
    if (-not $p) { return 0 }
    $tail = @(Get-Content -Path $p -Tail 300 -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = [string]$tail[$i]
        if ($line -notmatch '"usage"') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant' -or $o.isSidechain) { continue }
        $u = $o.message.usage
        if (-not $u) { continue }
        $n = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens
        if ($n -gt 0) { return $n }
    }
    return 0
}

# ---------- running claude ----------
function ConvertTo-CmdArg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '"', '\"') + '"'
}

function Stop-ProcessTree([System.Diagnostics.Process]$p) {
    try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {}
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
}

# One-line live progress from a stream-json event
function Write-Progress-Event($ev) {
    if ($ev.type -ne 'assistant') { return }
    foreach ($c in @($ev.message.content)) {
        if ($c.type -eq 'tool_use') { Write-Log ("  tool: {0}" -f $c.name) }
        elseif ($c.type -eq 'text' -and $c.text) {
            $t = ([string]$c.text -replace '\s+', ' ').Trim()
            if ($t) { Write-Log ("  text: {0}" -f $t.Substring(0, [Math]::Min(120, $t.Length))) }
        }
    }
}

function Invoke-Claude([string]$text, [string]$sid) {
    $cliArgs = @('-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', $PermissionMode)
    if ($sid)            { $cliArgs += @('--resume', $sid) }
    if ($MaxTurns -gt 0) { $cliArgs += @('--max-turns', [string]$MaxTurns) }
    if ($AllowedTools)   { $cliArgs += @('--allowedTools', $AllowedTools) }
    if ($Model)          { $cliArgs += @('--model', $Model) }

    if (-not $script:ClaudeExe) {
        $script:ClaudeExe = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ClaudeExe
    $psi.Arguments = ($cliArgs | ForEach-Object { ConvertTo-CmdArg ([string]$_) }) -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.CreateNoWindow = $true

    $rawLines = New-Object System.Collections.Generic.List[string]
    $events = New-Object System.Collections.Generic.List[object]
    $timedOut = $false
    $code = -1
    $stderrText = ''

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        # The prompt goes through stdin to avoid quote/newline escaping problems on Windows
        # Write raw UTF-8 bytes (no BOM): ProcessStartInfo.StandardInputEncoding does not exist on .NET Framework (PS 5.1)
        $inBytes = $utf8.GetBytes($text)
        $proc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $deadline = if ($RunTimeoutMinutes -gt 0) { (Get-Date).AddMinutes($RunTimeoutMinutes) } else { [datetime]::MaxValue }
        $readTask = $proc.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($readTask.Wait(1000)) {
                $line = $readTask.Result
                if ($null -eq $line) { break }
                $rawLines.Add($line)
                $l = $line.Trim()
                if ($l.StartsWith('{')) {
                    try { $ev = $l | ConvertFrom-Json; $events.Add($ev); Write-Progress-Event $ev } catch {}
                }
                $readTask = $proc.StandardOutput.ReadLineAsync()
            } elseif ((Get-Date) -gt $deadline) {
                $timedOut = $true
                Write-Log "claude exceeded the $RunTimeoutMinutes minute timeout, killing it."
                Stop-ProcessTree $proc
                break
            }
        }
        [void]$proc.WaitForExit(10000)
        if ($proc.HasExited) { $code = $proc.ExitCode }
        if ($errTask.Wait(5000)) { $stderrText = $errTask.Result }
    } finally {
        $proc.Dispose()
    }

    $raw = ($rawLines -join "`n")
    $json = $events | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1
    $init = $events | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'init' } | Select-Object -First 1

    # Quota info from rate_limit_event
    $qPct = -1.0; $qWeek = -1.0; $qWarn = $false; $qReset = 0; $sawQuota = $false
    $rejectedAt = $null
    foreach ($ev in $events) {
        if ($ev.type -ne 'rate_limit_event') { continue }
        $info = $ev.rate_limit_info
        if (-not $info) { $info = $ev.rateLimitInfo }
        if (-not $info) { continue }
        $sawQuota = $true
        $type = $info.rateLimitType; if (-not $type) { $type = $info.rate_limit_type }
        $status = [string]$info.status
        $rs = $info.resetsAt; if (-not $rs) { $rs = $info.resets_at }
        $sec = ConvertTo-EpochSeconds $rs
        if (-not $script:LoggedSample) {
            $script:LoggedSample = $true
            $sample = ($ev | ConvertTo-Json -Depth 6 -Compress)
            Write-Log ("rate_limit_event sample: " + $sample.Substring(0, [Math]::Min(1000, $sample.Length)))
        }
        # Newer Claude Code versions report both windows under unifiedWindows regardless of rateLimitType
        $uw = $info.unifiedWindows
        $u5 = $null
        if ($uw -and $uw.five_hour -and $null -ne $uw.five_hour.utilization) {
            $u5 = [double]$uw.five_hour.utilization
            $s5 = ConvertTo-EpochSeconds $uw.five_hour.resetsAt
            if ($s5 -gt 0) { $qReset = $s5 }
        }
        elseif ($type -eq 'five_hour' -and $null -ne $info.utilization) {
            $u5 = [double]$info.utilization
        }
        if ($null -ne $u5) {
            if ($UtilizationFormat -eq 'fraction') { $u5 = $u5 * 100 }
            $qPct = $u5
        }
        if ($uw -and $uw.seven_day -and $null -ne $uw.seven_day.utilization) {
            $u7 = [double]$uw.seven_day.utilization
            if ($UtilizationFormat -eq 'fraction') { $u7 = $u7 * 100 }
            $qWeek = $u7
        }
        if ($type -eq 'five_hour') {
            if ($status -eq 'allowed_warning') { $qWarn = $true }
            if ($sec -gt 0) { $qReset = $sec }
        }
        if ($status -eq 'rejected' -and $sec -gt 0) {
            $rejectedAt = [DateTimeOffset]::FromUnixTimeSeconds($sec).LocalDateTime
        }
    }

    # Text used for error / limit detection. Never include rate_limit_event JSON lines.
    $plainLines = @($rawLines | Where-Object { -not $_.Trim().StartsWith('{') })
    $plainText = (($plainLines -join "`n") + "`n" + $stderrText).Trim()
    $resultText = $plainText
    $isErr = ($code -ne 0) -or $timedOut
    $newSid = $null
    $cost = 0.0
    $denials = 0
    if ($json) {
        if ($json.result) { $resultText = [string]$json.result }
        $isErr = ([bool]$json.is_error) -or ($code -ne 0 -and -not $timedOut)
        if ($json.subtype -eq 'error_max_turns') { $isErr = $false }   # out of turns for this run: not an error
        if ($json.session_id) { $newSid = [string]$json.session_id }
        if ($json.total_cost_usd) { $cost = [double]$json.total_cost_usd }
        if ($json.permission_denials) { $denials = @($json.permission_denials).Count }
    }
    if (-not $newSid -and $init -and $init.session_id) { $newSid = [string]$init.session_id }
    if ($denials -gt 0) { Write-Log "Warning: $denials tool call(s) denied by permissions. Consider widening -AllowedTools." }

    $limit = $false
    if ($isErr -and -not $timedOut -and ($rejectedAt -or ($resultText -match '(?i)(usage limit|limit reached|hit your limit|rate limit|too many requests|resets?\s)'))) { $limit = $true }

    [pscustomobject]@{
        Raw = $raw; Text = $resultText; IsError = $isErr; Limit = $limit; SessionId = $newSid; Cost = $cost; Code = $code
        QPct = $qPct; QWeek = $qWeek; QWarn = $qWarn; QReset = $qReset; SawQuota = $sawQuota; RejectedAt = $rejectedAt; TimedOut = $timedOut
    }
}

# Update quota state from one invocation
function Update-Quota($state, $r) {
    if ($r.SawQuota) { $script:SawQuotaInfo = $true }
    if ($r.QPct -ge 0) { $state.quotaPct = $r.QPct }
    if ($r.QWeek -ge 0) { $script:WeekPct = $r.QWeek }
    if ($r.QWarn) { $state.warn = $true }
    if ($r.QReset -gt 0) { $state.windowResetAt = $r.QReset }
}

# ---------- reading the reset time ----------
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

function Wait-Until([datetime]$t) {
    Write-Log ("Waiting until {0}" -f $t.ToString('yyyy-MM-dd HH:mm'))
    $lastLog = Get-Date
    while ((Get-Date) -lt $t) {
        Start-Sleep -Seconds 30
        if (((Get-Date) - $lastLog).TotalMinutes -ge 30) {
            Write-Log ("About {0} minutes left" -f [int]($t - (Get-Date)).TotalMinutes)
            $lastLog = Get-Date
        }
    }
}

# Returns $true if the script should keep going, $false if it gave up
function Handle-Limit($r, $state) {
    $script:LimitStreak++
    # Learn the cost level of one window: used to compact earlier in later windows
    if ($state.blockCost -gt $state.limitCost) { $state.limitCost = [double]$state.blockCost }
    Write-Log ('Limit hit (#{0} in a row). Estimated cost spent in this window: ${1:N2} (learned level: ${2:N2})' -f $script:LimitStreak, $state.blockCost, $state.limitCost)

    if ($script:LimitStreak -gt $MaxLimitWaits) {
        Write-Log "Giving up: $MaxLimitWaits consecutive limit waits without a successful run."
        Send-Notify "Stopped: repeated limit hits with no progress."
        Save-State $state
        return $false
    }

    $reset = $r.RejectedAt
    if (-not $reset) { $reset = Get-ResetTime $r.Text }
    $minTarget = (Get-Date).AddSeconds($MinWaitSeconds)
    if ($reset) {
        $target = $reset.AddMinutes($ResetBufferMinutes)
        Write-Log ("Reset time read: {0}" -f $reset.ToString('yyyy-MM-dd HH:mm'))
        if (($reset - (Get-Date)).TotalHours -gt 6) { Write-Log "Note: more than 6 hours away - this may be the weekly limit." }
    } else {
        $target = (Get-Date).AddMinutes($PollMinutes)
        Write-Log "Could not read the reset time -> retrying in $PollMinutes minutes."
    }
    if ($target -lt $minTarget) { $target = $minTarget }
    if ($script:LimitStreak -eq 1) { Send-Notify ("Limit hit, waiting until {0}" -f $target.ToString('HH:mm dd/MM')) }
    Reset-Block $state
    Save-State $state
    Wait-Until $target
    return $true
}

# ---------- keep the machine awake ----------
function Enable-KeepAwake {
    try {
        Add-Type -Namespace Win32 -Name Power -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction Stop
        [void][Win32.Power]::SetThreadExecutionState([uint32]2147483649)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        Write-Log "Keep-awake enabled."
    } catch { Write-Log "Could not enable keep-awake: $($_.Exception.Message)" }
}

function Disable-KeepAwake {
    try { [void][Win32.Power]::SetThreadExecutionState([uint32]2147483648) } catch {}
}

# ---------- main ----------
Enter-Lock
try {
    if (-not $NoKeepAwake) { Enable-KeepAwake }

    # A new -Prompt without -SessionId means a new task: drop any old state
    if ($Prompt -and -not $SessionId -and (Test-Path $StateFile)) {
        Write-Log "New -Prompt given: discarding previous state."
        Remove-Item -Path $StateFile -ErrorAction SilentlyContinue
    }

    $state = Load-State
    if ($SessionId) { $state.sessionId = $SessionId }

    if (-not $state.sessionId -and -not $state.pendingPrompt -and -not $Prompt) {
        throw "Need -Prompt/-PromptFile (new task) or -SessionId (continue an old session)."
    }

    if ($state.pendingPrompt) {
        $nextPrompt = [string]$state.pendingPrompt
        Write-Log "Continuing from a saved pending prompt (handoff)."
    } elseif ($state.sessionId) {
        $nextPrompt = "$ContinuePrompt $DoneSuffix"
        Write-Log "Resume session $($state.sessionId)"
    } else {
        $nextPrompt = $Prompt + "`n`n" + $DoneSuffix
        Write-Log "Starting new task in $WorkDir"
    }

    $errStreak = 0
    $script:LimitStreak = 0
    $run = 0
    $finished = $false
    $gaveUp = $false
    while ($run -lt $MaxRuns) {
        $run++

        # The 5h window reset on its own (no limit hit needed)
        if ($state.windowResetAt -gt 0 -and (Get-Now-Unix) -gt $state.windowResetAt) {
            Write-Log "5h window has reset."
            Reset-Block $state
            Save-State $state
        }

        # 1) Proactive compact before the quota runs out
        $ctx = 0
        if ($state.sessionId) { $ctx = Get-ContextTokens $state.sessionId }
        $quotaTxt = "unknown"
        if ($state.quotaPct -ge 0) { $quotaTxt = ("{0:N0}%" -f $state.quotaPct) }
        if ($state.warn) { $quotaTxt += " (warned)" }
        $weekTxt = "unknown"
        if ($script:WeekPct -ge 0) { $weekTxt = ("{0:N0}%" -f $script:WeekPct) }
        Write-Log ("Context ~{0:N0} tokens | 5h quota: {1} | 7d quota: {2} | window cost: `${3:N2}" -f $ctx, $quotaTxt, $weekTxt, $state.blockCost)

        $canCompact = (-not $state.compacted) -or ($ctx -ge $HardCompactTokens -and $state.compactCount -lt $MaxCompactsPerWindow)
        if (-not $NoCompact -and $state.sessionId -and -not $state.pendingPrompt -and $canCompact -and $ctx -ge $MinCompactTokens) {
            $reasons = @()
            if (-not $state.compacted) {
                if ($state.quotaPct -ge $CompactAtPercent) { $reasons += ("5h quota ~{0:N0}%" -f $state.quotaPct) }
                if ($state.warn) { $reasons += "Claude Code warned the 5h quota is nearly used" }
                if ($state.limitCost -gt 0 -and $state.blockCost -ge ($CompactAtLimitFraction * $state.limitCost)) { $reasons += "near the learned cost level" }
                if ($CompactAtMinutes -gt 0 -and $state.blockStart) {
                    $elapsedMin = ((Get-Now-Unix) - [long]$state.blockStart) / 60
                    if ($elapsedMin -ge $CompactAtMinutes) { $reasons += ("5h window is {0:N0} minutes old" -f $elapsedMin) }
                }
            }
            if ($ctx -ge $HardCompactTokens) { $reasons += "context too large" }

            if ($reasons.Count -gt 0) {
                Write-Log ("Compact: {0}" -f ($reasons -join '; '))
                $c = Invoke-Claude ("/compact " + $CompactInstructions) $state.sessionId
                Update-Quota $state $c
                $state.blockCost += $c.Cost
                if ($c.Limit) {
                    if (-not (Handle-Limit $c $state)) { $gaveUp = $true; break }
                    $run--; continue
                }

                $compactOk = -not $c.IsError -and -not ($c.Text -match '(?i)unknown (slash )?command|isn.t available|not available in')
                $workSid = $state.sessionId
                if ($c.SessionId) { $workSid = $c.SessionId }
                if ($compactOk) {
                    # Verify: the context must really have shrunk (else /compact was treated as a plain prompt)
                    $after = Get-ContextTokens $workSid
                    if ($after -gt 0 -and $after -gt ($ctx * (1 - $CompactMinReduction))) {
                        Write-Log ("Compact did not shrink the context ({0:N0} -> {1:N0} tokens), treating it as failed." -f $ctx, $after)
                        $compactOk = $false
                    } else {
                        $state.sessionId = $workSid
                        Write-Log ("Compact done ({0:N0} -> {1:N0} tokens)." -f $ctx, $after)
                    }
                }

                if (-not $compactOk) {
                    Write-Log "Compact does not work in -p mode -> falling back to handoff (HANDOFF.md + new session)."
                    $h = Invoke-Claude $HandoffPrompt $workSid
                    Update-Quota $state $h
                    $state.blockCost += $h.Cost
                    if ($h.Limit) {
                        if (-not (Handle-Limit $h $state)) { $gaveUp = $true; break }
                        $run--; continue
                    }
                    if (-not $h.IsError) {
                        $state.sessionId = $null
                        $nextPrompt = $HandoffResumePrompt
                        $state.pendingPrompt = $HandoffResumePrompt   # survives a script restart
                        Write-Log "Handoff done, the next run opens a new session."
                    } else {
                        Write-Log "Handoff failed too, keeping the current session."
                    }
                }
                $state.compacted = $true
                $state.compactCount++
                Save-State $state
            }
        }

        # 2) Run one unit of work
        $runStart = Get-Now-Unix
        Write-Log "Run #$run"
        $r = Invoke-Claude $nextPrompt $state.sessionId
        Update-Quota $state $r
        $state.blockCost += $r.Cost

        if ($r.SessionId) {
            $state.sessionId = $r.SessionId
            if (-not $r.IsError -or $r.Limit) {
                $nextPrompt = "$ContinuePrompt $DoneSuffix"
                $state.pendingPrompt = $null
            }
        }

        if ($r.Limit) {
            Save-State $state
            if (-not (Handle-Limit $r $state)) { $gaveUp = $true; break }
            $run--          # limit hits do not count against MaxRuns
            continue
        }

        if ($r.IsError) {
            $errStreak++
            Write-Log ("Error ({0}/5): {1}" -f $errStreak, $r.Text.Substring(0, [Math]::Min(300, $r.Text.Length)))
            if ($errStreak -ge 5) { Send-Notify "Stopped: 5 consecutive errors."; Write-Log "Stopping after consecutive errors."; $gaveUp = $true; break }
            Save-State $state
            Start-Sleep -Seconds (60 * $errStreak)
            continue
        }
        $errStreak = 0
        $script:LimitStreak = 0

        if (-not $state.blockStart) { $state.blockStart = $runStart; $state.compacted = $false; $state.compactCount = 0 }
        if (-not $script:SawQuotaInfo -and $run -eq 1) {
            Write-Log "Warning: Claude Code returned no rate_limit_event in this mode -> only cost/context signals drive compaction."
        }
        Save-State $state

        # 3) Done yet? (the last non-empty line is the marker)
        $lines = @($r.Text -split "\r?\n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -gt 0 -and $lines[-1] -match ("^\W*" + [regex]::Escape($DoneMarker) + "\W*$")) {
            Write-Log "Finished ($DoneMarker)."
            Send-Notify "Task finished. Session: $($state.sessionId)"
            $finished = $true
            break
        }
        Start-Sleep -Seconds 5
    }

    if ($finished) {
        # Do not let a later run in this folder resume a finished session
        Move-Item -Path $StateFile -Destination ($StateFile -replace '\.json$', '.done.json') -Force -ErrorAction SilentlyContinue
    } elseif (-not $gaveUp -and $run -ge $MaxRuns) {
        Write-Log "Reached MaxRuns=$MaxRuns, stopping."
        Send-Notify "Reached MaxRuns, stopping."
    }
}
finally {
    if (-not $NoKeepAwake) { Disable-KeepAwake }
    Exit-Lock
}
