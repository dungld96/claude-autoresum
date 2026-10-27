# tui-compact

A Claude Code plugin (Windows, Pro/Max) that runs `/compact` for you **before** your 5-hour quota runs out.

Why: if you hit the usage limit while the context is big, the first request after the reset has to reload all of it into a fresh quota. Compacting first keeps that cheap. Claude Code's own `autoContinueAtUsageLimit` setting already continues the task after the reset; this plugin covers the part before it.

## Install

In Claude Code:

```
/plugin marketplace add dungld96/claude-autoresum
/plugin install tui-compact@autoresume-tools
/tui-compact:setup
```

Then restart Claude Code. After the first reply, the bottom of the TUI shows:

```
ctx 12% | 5h 34% | 7d 15%
```

`/tui-compact:setup` adds the status line (plugins cannot ship one) and turns on `autoContinueAtUsageLimit`. An existing status line is kept and shown too. A `.bak` of your `settings.json` is saved.

Use `/tui-compact:setup project` to set it up for the current project only.

## What it does

When the 5h quota reaches **80%** and the context is at least **40,000 tokens**, it compacts once per 5h window:

- If Claude is busy, it pauses at the next tool boundary, compacts, then tells Claude to continue.
- If Claude is idle, it just compacts.

Hooks cannot run slash commands, so a hidden helper types `/compact ...` into the TUI for you.

## Settings

Open `/plugin`, pick `tui-compact`, and change the options. The defaults work without touching anything.

| Option | Default | Meaning |
|---|---|---|
| Mode | `inject` | `inject` types `/compact` for you. `notify` only shows a warning and you run `/compact` yourself. |
| Compact at 5h quota % | 80 | Quota level that triggers a compact. |
| Minimum context tokens | 40000 | Below this, nothing is compacted. |
| Compact instructions | built-in | What `/compact` should keep. |
| Continue prompt | built-in | Typed after a compact that interrupted a running task. |

## Try it quickly

Set Mode to `notify`, quota to 5 and tokens to 3000. After some work you will see:

```
PostToolBatch says: autoresume: 5h quota 22%, context 48,518 tokens. Run /compact now ...
```

Then switch Mode to `inject` and check that `/compact` is typed and sent by itself. Put the defaults back afterwards. It triggers once per 5h window per session; to retry, start a new session or delete `%USERPROFILE%\.claude\autoresume\<session-id>.state.json`.

## Remove

```
/tui-compact:remove
```

then disable or uninstall the plugin in `/plugin`.

## Troubleshooting

- Status line shows nothing: run `/tui-compact:setup` again and restart Claude Code.
- `5h n/a`: quota info only exists for Pro/Max accounts, after the first reply of a session.
- Nothing happens at the threshold: read `%USERPROFILE%\.claude\autoresume\autoresume.log`.
- `AttachConsole failed` or `WriteConsoleInput failed` in the log: your terminal does not accept typed input. Set Mode to `notify`.

## Limitations

- Typing into the TUI is experimental and may not work in every terminal.
- If you are typing in the prompt box at that moment, the text can mix. It triggers at the end of a turn or tool batch, so usually Claude is idle.
- One compact per 5h window per session.
- Enable the plugin once, either for all projects or per project. Do not also paste your own hooks, or they run twice.
