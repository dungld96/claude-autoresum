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

## Two ways to run it

Both use the same script, `plugins/tui-compact/scripts/claude-tui-compact.ps1`.

| | A. Plugin (recommended) | B. Standalone script |
|---|---|---|
| Hooks | Come with the plugin, updated with it | You merge them into `settings.json` yourself |
| Status line | One command: `/tui-compact:setup` | Part of the merged block |
| Settings (threshold, mode, ...) | `/plugin` configuration dialog | Parameters in the printed commands |
| Per project | Enable the plugin at project scope | Put the block in the project's `settings.local.json` |

### Requirements

- Windows with PowerShell 5.1 or newer
- Claude Code with a status line that exposes `rate_limits` (claude.ai Pro/Max only; the field appears after the first API response of a session)
- Option A also needs Claude Code 2.1.275 or later for the one-line install below

### Option A: plugin

1. Install from this repository:

   ```
   /plugin marketplace add dungld96/claude-autoresum
   /plugin install tui-compact@autoresume-tools
   ```

   On Claude Code 2.1.275 or later you can also run `claude plugin install tui-compact --marketplace dungld96/claude-autoresum`. Claude Code asks for the plugin options (mode, thresholds, texts); the defaults are fine.

2. Run the one-time setup skill inside Claude Code:

   ```
   /tui-compact:setup            # user scope (all projects), also enables autoContinueAtUsageLimit
   /tui-compact:setup project    # or: project / local scope (needs the project folder as working directory)
   ```

   Plugins cannot ship a main status line, so this step writes it into `settings.json` (a `.bak` backup is written next to it). If you already have a status line, it is kept and chained: its output is still shown, and the `ctx | 5h | 7d` line is added after it. The script is copied to `%USERPROFILE%\.claude\autoresume\` so the status line keeps working after plugin updates.

3. Restart Claude Code. After the first assistant message the bottom of the TUI shows `ctx 12% | 5h 34% | 7d 15%`.

To remove: `/tui-compact:remove` (restores a chained status line), then disable or uninstall the plugin in `/plugin`.

Change the thresholds later in `/plugin` (plugin options). Hooks and status line pick them up; the status line uses the values the hook last saw.

### Option B: standalone script

1. Put `claude-tui-compact.ps1` (from `plugins/tui-compact/scripts/`) in a fixed folder, for example `D:\tools\`. Do not move it afterwards: its absolute path is written into `settings.json`.

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

5. Restart Claude Code and check the status line as above.

Notes on scopes (both options):
- Hooks add up across scopes. If the plugin and a hand-merged block are both active, they run twice per event. The once-per-window guard prevents a double compact, but use one option only.
- `statusLine` in a project overrides the user one for that project.
- Project hooks only run after you trust the project folder.
- `autoContinueAtUsageLimit` is only read from user settings.

## Try it

Lower the thresholds to see it fire quickly. With the plugin, set `Mode` to `notify`, `Compact at 5h quota %` to 5 and `Minimum context tokens` to 3000 in `/plugin`; with the standalone script, print the block like this:

```powershell
.\claude-tui-compact.ps1 -Mode notify -CompactAtPercent 5 -MinCompactTokens 3000
```

Merge it into `settings.json`, restart Claude Code, and let Claude work until the context passes 3000 tokens. The status line shows `| compact due` and you get a message like:

```
PostToolBatch says: autoresume: 5h quota 22%, context 48,518 tokens. Run /compact now so the resume after the reset is cheap.
```

Then switch to automatic mode (no `-Mode notify`) with a low threshold, confirm that `/compact` is typed and submitted for you, and finally go back to the defaults (80%, 40000 tokens). To retrigger in the same 5h window, delete `%USERPROFILE%\.claude\autoresume\<session-id>.state.json` or start a new session.

## Options

In option A they are plugin options (`/plugin`). In option B they are embedded in the commands printed by the script, so pass them when you print the settings block.

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
| `config.json` | Thresholds last seen by the hook, and a chained previous status line |
| `claude-tui-compact.ps1` | Stable copy of the script used by the status line (option A) |

## Troubleshooting

- **Status line shows nothing:** check the script path in `settings.json` (option B) or run `/tui-compact:setup` again (option A), and restart Claude Code.
- **`5h n/a`:** `rate_limits` is only present for Pro/Max accounts and only after the first API response.
- **Nothing happens at the threshold:** read `autoresume.log`; confirm the thresholds, and that this 5h window has not already triggered (see the state file).
- **`AttachConsole failed` / `WriteConsoleInput failed` in the log:** your terminal does not accept the typed input. Use `-Mode notify`.
- **Disable:** option A: `/tui-compact:remove` and disable the plugin. Option B: remove the `statusLine` and `hooks` blocks you added.

## Limitations

- Typing into the TUI is experimental and has not been verified with every terminal (Windows Terminal, conhost, VS Code terminal).
- If you are typing in the prompt box at the moment of injection, the text can mix. The trigger fires at the end of a turn or tool batch, so the TUI is usually idle.
- `continue: false` on `PostToolBatch` interrupts a running task at a tool-batch boundary; the helper then types the continue prompt after the compact.
- Compacts once per 5h window per session.
