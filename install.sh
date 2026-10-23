#!/usr/bin/env bash
# Hands-free voice conversations with Claude Code on Arch Linux,
# GPU-accelerated on any Vulkan GPU (AMD, Intel, NVIDIA), with the GLaDOS voice.
#
# System packages come from the official Arch repos (pacman). Software that
# isn't packaged for Arch (VoiceMode, whisper.cpp, piper-tts) is installed per
# user under ~/.voicemode and ~/.local, never into system Python or /usr.
set -euo pipefail

# ---------------------------------------------------------------- options
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_NAME="glados"
VOICE_SRC="$REPO_DIR/voices/en_US-glados-medium.onnx"
VOICE_JSON_SRC="$VOICE_SRC.json"
WHISPER_MODEL="base.en"
USE_VULKAN=1
HYPRWHSPR=0
KOKORO_ROCM=0
LAN=0
SOUNDS=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --voice NAME URL JSON_URL  Use another Piper voice instead of GLaDOS
                             (e.g. from huggingface.co/rhasspy/piper-voices)
  --whisper-model MODEL      Whisper model (default: base.en; e.g. small.en, large-v3-turbo)
  --cpu                      Don't build Whisper with Vulkan (CPU only)
  --hyprwhspr                Point hyprwhspr dictation at the same Whisper server
  --kokoro-rocm              Keep VoiceMode's Kokoro TTS as a fallback, on an AMD GPU (ROCm)
  --lan                      Let other machines on your network use Whisper (default: localhost only)
  --sounds                   Keep VoiceMode's beeps on every tool call (off by default)
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --voice) VOICE_NAME="$2"; VOICE_SRC="$3"; VOICE_JSON_SRC="$4"; shift 4 ;;
    --whisper-model) WHISPER_MODEL="$2"; shift 2 ;;
    --cpu) USE_VULKAN=0; shift ;;
    --hyprwhspr) HYPRWHSPR=1; shift ;;
    --kokoro-rocm) KOKORO_ROCM=1; shift ;;
    --lan) LAN=1; shift ;;
    --sounds) SOUNDS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

VM_DIR="$HOME/.voicemode"
VM_ENV="$VM_DIR/voicemode.env"
WHISPER_DIR="$VM_DIR/services/whisper"
PIPER_DIR="$VM_DIR/services/piper"
KOKORO_DIR="$VM_DIR/services/kokoro"
VOICE_DIR="$HOME/.local/share/piper-voices"
UNIT_DIR="$HOME/.config/systemd/user"
export PATH="$HOME/.local/bin:$PATH"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
# Hide VoiceMode's noisy Python warnings
vm()   { voicemode "$@" 2>&1 | grep -vE 'SyntaxWarning|re\.match|^\s*$|dependencies.checker' || true; }

# Set KEY=VALUE in voicemode.env, replacing an existing uncommented line
set_env() {
  mkdir -p "$VM_DIR"; touch "$VM_ENV"
  if grep -q "^$1=" "$VM_ENV"; then
    sed -i "s|^$1=.*|$1=$2|" "$VM_ENV"
  else
    echo "$1=$2" >> "$VM_ENV"
  fi
}

# Copy a local file or download a URL
fetch() {
  if [[ -f "$1" ]]; then cp "$1" "$2"; else curl -fL --progress-bar -o "$2" "$1"; fi
}

# ---------------------------------------------------------------- packages
step "Installing system packages from the Arch repos"
[[ -f /etc/arch-release ]] || die "this script is for Arch Linux (and derivatives)"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (sudo is used for pacman)"

pkgs=(base-devel git cmake curl uv python ffmpeg portaudio)
if [[ $USE_VULKAN == 1 ]]; then
  pkgs+=(shaderc vulkan-headers vulkan-icd-loader)
  gpus=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)
  if grep -qiE 'amd|ati' <<<"$gpus"; then pkgs+=(vulkan-radeon); fi
  if grep -qi 'intel' <<<"$gpus"; then pkgs+=(vulkan-intel); fi
  if grep -qi 'nvidia' <<<"$gpus" && ! pacman -Qq nvidia-utils >/dev/null 2>&1; then
    warn "NVIDIA GPU found: install your NVIDIA driver (nvidia-utils) for Vulkan"
  fi
fi
if [[ $KOKORO_ROCM == 1 ]]; then pkgs+=(rocm-hip-runtime); fi

