# SpectiX plugin

Installs the status hooks that drive **[SpectiX](https://spectix.app)** — a macOS menu bar app
that shows the live state of every Claude Code session you have open: which one is waiting on your
approval, which is still working, which finished, which is idle. Click a session and it jumps you to
that exact terminal pane.

This plugin is the wiring only. **You also need the app**, which is a separate download:
<https://spectix.app>

---

## What it does

It registers seven hooks. Each one writes a small plain-text file under `~/.claude/spectix/`,
keyed by the terminal's tty, which the menu bar app reads:

| Hook | Writes | Meaning |
|---|---|---|
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | `working` | the model is busy |
| `Stop` | `done` | the turn ended, it's your turn |
| `PermissionRequest` / `Notification` | `needs` | a permission prompt is up |
| `SessionStart` | `idle` | fresh or just-cleared session |

`PermissionRequest` fires the moment the dialog appears, which is the point of the whole design:
the "needs you" signal arrives in real time rather than being inferred after the fact.

## What it does not do

- **No network access.** The hooks only write files inside your home directory. Nothing is uploaded,
  and there is no telemetry in this plugin.
- **No reading of your conversations for anything but the local status row.** The `Stop` hook tallies
  the turn's token counts from the local transcript to render the elapsed-time / token column, and
  that stays on your machine.
- **No modification of your Claude Code config.** Installing via the plugin does not touch
  `~/.claude/settings.json`.

## Requirements and limits

- **macOS 13.0+**, and the SpectiX app installed.
- **Terminal sessions only.** State is keyed by the session's controlling tty — the hook walks up the
  parent process chain to find the terminal that owns the `claude` process. **In a host that does not
  allocate a pty, the hook exits without writing anything and the session simply will not appear in
  the menu bar.** It fails silent rather than showing a wrong status, but "absent" is a real limitation
  worth knowing before you install.
- The subscription-usage figures in the app header come from a throttled `claude -p "/usage"` call at
  most once every two minutes, on turn end. Everything else is free — the hooks do no work of their own.

## Do not install this twice

The SpectiX app's own installer offers to wire the same hooks directly into
`~/.claude/settings.json`. **Use one path or the other, not both.** If both are active every event
reaches the hook twice; the state files are written idempotently so the menu bar stays correct, but
you are paying for the duplicate work for nothing.

If you already installed via the app's installer and want to switch to the plugin, remove the
`spectix-status.sh` entries from the `hooks` block of `~/.claude/settings.json` first (the
installer's uninstall button does this for you).

## Install

```
/plugin marketplace add spectix-lab/spectix-plugin
/plugin install spectix
```

Then restart your Claude Code sessions (or run `/clear`) so the hooks take effect.

## License

FSL-1.1-ALv2 (Functional Source License), like the rest of SpectiX — see [LICENSE](../LICENSE).
