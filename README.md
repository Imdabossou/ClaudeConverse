# <img src="assets/claudeconverse.png" width="36" align="top" alt=""> ClaudeConverse

**Hands-free voice conversations with [Claude Code](https://claude.com/claude-code) on Arch Linux.**

Type `/converse` and just talk. Claude answers out loud, then listens again. No keyboard needed.

## Features

- **Uses the dictation you already have**: [hyprwhspr](https://github.com/goodroot/hyprwhspr)'s Whisper model handles both your hotkey and voice chats, so no second model is loaded
- **Fast**: about 0.1 s to transcribe a sentence on a modern GPU, and replies start playing after the first sentence
- **Natural voices** with [Piper](https://github.com/OHF-Voice/piper1-gpl): GLaDOS by default, or any Piper voice. Runs on the CPU, no VRAM
- **Talk to Claude Code on other machines**, like a home server, through this computer's mic and speakers
- **Small and contained**: one Python file in its own venv, reachable only from this computer

## Install

You need Arch Linux (or an Arch-based distro) with PipeWire or PulseAudio, Claude Code, and hyprwhspr set up (`yay -S hyprwhspr && hyprwhspr setup`).

```bash
git clone https://github.com/Imdabossou/ClaudeConverse
cd ClaudeConverse
./install.sh
```

> **Note:** when Arch upgrades Python to a new version (for example 3.14 to 3.15), `/converse` stops working until you run `./install.sh` again. It rebuilds the venv and keeps your settings (if you chose another voice, pass the same `--voice` option again).

Then start a new Claude Code session and run `/converse`. The [user guide](docs/guide.md) covers settings, other voices, remote machines and troubleshooting.

## Credits and licence

- [hyprwhspr](https://github.com/goodroot/hyprwhspr), which provides speech-to-text through [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts` is GPL-3.0) and [webrtcvad](https://github.com/wiseman/py-webrtcvad)
- The [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- Inspired by [VoiceMode](https://github.com/mbailey/voicemode) by Mike Bailey
- The GLaDOS voice model in [`voices/`](voices/) is from [dnhkng/GlaDOS](https://github.com/dnhkng/GlaDOS) (`glados.onnx`, release 0.1, MIT-licensed project), trained with Piper on Portal 2 voice lines. GLaDOS and Portal belong to Valve; this is a non-commercial fan project.

The code is licensed under the [GPL-3.0-or-later](LICENSE). How it works and how to work on it: [BUILDING.md](BUILDING.md).
