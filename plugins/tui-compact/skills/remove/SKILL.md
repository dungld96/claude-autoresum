---
name: remove
description: Remove the tui-compact status line from settings.json (restores a previously chained status line). Disable or uninstall the plugin separately to stop the hooks.
disable-model-invocation: true
argument-hint: "[user|project|local]"
---

Run this command with the Bash tool, then show its output to the user unchanged. Use the scope given in the arguments (`user`, `project` or `local`); if no argument was given, use `user`.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/claude-tui-compact.ps1" -Action Uninstall -Scope <scope>
```

Arguments: $ARGUMENTS

Remind the user that the hooks stay active until the plugin is disabled (`/plugin`), and that `autoContinueAtUsageLimit` was left unchanged.
