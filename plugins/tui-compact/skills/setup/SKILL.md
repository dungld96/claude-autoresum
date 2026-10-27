---
name: setup
description: One-time setup for tui-compact. Adds the status line that reads the 5h quota, and turns on autoContinueAtUsageLimit. Run once after installing the plugin.
disable-model-invocation: true
argument-hint: "[user|project|local]"
---

Run this command with the Bash tool, then show its output to the user unchanged. Use the scope given in the arguments (`user`, `project` or `local`); if no argument was given, use `user`.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/claude-tui-compact.ps1" -Action Install -Scope <scope>
```

Arguments: $ARGUMENTS

Afterwards tell the user to restart Claude Code, and that after the first assistant reply the bottom of the TUI should show `ctx ... | 5h ... | 7d ...`. Mention that an existing status line was kept and chained, and that a backup of the settings file was written next to it as `.bak`.