# pacman -T prints the ones that aren't installed yet
mapfile -t need < <(pacman -T "${pkgs[@]}" || true)
if (( ${#need[@]} )); then
  sudo pacman -S --needed "${need[@]}"
fi
ok "${#pkgs[@]} packages present"

command -v claude >/dev/null || die "Claude Code not found: install it first (https://claude.com/claude-code)"
systemctl --user show-environment >/dev/null 2>&1 || die "systemd user services are required"

# ---------------------------------------------------------------- VoiceMode
step "Installing VoiceMode (not in the Arch repos: per-user, via uv)"
# After an Arch Python upgrade the old tool env breaks; --reinstall rebuilds it
reinstall=(); voicemode --version >/dev/null 2>&1 || reinstall=(--reinstall)
uv tool install -q "${reinstall[@]}" --python /usr/bin/python3 voice-mode 2>&1 | grep -v 'already installed' || true
command -v voicemode >/dev/null || die "voicemode CLI not found after install"
ok "voicemode $(voicemode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

step "Installing the VoiceMode Claude Code plugin"
claude plugin marketplace add mbailey/voicemode >/dev/null 2>&1 || true
claude plugin install voicemode@voicemode 2>&1 | tail -1

# ---------------------------------------------------------------- Whisper
step "Installing whisper.cpp ($WHISPER_MODEL)"
# 'voicemode whisper install' is deprecated, but it is the only form that takes --no-gpu/--model
vm whisper install --no-gpu --model "$WHISPER_MODEL" | grep -vE 'Progress:|Deprecated' | tail -3 || true
[[ -x "$WHISPER_DIR/build/bin/whisper-server" ]] || die "whisper.cpp install failed"
set_env VOICEMODE_WHISPER_MODEL "$WHISPER_MODEL"

if [[ $USE_VULKAN == 1 ]]; then
  step "Rebuilding whisper.cpp with Vulkan (VoiceMode only builds for CUDA/Metal)"
  (cd "$WHISPER_DIR" &&
    cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null 2>&1 &&
    cmake --build build -j"$(nproc)" --config Release >/dev/null) || die "Vulkan build failed (try --cpu)"
  ok "built with Vulkan"
fi

if [[ $LAN == 0 ]]; then
  sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/' "$WHISPER_DIR/bin/start-whisper-server.sh"
  ok "Whisper only accepts connections from this machine"
fi

vm service enable whisper >/dev/null
systemctl --user restart voicemode-whisper

# ---------------------------------------------------------------- Piper
step "Installing Piper TTS with the '$VOICE_NAME' voice (per-user venv on system Python)"
mkdir -p "$PIPER_DIR" "$VOICE_DIR" "$UNIT_DIR"
# Recreate the venv if it's missing or broken by an Arch Python upgrade
"$PIPER_DIR/.venv/bin/python" -c 'import sys' 2>/dev/null || uv venv -q --clear --python /usr/bin/python3 "$PIPER_DIR/.venv"
uv pip install -q --python "$PIPER_DIR/.venv/bin/python" piper-tts
install -m 755 "$REPO_DIR/piper-server/server.py" "$PIPER_DIR/server.py"

voice_file="$VOICE_DIR/en_US-$VOICE_NAME-medium.onnx"
fetch "$VOICE_SRC" "$voice_file"
fetch "$VOICE_JSON_SRC" "$voice_file.json"
ok "voice at $voice_file"

sed "s/@VOICE@/$VOICE_NAME/" "$REPO_DIR/systemd/voicemode-piper.service" > "$UNIT_DIR/voicemode-piper.service"
systemctl --user daemon-reload
systemctl --user enable voicemode-piper >/dev/null 2>&1
systemctl --user restart voicemode-piper

# ---------------------------------------------------------------- Kokoro
tts_urls="http://127.0.0.1:8881/v1"
voices="$VOICE_NAME"
if [[ $KOKORO_ROCM == 1 ]]; then
  step "Installing Kokoro on the AMD GPU (ROCm)"
  [[ -d "$KOKORO_DIR" ]] || vm service install kokoro | tail -2
  # Kokoro pins torch 2.6 in its own venv, so it needs PyTorch's ROCm wheel
  # rather than Arch's python-pytorch-rocm
  uv pip install -q --python "$KOKORO_DIR/.venv/bin/python" "torch==2.6.0+rocm6.2.4" \
    --index-url https://download.pytorch.org/whl/rocm6.2.4
  # Same as VoiceMode's start-gpu.sh, minus the step that reinstalls CUDA torch
  # shellcheck disable=SC2016  # ${HIP_VISIBLE_DEVICES...} is meant for the generated script
  sed -e 's|^uv pip install -e ".\[gpu\]"|export HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-0}|' \
    "$KOKORO_DIR/start-gpu.sh" > "$KOKORO_DIR/start-rocm.sh"
  chmod +x "$KOKORO_DIR/start-rocm.sh"
  mkdir -p "$UNIT_DIR/voicemode-kokoro.service.d"
  cp "$REPO_DIR/systemd/kokoro-rocm.conf" "$UNIT_DIR/voicemode-kokoro.service.d/amd-gpu.conf"
  systemctl --user daemon-reload
  vm service enable kokoro >/dev/null
  systemctl --user restart voicemode-kokoro
  tts_urls="$tts_urls,http://127.0.0.1:8880/v1"
  voices="$voices,af_sky"
  ok "Kokoro runs as a fallback voice"
elif [[ -f "$UNIT_DIR/voicemode-kokoro.service" ]]; then
  systemctl --user disable --now voicemode-kokoro >/dev/null 2>&1 || true
fi

set_env VOICEMODE_TTS_BASE_URLS "$tts_urls"
set_env VOICEMODE_VOICES "$voices"
# VoiceMode's plugin beeps on every tool call whenever a voice conversation
# *isn't* running, i.e. during normal text chats. Off unless asked for.
if [[ $SOUNDS == 1 ]]; then
  set_env VOICEMODE_SOUNDFONTS_ENABLED true
  rm -f "$VM_DIR/soundfonts-disabled"
else
  set_env VOICEMODE_SOUNDFONTS_ENABLED false
fi

# ---------------------------------------------------------------- hyprwhspr
if [[ $HYPRWHSPR == 1 ]]; then
  step "Connecting hyprwhspr to the shared Whisper server"
  cfg="$HOME/.config/hyprwhspr/config.json"
  [[ -f "$cfg" ]] || die "hyprwhspr config not found at $cfg"
  [[ -f "$cfg.before-voicemode" ]] || cp "$cfg" "$cfg.before-voicemode"
  python3 - "$cfg" <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["transcription_backend"] = "rest-api"
c["rest_endpoint_url"] = "http://127.0.0.1:2022/v1/audio/transcriptions"
json.dump(c, open(p, "w"), indent=2)
EOF
  systemctl --user restart hyprwhspr 2>/dev/null || warn "restart hyprwhspr yourself"
  ok "backup saved as $cfg.before-voicemode"
fi

# ---------------------------------------------------------------- verify
step "Testing"
for _ in $(seq 30); do
  curl -fs -o /dev/null http://127.0.0.1:8881/health && curl -fs -o /dev/null http://127.0.0.1:2022/ && break
  sleep 1
done
tmp="$(mktemp --suffix .wav)"
trap 'rm -f "$tmp"' EXIT
if curl -fs -X POST http://127.0.0.1:8881/v1/audio/speech -H 'Content-Type: application/json' \
    -d "{\"input\":\"Testing the voice setup.\",\"voice\":\"$VOICE_NAME\",\"response_format\":\"wav\"}" -o "$tmp"; then
  ok "speech generated"
else
  die "Piper server not responding (journalctl --user -u voicemode-piper)"
fi
if text=$(curl -fs http://127.0.0.1:2022/v1/audio/transcriptions -F file=@"$tmp" -F model=whisper-1); then
  ok "Whisper heard: $text"
else
  die "Whisper not responding (journalctl --user -u voicemode-whisper)"
fi
if [[ $USE_VULKAN == 1 ]]; then
  gpu=$(journalctl --user -u voicemode-whisper --since "-5min" --no-pager 2>/dev/null |
        grep -m1 -oP 'ggml_vulkan: 0 = \K[^(]+' || true)
  if [[ -n "$gpu" ]]; then ok "Whisper GPU: $gpu"; else warn "couldn't confirm the Vulkan GPU from the logs"; fi
fi

cat <<EOF

$(printf '\033[1;32mDone!\033[0m') Start a new Claude Code session and run:

    /voicemode:converse

Talk normally; pausing sends your message.
EOF
