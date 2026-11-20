# Using ClaudeConverse

## Talking

Run `/converse` in a **new** Claude Code session. Talk after the rising chime. When you pause, a falling chime plays and your words go to Claude. Say "end voice mode" to stop.

The first time, Claude Code asks for permission to use the `converse` tool; choose "always allow" for hands-free use.

## Settings

`~/.config/claude-converse/converse.env`, then `systemctl --user restart claude-converse`:

| Setting | Default | What it does |
|---|---|---|
| `CONVERSE_VOICE` | `glados` | Default voice (any `.onnx` in `~/.local/share/claude-converse/voices`) |
| `CONVERSE_SILENCE` | `1.2` | Seconds of silence that end your turn |
| `CONVERSE_VAD` | `2` | Speech detection strictness, `0` (lenient) to `3` (strict) |
| `CONVERSE_CHIMES` | `1` | `0` turns off the "your turn" / "got it" chimes |
| `CONVERSE_HOLD` | `30` | Seconds one Claude session keeps the floor between turns |

To change the Whisper model or GPU backend, use `hyprwhspr setup`.

## Another voice

```bash
./install.sh --voice amy \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
```

## Talking to Claude Code on another machine

If you run Claude Code on a server or mini PC (for example, through Remote Control), it can use **this** machine's mic, speakers and hyprwhspr:

```bash
./connect-remote.sh user@192.168.1.50
```

The remote machine only needs Claude Code and an SSH server. Nothing else is installed there: no Whisper, no GPU and no audio.

```
 remote: Claude ──► 127.0.0.1:18765 ─┐
                                     │ SSH reverse tunnel, started from this machine
 this machine:  converse :8765 ◄─────┘──► mic, speakers, hyprwhspr, Piper
```

What the script does:

1. **Creates a dedicated SSH key** (`~/.ssh/claude_converse_tunnel`). You type the remote machine's password once, for `ssh-copy-id`.
2. **Sets up the remote's Claude Code:** it registers the `converse` MCP server at `http://127.0.0.1:18765/mcp` with the login token, and adds the same `/converse` command.
3. **Locks the key down:** on the remote, it's restricted to `restrict,port-forwarding,permitlisten="127.0.0.1:18765",command="/usr/bin/false"`, so it can hold open this one tunnel but can't open a shell. A backup of `authorized_keys` is kept.
4. **Starts the tunnel** as a systemd user service (`claude-converse-tunnel@user-host`) that starts at login and reconnects automatically.

Then start a **new** Claude Code session on the remote and run `/converse`.

- **Port in use?** Pick another: `./connect-remote.sh user@host 18766`.
- **This machine must be on**, because that's where the audio and GPU are.
- **Rerunning** is safe. Once the key is restricted, the script only restarts the tunnel.
- **Removing:** `./connect-remote.sh --remove user@host`.
- **One at a time:** if this machine and a remote both start talking, the second waits until the first conversation pauses for longer than `CONVERSE_HOLD`.

## Troubleshooting

```bash
systemctl --user status claude-converse hyprwhspr 'claude-converse-tunnel@*'
journalctl --user -u claude-converse -f
~/.local/share/claude-converse/venv/bin/python ~/.local/share/claude-converse/server.py --selftest
```

- **"hyprwhspr not reachable":** hyprwhspr isn't running: `systemctl --user start hyprwhspr`.
- **"Cannot transcribe a file while recording":** hyprwhspr was busy with a dictation. Finish it and speak again.
- **It cuts you off, or waits too long:** raise or lower `CONVERSE_SILENCE`. If background noise counts as speech, raise `CONVERSE_VAD`.
- **Wrong mic or speakers:** the server uses your system's default devices. Change them in your sound settings, then restart `claude-converse`.
- **`/converse` says it can't connect:** check that `claude-converse` is running. On a remote, also check its tunnel on this machine: `journalctl --user -u 'claude-converse-tunnel@*'`.
- **After an Arch Python upgrade** (for example, 3.14 to 3.15): run `./install.sh` again to rebuild the venv.
- **`piper: Unknown option --model`:** on Arch, the `piper` command is a gaming-mouse configuration tool. This project uses its own Piper library inside the venv, so the system command doesn't matter.

## What gets installed, and from where

| Component | Source | Location |
|---|---|---|
| `python uv portaudio curl` | official repos (`pacman -S --needed`) | system |
| `piper-tts sounddevice webrtcvad-wheels mcp` | PyPI, in a venv on Arch's own Python | `~/.local/share/claude-converse/venv` |
| converse server ([`converse-server/server.py`](converse-server/server.py)) | this repo | `~/.local/share/claude-converse` |
| GLaDOS voice | this repo ([`voices/`](voices/)) | `~/.local/share/claude-converse/voices` |
| settings and login token | created by the installer | `~/.config/claude-converse` |
| `/converse` command | this repo ([`commands/`](commands/)) | `~/.claude/commands` |

Nothing is pip-installed into system Python or `/usr`, and hyprwhspr's config isn't changed. `./uninstall.sh` removes everything above except the pacman packages.

## Uninstall

```bash
./uninstall.sh   # removes the server, tunnels, /converse and its files; keeps hyprwhspr
```
