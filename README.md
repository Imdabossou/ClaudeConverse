# claude-hyprwhspr-converse

Hands-free voice conversations with [Claude Code](https://claude.com/claude-code) on **Arch Linux**, using the [hyprwhspr](https://github.com/goodroot/hyprwhspr) dictation you already run for speech-to-text, and a [Piper](https://github.com/OHF-Voice/piper1-gpl) voice for replies. The default voice is GLaDOS.

You talk, Claude answers out loud, and then it listens again. No keyboard needed. It also works with Claude Code running on **another machine**, like a home server, which then speaks and listens through your desktop.

This is a setup script on top of [VoiceMode](https://github.com/mbailey/voicemode), which runs the conversation loop. It adds the following:

| | VoiceMode on its own | With this setup |
|---|---|---|
| Speech-to-text | Builds its own whisper.cpp server: GPU only on NVIDIA (CUDA) or Apple | **Uses hyprwhspr's Whisper.** hyprwhspr does GPU acceleration on AMD, Intel or NVIDIA (e.g. Vulkan), and one model serves both F13-style dictation and voice chats. No second Whisper is built or loaded. |
| Voice | Kokoro voices | **Any Piper voice** (GLaDOS by default) through a small OpenAI-compatible server |
| Kokoro on AMD | Uses CUDA PyTorch, so it falls back to a single CPU core | Optional ROCm PyTorch build on the GPU |
| Command | `/voicemode:converse` (plugin) | `/converse`, the same on every machine |
| Remote machines | Manual setup | `./connect-remote.sh user@host`: SSH tunnel with a restricted key |

On a Radeon RX 7900 XTX with hyprwhspr's Vulkan backend, transcription takes about 0.1 s, and Claude starts speaking about 0.3 s after its reply is ready. The GLaDOS voice runs on the CPU, so it uses no VRAM. The only model in VRAM is hyprwhspr's.

## Requirements

- **Arch Linux** (or an Arch-based distro) with systemd
- [Claude Code](https://claude.com/claude-code)
- [hyprwhspr](https://github.com/goodroot/hyprwhspr), installed and set up. It's in the AUR:

  ```bash
  yay -S hyprwhspr
  hyprwhspr setup     # pick a GPU backend, e.g. vulkan for AMD/Intel
  ```

  Any hyprwhspr backend works except `realtime-ws`.

The installer installs everything else.

### What gets installed, and from where

| Component | Source | Location |
|---|---|---|
| `base-devel git curl uv python ffmpeg portaudio` | official repos (`pacman -S --needed`) | system |
| `rocm-hip-runtime` (only with `--kokoro-rocm`) | official repos | system |
| [VoiceMode](https://github.com/mbailey/voicemode) | PyPI via `uv tool`, on Arch's own Python | `~/.local` |
| piper-tts | PyPI, in a venv on Arch's own Python | `~/.voicemode/services/piper` |
| GLaDOS voice | this repo ([`voices/`](voices/)) | `~/.local/share/piper-voices` |
| `/converse` command | this repo ([`commands/`](commands/)) | `~/.claude/commands` |

VoiceMode and piper-tts aren't in the official repos (the AUR only has outdated or unrelated builds). So they're installed per user in your home folder, and nothing is pip-installed into system Python or `/usr`. Everything outside pacman's control is removed by `./uninstall.sh`. hyprwhspr's own config isn't changed.

## Install

```bash
git clone https://github.com/Imdabossou/claude-hyprwhspr-converse
cd claude-hyprwhspr-converse
./install.sh
```

The script asks for your password once, for `pacman`, and only if a package is missing. Then start a **new** Claude Code session and run:

```
/converse
```

Talk normally. When you pause, your message is sent. Say "end voice mode" to stop. The first time, Claude Code asks for permission to use the `voicemode` converse tool; choose "always allow" for hands-free use.

### Options

| Flag | What it does |
|---|---|
| `--voice NAME URL JSON_URL` | Uses a different Piper voice, e.g. from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). |
| `--kokoro-rocm` | Keeps VoiceMode's Kokoro voices as a fallback, running on an AMD GPU (needs about 1 GB of VRAM). |

Example with a standard Piper voice:

```bash
./install.sh --voice amy \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
```

To change the Whisper model or GPU backend, use `hyprwhspr setup`: VoiceMode follows whatever hyprwhspr uses.

## Talking to Claude Code on another machine

If you run Claude Code on a server or mini PC (for example, through Remote Control), it can use **this** machine's microphone, speakers and hyprwhspr:

```bash
./connect-remote.sh user@192.168.0.8
```

The remote machine only needs Claude Code and an SSH server. Nothing else is installed there: no Whisper, no GPU and no audio.

```
 remote: Claude ──► 127.0.0.1:18765 ─┐
                                     │ SSH reverse tunnel, started from this machine
 this machine:  VoiceMode :8765 ◄────┘──► mic, speakers, hyprwhspr, Piper
```

What the script does:

1. **Creates a dedicated SSH key** (`~/.ssh/voicemode_tunnel`). You type the remote machine's password once, for `ssh-copy-id`.
2. **Sets up the remote's Claude Code:** it registers the `voicemode` MCP server at `http://127.0.0.1:18765/mcp` with the login token, and adds the same `/converse` command.
3. **Locks the key down:** on the remote, it's restricted to `restrict,port-forwarding,permitlisten="127.0.0.1:18765",command="/usr/bin/false"`, so it can hold open this one tunnel but can't open a shell. A backup of `authorized_keys` is kept.
4. **Starts the tunnel** as a systemd user service (`voicemode-tunnel@user-host`) that starts at login and reconnects automatically.

Then start a **new** Claude Code session on the remote and run `/converse`.

- **Port in use?** Pick another: `./connect-remote.sh user@host 18766`.
- **This machine must be on**, because that's where the audio and GPU are.
- **Rerunning** is safe. Once the key is restricted, the script only restarts the tunnel.
- **Removing:** `./connect-remote.sh --remove user@host`.
- **Security:** VoiceMode only listens on `127.0.0.1` and requires a token (`~/.voicemode/serve-token`). The tunnel is the only way in from the remote, and nothing is opened on your network.

## How it works

```
 F13 (dictation) ──────────────────────────► hyprwhspr (Whisper, GPU) ──► types text
 mic ──► VoiceMode ──► piper-server :8881 ──┘ (asks hyprwhspr) ──► text ──► Claude

 Claude ──► VoiceMode ──► piper-server :8881 (Piper, CPU) ──► speakers
```

- **VoiceMode** runs as a local HTTP server (`voicemode-serve`, `127.0.0.1:8765`, token login). Claude Code connects to it as an MCP server the same way on this machine and on remote ones. The VoiceMode plugin isn't used: its command is `/voicemode:converse`, and it plays a sound on every tool call during normal text chats.
- **Speech-to-text:** hyprwhspr keeps its Whisper model loaded for dictation and accepts `transcribe_file` requests on its control socket (`$XDG_RUNTIME_DIR/hyprwhspr/hyprwhspr.sock`). [`piper-server/server.py`](piper-server/server.py) offers an OpenAI-style `POST /v1/audio/transcriptions` that forwards to it, so VoiceMode can use it. Results only come back to VoiceMode; nothing is typed. hyprwhspr does one thing at a time, so if you're mid-dictation, it waits a few seconds and tries again.
- **Voice:** the same server offers `POST /v1/audio/speech` with Piper. Piper voices are 16–22 kHz, so it resamples them to 24 kHz with soxr. Without that, they play too fast and sound crispy.
- Everything runs as systemd user services: `voicemode-serve` and `voicemode-piper`, alongside your existing `hyprwhspr` (plus `voicemode-kokoro` with `--kokoro-rocm`, and one `voicemode-tunnel@…` per remote).

## Troubleshooting

```bash
systemctl --user status hyprwhspr voicemode-serve voicemode-piper 'voicemode-tunnel@*'
journalctl --user -u voicemode-piper -f
```

- **No sound, or `piper: Unknown option --model`:** on some distros, `piper` is a gaming-mouse configuration tool. This setup uses its own Piper inside `~/.voicemode/services/piper`, so the system command doesn't matter.
- **"Cannot transcribe a file while recording":** hyprwhspr was busy with a dictation. Finish it and speak again.
- **"hyprwhspr not reachable":** hyprwhspr isn't running: `systemctl --user start hyprwhspr`.
- **`/converse` says it can't connect:** check that `voicemode-serve` is running. On a remote, also check its tunnel on this machine: `journalctl --user -u 'voicemode-tunnel@*'`.
- **Changed the voice or other settings:** run `systemctl --user restart voicemode-serve`, then start a new Claude Code session.
- **After a VoiceMode update or an Arch Python upgrade** (for example, 3.14 to 3.15): run `./install.sh` again. It rebuilds anything that broke, and leaves the rest alone.

## Uninstall

```bash
./uninstall.sh        # removes this setup, tunnels and /converse; keeps VoiceMode and hyprwhspr
./uninstall.sh --all  # also removes VoiceMode
```

## Credits and licences

- [VoiceMode](https://github.com/mbailey/voicemode) by Mike Bailey
- [hyprwhspr](https://github.com/goodroot/hyprwhspr), which provides speech-to-text through [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts` is GPL-3.0)
- The GLaDOS voice model in [`voices/`](voices/) is from [dnhkng/GlaDOS](https://github.com/dnhkng/GlaDOS) (`glados.onnx`, release 0.1, MIT-licensed project), trained with Piper on Portal 2 voice lines. GLaDOS and Portal belong to Valve; this is a non-commercial fan project.

The scripts in this repo are MIT licensed.
