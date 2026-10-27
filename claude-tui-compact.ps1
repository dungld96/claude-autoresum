<#
.SYNOPSIS
  Auto /compact before the 5h quota runs out, for the interactive Claude Code TUI (Windows).

.DESCRIPTION
  Claude Code's own `autoContinueAtUsageLimit` setting already continues the task after a limit
  resets. What it does not do is compact BEFORE the limit, so the first request after the reset
  does not have to reload a huge context into a fresh quota. This script fills that gap.

  How it works (it is one script with several actions, wired into Claude Code via settings.json):
    StatusLine   Claude Code runs it after every assistant message. It reads the status line JSON
                 (rate_limits.five_hour.used_percentage, context_window.*), saves a snapshot per
                 session, and prints a small status line (ctx % | 5h % | 7d %).
    Hook         Runs on PostToolBatch and Stop. If the 5h quota is >= -CompactAtPercent and the
                 context is >= -MinCompactTokens (once per 5h window), it triggers a compact.
    PostCompact  Signals that a compaction finished.
    Inject       Detached helper started by Hook: waits for the TUI to be idle, types
                 "/compact <instructions>" + Enter into the TUI's console, waits for the
                 PostCompact signal, then (if the trigger interrupted a running task) types the
                 continue prompt.
    Snippet      Prints the settings.json block to paste (default action).

  Hooks cannot run slash commands, so -Mode inject types the command into the TUI's console
  (Win32 AttachConsole + WriteConsoleInput). This is experimental: see Limitations in the README.
  -Mode notify only shows a warning asking you to run /compact yourself.

.EXAMPLE
  .\claude-tui-compact.ps1                       # print the settings.json snippet
  .\claude-tui-compact.ps1 -Mode notify          # snippet for notify-only mode

.NOTES
  Requires Windows PowerShell 5.1+ and a Claude Code version whose status line JSON contains
  rate_limits (claude.ai Pro/Max). Data and log: %USERPROFILE%\.claude\autoresume\
#>
[CmdletBinding()]
param(
    [ValidateSet('Snippet', 'StatusLine', 'Hook', 'PostCompact', 'Inject')]
    [string]$Action = 'Snippet',
    [ValidateSet('inject', 'notify')]
    [string]$Mode = 'inject',
    [double]$CompactAtPercent = 80,
    [int]$MinCompactTokens = 40000,
    [string]$CompactInstructions = "Keep: the main goal, decisions already made, the list of modified files, current errors, and the remaining steps in order.",
    [string]$ContinuePrompt = "Continue the unfinished work from where you stopped, following the original goal.",
    [int]$InjectDelaySeconds = 3,
    [int]$CompactTimeoutMinutes = 10,
    [string]$DataDir = (Join-Path $env:USERPROFILE '.claude\autoresume'),
    # internal, used by Hook -> Inject
    [string]$SessionId,
    [int]$ClaudePid,
    [switch]$ThenContinue
)

$ErrorActionPreference = 'Continue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$LogFile = Join-Path $DataDir 'autoresume.log'

# Never write to the console from Hook/StatusLine/Inject except the intended output: log to a file
function Write-Log([string]$msg) {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Action, $msg
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 100 }
    }
}

function Read-StdinJson {
    try {
        [Console]::InputEncoding = $utf8
        $raw = [Console]::In.ReadToEnd()
        if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json) }
    } catch { Write-Log "Could not read stdin JSON: $($_.Exception.Message)" }
    return $null
}

function Get-SnapshotPath([string]$sid) { Join-Path $DataDir ("{0}.json" -f $sid) }
function Get-StatePath([string]$sid)    { Join-Path $DataDir ("{0}.state.json" -f $sid) }
function Get-SignalPath([string]$sid)   { Join-Path $DataDir ("{0}.compacted" -f $sid) }

