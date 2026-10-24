#!/usr/bin/env bash
# Hands-free voice conversations with Claude Code on Arch Linux, with the
# GLaDOS voice. Speech-to-text comes from hyprwhspr, which you already use for
# dictation: one Whisper model, loaded once (on your GPU if hyprwhspr uses it),
# serves both.
#
# System packages come from the official Arch repos (pacman). Software that
# isn't packaged for Arch (VoiceMode, piper-tts) is installed per user under
# ~/.voicemode and ~/.local, never into system Python or /usr.
set -euo pipefail

# ---------------------------------------------------------------- options
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_NAME="glados"
VOICE_SRC="$REPO_DIR/voices/en_US-glados-medium.onnx"
VOICE_JSON_SRC="$VOICE_SRC.json"
KOKORO_ROCM=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --voice NAME URL JSON_URL  Use another Piper voice instead of GLaDOS
                             (e.g. from huggingface.co/rhasspy/piper-voices)
  --kokoro-rocm              Keep VoiceMode's Kokoro TTS as a fallback, on an AMD GPU (ROCm)
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --voice) VOICE_NAME="$2"; VOICE_SRC="$3"; VOICE_JSON_SRC="$4"; shift 4 ;;
    --kokoro-rocm) KOKORO_ROCM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

VM_DIR="$HOME/.voicemode"
VM_ENV="$VM_DIR/voicemode.env"
HYPR_CFG="$HOME/.config/hyprwhspr/config.json"
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

pkgs=(base-devel git curl uv python ffmpeg portaudio)
if [[ $KOKORO_ROCM == 1 ]]; then pkgs+=(rocm-hip-runtime); fi

# pacman -T prints the ones that aren't installed yet
mapfile -t need < <(pacman -T "${pkgs[@]}" || true)
if (( ${#need[@]} )); then
  sudo pacman -S --needed "${need[@]}"
fi
ok "${#pkgs[@]} packages present"

command -v claude >/dev/null || die "Claude Code not found: install it first (https://claude.com/claude-code)"
command -v hyprwhspr >/dev/null && [[ -f "$HYPR_CFG" ]] ||
  die "hyprwhspr is required for speech-to-text. Install it from the AUR (e.g. 'yay -S hyprwhspr'), run 'hyprwhspr setup', then rerun this script"
systemctl --user show-environment >/dev/null 2>&1 || die "systemd user services are required"

# ---------------------------------------------------------------- VoiceMode
step "Installing VoiceMode (not in the Arch repos: per-user, via uv)"
# After an Arch Python upgrade the old tool env breaks; --reinstall rebuilds it
reinstall=(); voicemode --version >/dev/null 2>&1 || reinstall=(--reinstall)
uv tool install -q "${reinstall[@]}" --python /usr/bin/python3 voice-mode 2>&1 | grep -v 'already installed' || true
command -v voicemode >/dev/null || die "voicemode CLI not found after install"
ok "voicemode $(voicemode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

step "Connecting Claude Code to VoiceMode"
# VoiceMode runs as a local HTTP server (localhost only, token login), so this
# machine and remote ones (see ./connect-remote.sh) connect the same way and
# share one /converse command. The VoiceMode plugin isn't used: its command
# would be /voicemode:converse, and it beeps on every tool call.
token_file="$VM_DIR/serve-token"
[[ -s "$token_file" ]] || (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$token_file")
set_env VOICEMODE_SERVE_HOST 127.0.0.1
set_env VOICEMODE_SERVE_PORT 8765
set_env VOICEMODE_SERVE_TOKEN "$(cat "$token_file")"
chmod 600 "$VM_ENV"
vm service install voicemode >/dev/null
vm service enable voicemode >/dev/null
systemctl --user restart voicemode-serve

claude plugin disable voicemode@voicemode >/dev/null 2>&1 || true
claude mcp remove --scope user voicemode >/dev/null 2>&1 || true
claude mcp add --scope user --transport http voicemode http://127.0.0.1:8765/mcp \
  --header "Authorization: Bearer $(cat "$token_file")" >/dev/null
mkdir -p "$HOME/.claude/commands"
cp "$REPO_DIR/commands/converse.md" "$HOME/.claude/commands/converse.md"
ok "/converse command installed; VoiceMode server on 127.0.0.1:8765"

# ---------------------------------------------------------------- hyprwhspr
step "Using hyprwhspr for speech-to-text"
# Older versions of this script pointed hyprwhspr at a separate Whisper server; undo that
if [[ -f "$HYPR_CFG.before-voicemode" ]] && grep -q '127.0.0.1:2022' "$HYPR_CFG"; then
  mv "$HYPR_CFG.before-voicemode" "$HYPR_CFG"
  systemctl --user restart hyprwhspr 2>/dev/null || true
  ok "restored hyprwhspr's own Whisper backend"
fi
backend=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("transcription_backend","pywhispercpp"))' "$HYPR_CFG")
[[ $backend == realtime-ws ]] && die "hyprwhspr's realtime-ws backend can't transcribe for VoiceMode; pick another in 'hyprwhspr setup'"
systemctl --user enable hyprwhspr >/dev/null 2>&1 || true
systemctl --user is-active -q hyprwhspr || systemctl --user restart hyprwhspr
ok "hyprwhspr backend: $backend"
# ...and switch off the separate Whisper server those versions installed
if [[ -f "$UNIT_DIR/voicemode-whisper.service" ]]; then
  systemctl --user disable --now voicemode-whisper >/dev/null 2>&1 || true
  ok "old separate Whisper server switched off (remove ~/.voicemode/services/whisper to reclaim space)"
fi
# The Piper server's /v1/audio/transcriptions forwards to hyprwhspr's control socket
set_env VOICEMODE_STT_BASE_URLS http://127.0.0.1:8881/v1

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
systemctl --user restart voicemode-serve   # it reads voicemode.env at start

# ---------------------------------------------------------------- verify
step "Testing"
for _ in $(seq 30); do
  curl -fs -o /dev/null http://127.0.0.1:8881/health && break
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
text=""
for _ in 1 2 3; do
  text=$(curl -fs http://127.0.0.1:8881/v1/audio/transcriptions -F file=@"$tmp" -F model=whisper-1) && break
  sleep 5
done
if [[ -n "$text" ]]; then
  ok "hyprwhspr heard: $text"
elif [[ "$(cat "$HOME/.config/hyprwhspr/recording_status" 2>/dev/null)" == true ]]; then
  warn "hyprwhspr is busy recording dictation, so the speech-to-text test was skipped"
else
  die "hyprwhspr didn't transcribe (is its model loaded? journalctl --user -u hyprwhspr)"
fi

cat <<EOF

$(printf '\033[1;32mDone!\033[0m') Start a new Claude Code session and run:

    /converse

Talk normally; pausing sends your message. The first time, allow the
"voicemode converse" tool when Claude Code asks.

To talk to Claude Code on another machine through this one's mic and
speakers, see ./connect-remote.sh.
EOF
