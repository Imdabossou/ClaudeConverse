# voicemode-vulkan

Hands-free voice conversations with [Claude Code](https://claude.com/claude-code) on **Arch Linux**, running locally on **any Vulkan GPU** (AMD, Intel or NVIDIA), with a [Piper](https://github.com/OHF-Voice/piper1-gpl) voice. The default voice is GLaDOS.

You talk, Claude answers out loud, and then it listens again. No keyboard needed.

This is a setup script on top of [VoiceMode](https://github.com/mbailey/voicemode), which does the hard part. It adds the following:

| | VoiceMode on its own | With this setup |
|---|---|---|
| Speech-to-text GPU | NVIDIA (CUDA) or Apple only | **Any Vulkan GPU**: whisper.cpp is rebuilt with `GGML_VULKAN` |
| Voice | Kokoro voices | **Any Piper voice** (GLaDOS by default) through a small OpenAI-compatible server |
| Dictation | Separate | Optionally shares one Whisper with [hyprwhspr](https://github.com/goodroot/hyprwhspr), so only one model sits in VRAM |
| Kokoro on AMD | Uses CUDA PyTorch, so it falls back to a single CPU core | Optional ROCm PyTorch build on the GPU |
| Network | Whisper listens on all interfaces | Localhost only by default |

On a Radeon RX 7900 XTX, transcription takes about 0.1 s, and Claude starts speaking about 0.3 s after its reply is ready. The GLaDOS voice runs on the CPU, so it uses no VRAM. Whisper `base.en` uses a few hundred MB.

## Requirements

- **Arch Linux** (or an Arch-based distro) with systemd
- [Claude Code](https://claude.com/claude-code)
- A Vulkan-capable GPU (optional: `--cpu` works without one)

The installer installs everything else.

### What gets installed, and from where

| Component | Source | Location |
|---|---|---|
| `base-devel git cmake curl uv python ffmpeg portaudio` | official repos (`pacman -S --needed`) | system |
| `shaderc vulkan-headers vulkan-icd-loader` + `vulkan-radeon` / `vulkan-intel` (detected from your GPU) | official repos | system |
| `rocm-hip-runtime` (only with `--kokoro-rocm`) | official repos | system |
| [VoiceMode](https://github.com/mbailey/voicemode) | PyPI via `uv tool`, on Arch's own Python | `~/.local` |
| whisper.cpp (built with Vulkan) | built from source by VoiceMode | `~/.voicemode/services/whisper` |
| piper-tts | PyPI, in a venv on Arch's own Python | `~/.voicemode/services/piper` |
| GLaDOS voice | this repo ([`voices/`](voices/)) | `~/.local/share/piper-voices` |

VoiceMode, whisper.cpp and piper-tts aren't in the official repos (the AUR only has outdated or unrelated builds). So they're installed per user in your home folder, and nothing is pip-installed into system Python or `/usr`. Everything outside pacman's control is removed by `./uninstall.sh`.

## Install

```bash
git clone https://github.com/Imdabossou/voicemode-vulkan
cd voicemode-vulkan
./install.sh
```

The script asks for your password once, for `pacman`, and only if a package is missing. Then start a **new** Claude Code session and run:

```
/voicemode:converse
```

Talk normally. When you pause, your message is sent.

### Options

| Flag | What it does |
|---|---|
| `--hyprwhspr` | Points hyprwhspr dictation at the shared Whisper server. Your old config is backed up. |
| `--whisper-model small.en` | Uses a bigger, more accurate Whisper model. The default is `base.en`. |
| `--kokoro-rocm` | Keeps VoiceMode's Kokoro voices as a fallback, running on an AMD GPU (needs about 1 GB of VRAM). |
| `--voice NAME URL JSON_URL` | Uses a different Piper voice, e.g. from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices). |
| `--cpu` | Skips the Vulkan build. |
| `--lan` | Lets other machines on your network use Whisper. |
| `--sounds` | Keeps VoiceMode's beeps on every tool call during normal (non-voice) chats. They're off by default. |

Example with a standard Piper voice:

```bash
./install.sh --voice amy \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
```

## How it works

```
 mic ──► VoiceMode ──► whisper-server :2022 (Vulkan GPU) ──► text ──► Claude
                                    ▲
             hyprwhspr (optional) ──┘

 Claude ──► VoiceMode ──► piper-server :8881 (CPU) ──► speakers
```

- **Whisper:** VoiceMode installs whisper.cpp, and the script rebuilds it with `-DGGML_VULKAN=ON`. If you have more than one GPU, you can pick one with `GGML_VK_VISIBLE_DEVICES`.
- **Piper:** [`piper-server/server.py`](piper-server/server.py) serves `POST /v1/audio/speech` in OpenAI's format, which is what VoiceMode expects. Piper voices are 16–22 kHz, so the server resamples them to 24 kHz with soxr. Without that, they play too fast and sound crispy.
- Everything runs as systemd user services: `voicemode-whisper` and `voicemode-piper` (plus `voicemode-kokoro` with `--kokoro-rocm`).

## Troubleshooting

```bash
systemctl --user status voicemode-whisper voicemode-piper
journalctl --user -u voicemode-piper -f
voicemode service status
```

- **No sound, or `piper: Unknown option --model`:** on some distros, `piper` is a gaming-mouse configuration tool. This setup uses its own Piper inside `~/.voicemode/services/piper`, so the system command doesn't matter.
- **Whisper uses the wrong GPU:** set `GGML_VK_VISIBLE_DEVICES=0` (or `1`) for the `voicemode-whisper` service.
- **Beeping during normal text chats:** these are VoiceMode's tool-use sounds, which play when a voice conversation *isn't* running. The installer turns them off. Toggle them any time with `voicemode soundfonts off` or `voicemode soundfonts on`.
- **Changes don't apply:** VoiceMode reads `~/.voicemode/voicemode.env` when Claude Code starts, so start a new session.
- **After a VoiceMode update or an Arch Python upgrade** (for example, 3.14 to 3.15): run `./install.sh` again. It rebuilds anything that broke, and leaves the rest alone.

## Uninstall

```bash
./uninstall.sh        # removes this setup and restores hyprwhspr's config; keeps VoiceMode
./uninstall.sh --all  # also removes VoiceMode
```

## Credits and licences

- [VoiceMode](https://github.com/mbailey/voicemode) by Mike Bailey
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts` is GPL-3.0)
- The GLaDOS voice model in [`voices/`](voices/) is from [dnhkng/GlaDOS](https://github.com/dnhkng/GlaDOS) (`glados.onnx`, release 0.1, MIT-licensed project), trained with Piper on Portal 2 voice lines. GLaDOS and Portal belong to Valve; this is a non-commercial fan project.

The scripts in this repo are MIT licensed.