function Add-ConsoleInputType {
    if ('AutoResume.ConsoleInput' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace AutoResume {
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    public struct INPUT_RECORD {
        [FieldOffset(0)]  public ushort EventType;
        [FieldOffset(4)]  public int KeyDown;
        [FieldOffset(8)]  public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public ushort UnicodeChar;
        [FieldOffset(16)] public uint ControlKeyState;
    }
    public static class ConsoleInput {
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("user32.dll")] static extern short VkKeyScanW(char c);

        static INPUT_RECORD Key(char c, ushort vk, bool down, uint ctrl) {
            INPUT_RECORD r = new INPUT_RECORD();
            r.EventType = 1;                       // KEY_EVENT
            r.KeyDown = down ? 1 : 0;
            r.RepeatCount = 1;
            r.VirtualKeyCode = vk;
            r.VirtualScanCode = (ushort)(vk == 0x0D ? 0x1C : 0);
            r.UnicodeChar = c;
            r.ControlKeyState = ctrl;
            return r;
        }

        // Types `text` (and optionally Enter) into the console of process `pid`. Returns "ok" or an error.
        public static string Send(uint pid, string text, bool enter) {
            FreeConsole();
            if (!AttachConsole(pid)) return "AttachConsole failed, error " + Marshal.GetLastWin32Error();
            try {
                IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (h == new IntPtr(-1)) return "Open CONIN$ failed, error " + Marshal.GetLastWin32Error();
                try {
                    int n = (text.Length + (enter ? 1 : 0)) * 2;
                    if (n == 0) return "ok";
                    INPUT_RECORD[] recs = new INPUT_RECORD[n];
                    int i = 0;
                    foreach (char c in text) {
                        short vk = VkKeyScanW(c);
                        ushort v = 0; uint ctrl = 0;
                        if (vk != -1) { v = (ushort)(vk & 0xFF); if (((vk >> 8) & 1) != 0) ctrl = 0x10; }
                        recs[i++] = Key(c, v, true, ctrl);
                        recs[i++] = Key(c, v, false, ctrl);
                    }
                    if (enter) { recs[i++] = Key('\r', 0x0D, true, 0); recs[i++] = Key('\r', 0x0D, false, 0); }
                    uint written;
                    if (!WriteConsoleInputW(h, recs, (uint)n, out written)) return "WriteConsoleInput failed, error " + Marshal.GetLastWin32Error();
                    return "ok";
                } finally { CloseHandle(h); }
            } finally { FreeConsole(); }
        }
    }
}
"@
}

# Walk up the process tree from this process to the claude / node process that owns the TUI
function Find-ClaudePid {
    $id = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ParentProcessId) { return 0 }
        $id = [int]$p.ParentProcessId
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if ($parent -and $parent.Name -match '^(claude|node)(\.exe)?$') { return $id }
    }
    return 0
}

