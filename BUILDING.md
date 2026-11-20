# Building ClaudeConverse

There's nothing to compile. ClaudeConverse is one Python MCP server, a few shell scripts and a systemd user unit. `./install.sh` sets everything up from your clone, so after a change, run it again and restart the service:

```bash
./install.sh
systemctl --user restart claude-converse
```

## Checks

CI runs:

```bash
python3 -m py_compile converse-server/server.py
pipx run ruff check --select E9,F converse-server
shellcheck -S error *.sh
```

On a set-up machine, the server also has a self-test that checks Piper can speak and hyprwhspr can hear it:

```bash
~/.local/share/claude-converse/venv/bin/python ~/.local/share/claude-converse/server.py --selftest
```

## Files

| Path | What |
| --- | --- |
| `converse-server/server.py` | The MCP server: speech output, recording, speech detection and the hyprwhspr hand-off |
| `install.sh`, `uninstall.sh` | Set up and remove everything in the user's home folder |
| `connect-remote.sh` | Sets up another machine to use this one's audio over a locked-down SSH tunnel |
| `systemd/claude-converse.service` | The user service |
| `commands/converse.md` | The `/converse` command for Claude Code |
| `voices/` | The default GLaDOS Piper voice |

## How it works

```
 Dictation hotkey ───────────────────────────► hyprwhspr (Whisper, GPU) ──► types text
 Claude ──► converse tool ──► Piper ──► speakers           ▲
                         └──► mic ──► speech detection ────┘ (transcribe_file) ──► text ──► Claude
```

A `converse(message)` call:

1. **Speaks** `message` with Piper, sentence by sentence: the next sentence is synthesised while the current one plays.
2. **Plays a rising chime** and records 16 kHz audio from the default mic. [webrtcvad](https://github.com/wiseman/py-webrtcvad) detects when you start talking and when you've paused.
3. **Plays a falling chime** and hands the recording to hyprwhspr through its control socket (`$XDG_RUNTIME_DIR/hyprwhspr/hyprwhspr.sock`, `transcribe_file`). The text comes back to Claude; nothing is typed. hyprwhspr does one thing at a time, so if you're mid-dictation, it waits a few seconds and tries again.

The server speaks MCP over streamable HTTP on `127.0.0.1:8765`. Every request needs the token in `~/.config/claude-converse/token`, and nothing is reachable from your network. It runs as the systemd user service `claude-converse`.
