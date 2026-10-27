# claude-tui-compact

Auto `/compact` before the 5-hour quota runs out, for the interactive [Claude Code](https://docs.claude.com/en/docs/claude-code) TUI on Windows (Pro/Max plan).

Claude Code's own `autoContinueAtUsageLimit` setting already continues a task after a usage limit resets. What it does not do is compact **before** the limit. If the limit is hit while the context is large, the first request after the reset has to reload the whole context into a fresh quota. This script compacts first, so the resume is cheap.

## How it works

One script, wired into Claude Code through `settings.json`:

```
Claude finishes an assistant message
        |
        v
[1] StatusLine  -> saves a snapshot (5h quota %, context tokens) and shows "ctx 45% | 5h 62% | 7d 15%"
        |
Claude runs tools / ends its turn
        |
        v
[2] Hook (PostToolBatch, Stop) reads the snapshot
        |  5h quota >= CompactAtPercent AND context >= MinCompactTokens AND not yet compacted in this 5h window?
        |-- no: nothing happens
        |-- yes:
        v
[3] Inject (hidden helper process)
        types "/compact <instructions>" + Enter into the TUI
        waits for the PostCompact hook
        (if it interrupted a running task) types the continue prompt
```

1. **StatusLine.** Claude Code runs it after every assistant message and passes JSON on stdin (`rate_limits.five_hour.used_percentage`, context size). Hooks do not receive quota data, so the status line is the bridge. The snapshot is saved per session.
2. **Hook.** On `PostToolBatch` and `Stop` it checks the snapshot. It fires at most once per 5h window per session. Contexts below `-MinCompactTokens` are skipped because resuming them is cheap.
3. **Inject.** Hooks cannot run slash commands, so a hidden PowerShell process types the command into the TUI's console (Win32 `AttachConsole` + `WriteConsoleInput`). Text and Enter are sent in separate bursts so Enter submits instead of pasting. If the trigger interrupted a running task (`PostToolBatch` returns `continue: false`), it types the continue prompt after the `PostCompact` hook reports completion. If the trigger came from `Stop`, it only compacts.

`-Mode notify` skips step 3 and only shows a warning asking you to run `/compact` yourself.

## Requirements

- Windows with PowerShell 5.1 or newer
- Claude Code with a status line that exposes `rate_limits` (claude.ai Pro/Max only; the field appears after the first API response of a session)

## Setup

1. Put `claude-tui-compact.ps1` in a fixed folder, for example `D:\tools\`. Do not move it afterwards: its absolute path is written into `settings.json`.

2. Print the settings block:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\claude-tui-compact.ps1                 # automatic mode (types /compact for you)
   .\claude-tui-compact.ps1 -Mode notify    # warning only
   ```

3. Merge the printed `statusLine` and `hooks` into one of these files (merge, do not overwrite existing keys):

   | File | Scope |
   |---|---|
   | `%USERPROFILE%\.claude\settings.json` | All projects |
   | `<project>\.claude\settings.local.json` | One project, only your machine (recommended for per-project use) |
   | `<project>\.claude\settings.json` | One project, shared with the team (only if the script has the same path on every machine) |

4. Enable auto-continue in your **user** settings (`%USERPROFILE%\.claude\settings.json`). It is not read from project settings:

   ```json
   { "autoContinueAtUsageLimit": true }
   ```

5. Restart Claude Code. After the first assistant message the bottom of the TUI should show `ctx 12% | 5h 34% | 7d 15%`. `n/a` for 5h means `rate_limits` is not available yet.

Notes on scopes:
- Hooks add up across scopes. If both user and project settings contain them, they run twice per event. The once-per-window guard prevents a double compact, but keep them in one place.
- `statusLine` in a project overrides the user one for that project.
- Project hooks only run after you trust the project folder.
- If you already have a status line, keep yours and add the snapshot-saving part, otherwise this script replaces it.

## Try it

Lower the thresholds to see it fire quickly:

```powershell
.\claude-tui-compact.ps1 -Mode notify -CompactAtPercent 5 -MinCompactTokens 3000
```

Merge it into `settings.json`, restart Claude Code, and let Claude work until the context passes 3000 tokens. The status line shows `| compact due` and you get a message like:

```
PostToolBatch says: autoresume: 5h quota 22%, context 48,518 tokens. Run /compact now so the resume after the reset is cheap.
```

Then switch to automatic mode (no `-Mode notify`) with a low threshold, confirm that `/compact` is typed and submitted for you, and finally go back to the defaults (80%, 40000 tokens). To retrigger in the same 5h window, delete `%USERPROFILE%\.claude\autoresume\<session-id>.state.json` or start a new session.

## Options

They are embedded in the commands printed by the script, so pass them when you print the settings block.

| Parameter | Default | Meaning |
|---|---|---|
| `-Mode` | `inject` | `inject` types `/compact` for you, `notify` only warns |
| `-CompactAtPercent` | 80 | Compact when the 5h quota reaches this % |
| `-MinCompactTokens` | 40000 | Below this context size, never compact |
| `-CompactInstructions` | built-in | Text passed to `/compact` (what to keep) |
| `-ContinuePrompt` | built-in | Typed after a compact that interrupted a running task |
| `-InjectDelaySeconds` | 3 | Wait before typing, so the TUI is idle |
| `-CompactTimeoutMinutes` | 10 | How long to wait for `PostCompact` |
| `-DataDir` | `%USERPROFILE%\.claude\autoresume` | Snapshots, state, signal files, log |

## Files

In `%USERPROFILE%\.claude\autoresume\`:

| File | Purpose |
|---|---|
| `autoresume.log` | Every decision and any typing failure |
| `<session>.json` | Latest quota/context snapshot |
| `<session>.state.json` | Which 5h window already triggered a compact |
| `<session>.compacted` | Signal written by the `PostCompact` hook |

## Troubleshooting

- **Status line shows nothing:** check the script path in `settings.json`, and restart Claude Code.
- **`5h n/a`:** `rate_limits` is only present for Pro/Max accounts and only after the first API response.
- **Nothing happens at the threshold:** read `autoresume.log`; confirm the thresholds, and that this 5h window has not already triggered (see the state file).
- **`AttachConsole failed` / `WriteConsoleInput failed` in the log:** your terminal does not accept the typed input. Use `-Mode notify`.
- **Disable:** remove the `statusLine` and `hooks` blocks you added.

## Limitations

- Typing into the TUI is experimental and has not been verified with every terminal (Windows Terminal, conhost, VS Code terminal).
- If you are typing in the prompt box at the moment of injection, the text can mix. The trigger fires at the end of a turn or tool batch, so the TUI is usually idle.
- `continue: false` on `PostToolBatch` interrupts a running task at a tool-batch boundary; the helper then types the continue prompt after the compact.
- Compacts once per 5h window per session.