switch ($Action) {

    'Snippet' {
        $self = $PSCommandPath
        $common = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Mode $Mode -CompactAtPercent $CompactAtPercent -MinCompactTokens $MinCompactTokens"
        $settings = [ordered]@{
            statusLine = [ordered]@{ type = 'command'; command = "powershell.exe $common -Action StatusLine" }
            hooks = [ordered]@{
                PostToolBatch = @(@{ hooks = @(@{ type = 'command'; command = "powershell.exe $common -Action Hook"; timeout = 30 }) })
                Stop          = @(@{ hooks = @(@{ type = 'command'; command = "powershell.exe $common -Action Hook"; timeout = 30 }) })
                PostCompact   = @(@{ hooks = @(@{ type = 'command'; command = "powershell.exe $common -Action PostCompact"; timeout = 30 }) })
            }
        }
        Write-Output "Merge this into %USERPROFILE%\.claude\settings.json (user settings), then restart Claude Code."
        Write-Output "Also set:  autoContinueAtUsageLimit: true   (continues the task after the limit resets)"
        Write-Output ""
        Write-Output ($settings | ConvertTo-Json -Depth 8)
    }

    'StatusLine' {
        $in = Read-StdinJson
        if (-not $in) { Write-Output "autoresume: no data"; break }
        $five = $in.rate_limits.five_hour
        $seven = $in.rate_limits.seven_day
        $ctxTok = 0
        if ($null -ne $in.context_window.total_input_tokens) { $ctxTok = [long]$in.context_window.total_input_tokens }
        $snap = [ordered]@{
            sessionId = [string]$in.session_id
            fivePct   = $(if ($five -and $null -ne $five.used_percentage) { [double]$five.used_percentage } else { $null })
            resetsAt  = $(if ($five -and $five.resets_at) { [long]$five.resets_at } else { 0 })
            sevenPct  = $(if ($seven -and $null -ne $seven.used_percentage) { [double]$seven.used_percentage } else { $null })
            ctxPct    = $(if ($null -ne $in.context_window.used_percentage) { [double]$in.context_window.used_percentage } else { $null })
            ctxTokens = $ctxTok
            updated   = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        }
        if ($snap.sessionId) {
            try { ($snap | ConvertTo-Json) | Set-Content -Path (Get-SnapshotPath $snap.sessionId) -Encoding UTF8 } catch {}
        }
        $f = if ($null -ne $snap.fivePct) { "{0:N0}%" -f $snap.fivePct } else { "n/a" }
        $s = if ($null -ne $snap.sevenPct) { "{0:N0}%" -f $snap.sevenPct } else { "n/a" }
        $c = if ($null -ne $snap.ctxPct) { "{0:N0}%" -f $snap.ctxPct } else { "n/a" }
        $warn = ''
        if ($null -ne $snap.fivePct -and $snap.fivePct -ge $CompactAtPercent -and $snap.ctxTokens -ge $MinCompactTokens) { $warn = ' | compact due' }
        Write-Output ("ctx {0} | 5h {1} | 7d {2}{3}" -f $c, $f, $s, $warn)
    }

    'Hook' {
        $in = Read-StdinJson
        if (-not $in -or -not $in.session_id) { break }
        $sid = [string]$in.session_id
        $event = [string]$in.hook_event_name
        $snapPath = Get-SnapshotPath $sid
        if (-not (Test-Path $snapPath)) { break }
        try { $snap = Get-Content -Raw -Encoding UTF8 $snapPath | ConvertFrom-Json } catch { break }
        if ($null -eq $snap.fivePct) { break }
        if (([DateTimeOffset]::Now.ToUnixTimeSeconds() - [long]$snap.updated) -gt 900) { break }   # stale snapshot

        $due = ([double]$snap.fivePct -ge $CompactAtPercent) -and ([long]$snap.ctxTokens -ge $MinCompactTokens)
        if (-not $due) { break }

        # One compact per 5h window
        $statePath = Get-StatePath $sid
        $state = $null
        if (Test-Path $statePath) { try { $state = Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json } catch {} }
        if ($state -and [long]$state.triggeredWindow -eq [long]$snap.resetsAt) { break }
        (@{ triggeredWindow = [long]$snap.resetsAt; at = [DateTimeOffset]::Now.ToUnixTimeSeconds() } | ConvertTo-Json) | Set-Content -Path $statePath -Encoding UTF8

        $reason = "5h quota {0:N0}%, context {1:N0} tokens" -f $snap.fivePct, $snap.ctxTokens
        Write-Log ("Compact due on {0}: {1} (mode {2})" -f $event, $reason, $Mode)

        if ($Mode -eq 'notify') {
            Write-Output (@{ systemMessage = "autoresume: $reason. Run /compact now so the resume after the reset is cheap." } | ConvertTo-Json -Compress)
            break
        }

        $cpid = Find-ClaudePid
        if ($cpid -le 0) {
            Write-Log "Could not find the claude process, falling back to a notification."
            Write-Output (@{ systemMessage = "autoresume: $reason. Run /compact now (could not find the TUI process to type it for you)." } | ConvertTo-Json -Compress)
            break
        }

        # Mid-task trigger (PostToolBatch): stop the loop so the TUI becomes idle, then continue after the compact.
        $midTask = ($event -eq 'PostToolBatch')
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Action', 'Inject',
                     '-SessionId', $sid, '-ClaudePid', [string]$cpid, '-InjectDelaySeconds', [string]$InjectDelaySeconds,
                     '-CompactTimeoutMinutes', [string]$CompactTimeoutMinutes, '-DataDir', $DataDir,
                     '-CompactInstructions', $CompactInstructions, '-ContinuePrompt', $ContinuePrompt)
        if ($midTask) { $argList += '-ThenContinue' }
        $quoted = ($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted -WindowStyle Hidden | Out-Null
        Write-Log ("Started injector for claude pid {0} (continue after compact: {1})" -f $cpid, $midTask)

        if ($midTask) {
            Write-Output (@{ continue = $false; stopReason = "autoresume: $reason - compacting before the limit, will continue automatically" } | ConvertTo-Json -Compress)
        }
    }

    'PostCompact' {
        $in = Read-StdinJson
        if ($in -and $in.session_id) {
            Set-Content -Path (Get-SignalPath ([string]$in.session_id)) -Value ([DateTimeOffset]::Now.ToUnixTimeSeconds()) -Encoding ASCII
            Write-Log "PostCompact signal written for session $($in.session_id)"
        }
    }

    'Inject' {
        # Detached helper: no console output, log to file only (the console is detached while typing)
        Write-Log "Injector started for session $SessionId (pid $ClaudePid, continue: $([bool]$ThenContinue))"
        $signal = Get-SignalPath $SessionId
        Remove-Item -Path $signal -ErrorAction SilentlyContinue
        Start-Sleep -Seconds $InjectDelaySeconds
        Add-ConsoleInputType

        $text = "/compact " + $CompactInstructions
        $res = [AutoResume.ConsoleInput]::Send([uint32]$ClaudePid, $text, $false)
        if ($res -ne 'ok') { Write-Log "Typing the command failed: $res"; break }
        Start-Sleep -Milliseconds 500        # keep the text and Enter in separate bursts so Enter submits instead of pasting
        $res = [AutoResume.ConsoleInput]::Send([uint32]$ClaudePid, '', $true)
        if ($res -ne 'ok') { Write-Log "Sending Enter failed: $res"; break }
        Write-Log "/compact submitted, waiting for PostCompact."

        $deadline = (Get-Date).AddMinutes($CompactTimeoutMinutes)
        while (-not (Test-Path $signal) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        if (-not (Test-Path $signal)) { Write-Log "Timed out waiting for the compact to finish."; break }
        Write-Log "Compact finished."

        if ($ThenContinue) {
            Start-Sleep -Seconds 3
            $res = [AutoResume.ConsoleInput]::Send([uint32]$ClaudePid, $ContinuePrompt, $false)
            if ($res -ne 'ok') { Write-Log "Typing the continue prompt failed: $res"; break }
            Start-Sleep -Milliseconds 500
            $res = [AutoResume.ConsoleInput]::Send([uint32]$ClaudePid, '', $true)
            Write-Log "Continue prompt submitted: $res"
        }
    }
}
