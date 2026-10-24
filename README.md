# claude-hyprwhspr-converse

Hands-free voice conversations with [Claude Code](https://claude.com/claude-code) on **Arch Linux**. Type `/converse` and just talk: Claude answers out loud, then listens again. No keyboard needed.

- **Hears you with [hyprwhspr](https://github.com/goodroot/hyprwhspr)**, the dictation tool you already run. Its Whisper model (GPU-accelerated on AMD, Intel or NVIDIA) serves both your dictation hotkey and voice chats, so no second model is loaded.
- **Answers with a [Piper](https://github.com/OHF-Voice/piper1-gpl) voice:** GLaDOS by default, or any Piper voice. It runs on the CPU and uses no VRAM.
- **Works with Claude Code on other machines**, like a home server driven through Remote Control. They talk through your desktop's mic and speakers.

It's one small server (one Python file and four Python packages) that Claude Code connects to as an MCP server. On a Radeon RX 7900 XTX, hyprwhspr transcribes a sentence in about 0.1 s, and replies start playing as soon as the first sentence is synthesised.

## Requirements

- **Arch Linux** (or an Arch-based distro) with systemd and PipeWire or PulseAudio
- [Claude Code](https://claude.com/claude-code)
- [hyprwhspr](https://github.com/goodroot/hyprwhspr), installed and set up. It's in the AUR:

  ```bash
  yay -S hyprwhspr
  hyprwhspr setup     # pick a GPU backend, e.g. vulkan for AMD/Intel
  ```

  Any hyprwhspr backend works except `realtime-ws`.

### What gets installed, and from where

| Component | Source | Location |
|---|---|---|
| `python uv portaudio curl` | official repos (`pacman -S --needed`) | system |
| `piper-tts sounddevice webrtcvad-wheels mcp` | PyPI, in a venv on Arch's own Python | `~/.local/share/claude-converse/venv` |
| converse server ([`converse-server/server.py`](converse-server/server.py)) | this repo | `~/.local/share/claude-converse` |
| GLaDOS voice | this repo ([`voices/`](voices/)) | `~/.local/share/claude-converse/voices` |
| settings and login token | created by the installer | `~/.config/claude-converse` |
| `/converse` command | this repo ([`commands/`](commands/)) | `~/.claude/commands` |

Nothing is pip-installed into system Python or `/usr`, and hyprwhspr's config isn't changed. `./uninstall.sh` removes everything above except the pacman packages.

## Install

```bash
git clone https://github.com/Imdabossou/claude-hyprwhspr-converse
cd claude-hyprwhspr-converse
./install.sh
```

The script asks for your password once, for `pacman`, and only if a package is missing. At the end, it checks that Piper can speak and hyprwhspr can hear it. Then start a **new** Claude Code session and run:

```
/converse
```

Talk after the rising chime. When you pause, a falling chime plays and your words go to Claude. Say "end voice mode" to stop. The first time, Claude Code asks for permission to use the `converse` tool; choose "always allow" for hands-free use.

### Another voice

```bash
./install.sh --voice amy \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
```

### Settings

`~/.config/claude-converse/converse.env`, then `systemctl --user restart claude-converse`:

| Setting | Default | What it does |
|---|---|---|
| `CONVERSE_VOICE` | `glados` | Default voice (any `.onnx` in `~/.local/share/claude-converse/voices`) |
| `CONVERSE_SILENCE` | `1.2` | Seconds of silence that end your turn |
| `CONVERSE_VAD` | `2` | Speech detection strictness, `0` (lenient) to `3` (strict) |
| `CONVERSE_CHIMES` | `1` | `0` turns off the "your turn" / "got it" chimes |
| `CONVERSE_HOLD` | `30` | Seconds one Claude session keeps the floor between turns |

To change the Whisper model or GPU backend, use `hyprwhspr setup`.

## Talking to Claude Code on another machine

If you run Claude Code on a server or mini PC (for example, through Remote Control), it can use **this** machine's mic, speakers and hyprwhspr:

```bash
./connect-remote.sh user@192.168.0.8
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

## Uninstall

```bash
./uninstall.sh   # removes the server, tunnels, /converse and its files; keeps hyprwhspr
```

## Credits and licences

- [hyprwhspr](https://github.com/goodroot/hyprwhspr), which provides speech-to-text through [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts` is GPL-3.0) and [webrtcvad](https://github.com/wiseman/py-webrtcvad)
- The [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- Inspired by [VoiceMode](https://github.com/mbailey/voicemode) by Mike Bailey
- The GLaDOS voice model in [`voices/`](voices/) is from [dnhkng/GlaDOS](https://github.com/dnhkng/GlaDOS) (`glados.onnx`, release 0.1, MIT-licensed project), trained with Piper on Portal 2 voice lines. GLaDOS and Portal belong to Valve; this is a non-commercial fan project.

The code in this repo is MIT licensed.
