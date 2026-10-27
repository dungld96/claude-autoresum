# claude-autoresume

Auto compact + auto resume for [Claude Code](https://docs.claude.com/en/docs/claude-code) on Windows (Pro plan).

It runs Claude Code headless in a loop, a few turns at a time. It compacts the context **before** the 5-hour quota runs out, and when the limit is hit anyway it sleeps until the reset time and resumes the same session. Good for long, multi-step tasks you leave running overnight.

> Status: untested prototype. It relies on Claude Code's `stream-json` output, which is not a stable interface. See [Known limitations](#known-limitations).

## Why

If you hit the usage limit while the context is large (say ~80%), the resume after the reset has to reload that whole context (the prompt cache has expired) and immediately burns a chunk of the fresh quota. Compacting first makes the resume cheap.

## Requirements

- Windows with PowerShell 5.1 or newer
- `claude` (Claude Code CLI) on `PATH`, already logged in with a Pro account (run `claude` once interactively first)
- A project folder (ideally a git repo on its own branch, see [Safety](#safety))

## Quick start

1. Write the task in a file, for example `task.md`:

   ```markdown
   Migrate every module under src/ from CommonJS to ESM.
   Run the tests after each module and fix failures.
   ```

2. Allow script execution for this session if needed, then run:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

   .\claude-autoresume.ps1 -WorkDir D:\proj -PromptFile .\task.md `
       -AllowedTools "Bash Edit Write Read Glob Grep"
   ```

3. Watch the log. On the first run, look for the line `rate_limit_event sample:`. It shows what your Claude Code version reports about quota (see [Check your setup](#check-your-setup)).

The script stops when Claude ends an answer with a final line containing only `TASK_DONE`, when `-MaxRuns` is reached, or after repeated errors / limit waits.

## Common usage

```powershell
# New task from an inline prompt
.\claude-autoresume.ps1 -WorkDir D:\proj -Prompt "Fix all failing tests" -AllowedTools "Bash Edit Read Glob Grep"

# Continue an existing session
.\claude-autoresume.ps1 -WorkDir D:\proj -SessionId <session-id>

# Re-run the script after stopping it: state is picked up automatically
.\claude-autoresume.ps1 -WorkDir D:\proj

# Compact earlier / more aggressively
.\claude-autoresume.ps1 -WorkDir D:\proj -PromptFile .\task.md -CompactAtPercent 70 -HardCompactTokens 100000

# Disable compaction entirely (resume only)
.\claude-autoresume.ps1 -WorkDir D:\proj -PromptFile .\task.md -NoCompact
```

Passing `-Prompt`/`-PromptFile` without `-SessionId` always starts a **new** task and discards old state in that folder.

## How it works

Each loop iteration:

1. **Check for a window reset.** If the 5h window has passed, counters are reset.
2. **Proactive compact** (once per window, unless the context is huge) when any of these is true and the context is at least `-MinCompactTokens`:
   - `utilization` from `rate_limit_event` is at least `-CompactAtPercent`
   - Claude Code reports `allowed_warning` on the `five_hour` limit
   - Estimated cost in this window is at least `-CompactAtLimitFraction` of the cost level where earlier windows hit the limit (learned automatically)
   - The context is at least `-HardCompactTokens`
   - Optional: the window is older than `-CompactAtMinutes` (off by default)
3. **Verify the compact.** A compact only counts if Claude Code emits a `compact_boundary` event. Otherwise (or if `/compact` errors) the script falls back to a **handoff**: Claude writes `HANDOFF.md`, then a fresh session reads it. In `auto` mode a failed `/compact` is remembered in the state file, so later windows go straight to handoff. The `Compact response events:` log line lists the event types received, which helps diagnose a failure.
4. **Run one unit of work** (`-MaxTurns` turns).
5. **On limit hit:** read the reset time, wait until then (+ `-ResetBufferMinutes`), then resume. If the time cannot be read, retry every `-PollMinutes`.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-Prompt` / `-PromptFile` | | Task prompt (new task) |
| `-WorkDir` | current dir | Project folder; state, log and lock files live here |
| `-SessionId` | | Resume this session |
| `-ContinuePrompt` | built-in | Prompt sent on each resume |
| `-DoneMarker` | `TASK_DONE` | Final-line marker that ends the loop |
| `-CompactInstructions` | built-in | What `/compact` should keep |
| `-MaxRuns` | 300 | Max runs (limit waits do not count) |
| `-MaxTurns` | 15 | Turns per run, so quota is checked often |
| `-CompactAtPercent` | 80 | Compact when the 5h quota reaches this % |
| `-UtilizationFormat` | `fraction` | How `utilization` is encoded: `fraction` (0..1) or `percent` (0..100) |
| `-CompactAtLimitFraction` | 0.85 | Fraction of the learned cost level that triggers compact |
| `-MinCompactTokens` | 40000 | Below this, never compact |
| `-HardCompactTokens` | 140000 | Above this, compact regardless of quota |
| `-MaxCompactsPerWindow` | 3 | Cap on repeated hard compacts per window |
| `-CompactMode` | `auto` | `auto`: try `/compact`, remember if it fails and use handoff from then on; `compact`: always try `/compact` first; `handoff`: never try `/compact` |
| `-CompactAtMinutes` | 0 | Time trigger since window start (0 = off) |
| `-ResetBufferMinutes` | 2 | Extra wait after the reset time |
| `-MinWaitSeconds` | 60 | Minimum wait after any limit hit |
| `-PollMinutes` | 15 | Retry interval when the reset time is unreadable |
| `-MaxLimitWaits` | 12 | Consecutive limit waits before giving up |
| `-RunTimeoutMinutes` | 60 | Kill a single `claude` call after this long (0 = no timeout) |
| `-PermissionMode` | `acceptEdits` | Passed to `--permission-mode` |
| `-AllowedTools` | | Passed to `--allowedTools`, e.g. `"Bash Edit Write Read Glob Grep"` |
| `-Model` | | Passed to `--model` |
| `-NoCompact` | off | Never compact |
| `-NoKeepAwake` | off | Do not prevent Windows from sleeping |

## Files created in `-WorkDir`

| File | Purpose |
|---|---|
| `.claude-autoresume.json` | State (session id, window counters, pending handoff). Renamed to `.claude-autoresume.done.json` when the task finishes |
| `.claude-autoresume.log` | Log of everything the script does |
| `.claude-autoresume.lock` | Prevents two instances in the same folder |
| `HANDOFF.md` | Only if the handoff fallback is used |

Consider adding these to `.gitignore`.

## Check your setup

Before trusting it with a long task, do a short dry run:

```powershell
.\claude-autoresume.ps1 -WorkDir D:\scratch -Prompt "Create hello.txt, then reply" -MaxTurns 2
```

Then check the log:

- `rate_limit_event sample:` is present: quota signals work. Look at whether `utilization` exists and whether it is `0..1` or `0..100`, and set `-UtilizationFormat` accordingly.
- `Warning: Claude Code returned no rate_limit_event`: only cost and context signals will drive compaction.
- To exercise the compact path, lower the thresholds, for example `-MinCompactTokens 3000 -CompactAtPercent 5`, with a task that runs several turns. You should see either `Compact done (compact_boundary received ...)` or `Falling back to handoff`.
- `Warning: N tool call(s) denied by permissions`: pass `-AllowedTools` (for example `"Bash Edit Write Read Glob Grep"`), otherwise tools such as `Bash` are denied in headless mode.

## Notifications (optional)

Set these environment variables to get Telegram messages on limit waits, completion and failures:

```powershell
$env:TELEGRAM_BOT_TOKEN = "<bot token>"
$env:TELEGRAM_CHAT_ID   = "<chat id>"
```

## Safety

The script runs Claude unattended with `acceptEdits` and whatever you pass in `-AllowedTools`. If that includes `Bash`, Claude can run commands in the project folder with nobody watching.

- Work on a dedicated git branch so everything is reviewable and revertible.
- Keep `-AllowedTools` as small as the task allows.
- Prefer a VM or a disposable machine for risky tasks.
- Stop it any time with `Ctrl+C`; re-run the same command to continue.

## Known limitations

- Depends on the `stream-json` output and limit messages of Claude Code, which can change between versions. If the reset time cannot be parsed, the script falls back to polling.
- Whether `utilization` is reported, and whether `/compact` works in `-p` mode, depends on your Claude Code version. The script detects and degrades gracefully, but check the log.
- Cost tracking only sees this script's own usage. Other usage on the same Pro account (claude.ai, other terminals) is invisible to it.
- The weekly limit is not handled specially: the script waits for it if the reset time is readable, otherwise gives up after `-MaxLimitWaits` polls.
- The log file can be briefly locked by an editor, antivirus or sync client; the script retries and never crashes because of it, but a few lines may be missing from the file.
- Windows only (PowerShell, `taskkill`, `SetThreadExecutionState`).
- A summary or handoff can lose detail. Tasks that depend on exact earlier context are riskier.
- If `claude` is a `.cmd` shim, `&` or `^` inside `-AllowedTools` may be interpreted by `cmd`. The prompt itself goes through stdin and is unaffected.
