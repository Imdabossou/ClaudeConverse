#!/usr/bin/env bash
# claude-hyprwhspr-converse: hands-free voice conversations with Claude Code on
# Arch Linux. Speech-to-text comes from hyprwhspr (the Whisper you already run
# for dictation), replies are spoken with Piper (GLaDOS by default).
#
# System packages come from the official Arch repos (pacman). The server and
# its few Python packages go in a per-user venv on Arch's own Python, under
# ~/.local/share/claude-converse; nothing is pip-installed into /usr.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/claude-converse"
CONF_DIR="$HOME/.config/claude-converse"
UNIT_DIR="$HOME/.config/systemd/user"
HYPR_CFG="$HOME/.config/hyprwhspr/config.json"
PORT=8765

VOICE_NAME="glados"
VOICE_SRC="$REPO_DIR/voices/en_US-glados-medium.onnx"
VOICE_JSON_SRC="$VOICE_SRC.json"

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --voice NAME URL JSON_URL  Use another Piper voice instead of GLaDOS
                             (e.g. from huggingface.co/rhasspy/piper-voices)
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --voice) VOICE_NAME="$2"; VOICE_SRC="$3"; VOICE_JSON_SRC="$4"; shift 4 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Copy a local file or download a URL
fetch() {
  if [[ -f "$1" ]]; then cp "$1" "$2"; else curl -fL --progress-bar -o "$2" "$1"; fi
}

# ---------------------------------------------------------------- checks
step "Checking requirements"
[[ -f /etc/arch-release ]] || die "this script is for Arch Linux (and derivatives)"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (sudo is used for pacman)"
command -v claude >/dev/null || die "Claude Code not found: install it first (https://claude.com/claude-code)"
command -v hyprwhspr >/dev/null && [[ -f "$HYPR_CFG" ]] ||
  die "hyprwhspr is required for speech-to-text. Install it from the AUR (e.g. 'yay -S hyprwhspr'), run 'hyprwhspr setup', then rerun this script"
systemctl --user show-environment >/dev/null 2>&1 || die "systemd user services are required"

backend=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("transcription_backend","pywhispercpp"))' "$HYPR_CFG")
[[ $backend != realtime-ws ]] || die "hyprwhspr's realtime-ws backend can't transcribe for this; pick another in 'hyprwhspr setup'"
systemctl --user enable hyprwhspr >/dev/null 2>&1 || true
systemctl --user is-active -q hyprwhspr || systemctl --user restart hyprwhspr
ok "hyprwhspr ($backend backend)"

pkgs=(python uv portaudio curl)
# pacman -T prints the ones that aren't installed yet
mapfile -t need < <(pacman -T "${pkgs[@]}" || true)
if (( ${#need[@]} )); then
  sudo pacman -S --needed "${need[@]}"
fi
ok "packages: ${pkgs[*]}"

# ---------------------------------------------------------------- server
step "Installing the converse server"
mkdir -p "$APP_DIR/voices" "$CONF_DIR" "$UNIT_DIR"
# Recreate the venv if it's missing or broken by an Arch Python upgrade
"$APP_DIR/venv/bin/python" -c 'import sys' 2>/dev/null || uv venv -q --clear --python /usr/bin/python3 "$APP_DIR/venv"
uv pip install -q --python "$APP_DIR/venv/bin/python" piper-tts sounddevice webrtcvad-wheels "mcp>=2,<3"
install -m 755 "$REPO_DIR/converse-server/server.py" "$APP_DIR/server.py"
ok "$APP_DIR"

voice_file="$APP_DIR/voices/en_US-$VOICE_NAME-medium.onnx"
fetch "$VOICE_SRC" "$voice_file"
fetch "$VOICE_JSON_SRC" "$voice_file.json"
ok "voice: $VOICE_NAME"

[[ -s "$CONF_DIR/token" ]] || (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$CONF_DIR/token")
if [[ ! -f "$CONF_DIR/converse.env" ]]; then
  cat > "$CONF_DIR/converse.env" <<EOF
# claude-converse settings; restart after editing: systemctl --user restart claude-converse
CONVERSE_VOICE=$VOICE_NAME
# Seconds of silence that end your turn
CONVERSE_SILENCE=1.2
# Speech detection strictness, 0 (lenient) to 3 (strict)
CONVERSE_VAD=2
# 0 turns off the "your turn" / "got it" chimes
CONVERSE_CHIMES=1
EOF
else
  sed -i "s/^CONVERSE_VOICE=.*/CONVERSE_VOICE=$VOICE_NAME/" "$CONF_DIR/converse.env"
fi

cp "$REPO_DIR/systemd/claude-converse.service" "$UNIT_DIR/claude-converse.service"
systemctl --user daemon-reload
systemctl --user enable claude-converse >/dev/null 2>&1
systemctl --user restart claude-converse

# ---------------------------------------------------------------- Claude Code
step "Connecting Claude Code"
claude mcp remove --scope user converse >/dev/null 2>&1 || true
claude mcp add --scope user --transport http converse "http://127.0.0.1:$PORT/mcp" \
  --header "Authorization: Bearer $(cat "$CONF_DIR/token")" >/dev/null
mkdir -p "$HOME/.claude/commands"
cp "$REPO_DIR/commands/converse.md" "$HOME/.claude/commands/converse.md"
ok "MCP server 'converse' and the /converse command"

# ---------------------------------------------------------------- verify
step "Testing"
for _ in $(seq 30); do
  curl -fs -o /dev/null "http://127.0.0.1:$PORT/health" && break
  sleep 1
done
curl -fs -o /dev/null "http://127.0.0.1:$PORT/health" || die "server didn't start (journalctl --user -u claude-converse)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp")
[[ $code == 401 ]] || die "server accepted a request without the token (HTTP $code)"
ok "server running on 127.0.0.1:$PORT, token required"

result=""
for _ in 1 2 3; do
  result=$(CONVERSE_VOICE_DIR="$APP_DIR/voices" CONVERSE_VOICE="$VOICE_NAME" \
    "$APP_DIR/venv/bin/python" "$APP_DIR/server.py" --selftest 2>/dev/null) && break
  sleep 5
done
if [[ -n "$result" ]]; then
  ok "Piper spoke and hyprwhspr heard: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["heard"])' "$result")"
elif [[ "$(cat "$HOME/.config/hyprwhspr/recording_status" 2>/dev/null)" == true ]]; then
  warn "hyprwhspr is busy recording dictation, so the speech-to-text test was skipped"
else
  die "speech test failed: $(CONVERSE_VOICE_DIR="$APP_DIR/voices" "$APP_DIR/venv/bin/python" "$APP_DIR/server.py" --selftest 2>&1 | tail -1)"
fi

cat <<EOF

$(printf '\033[1;32mDone!\033[0m') Start a new Claude Code session and run:

    /converse

Talk after the rising chime; pausing ends your turn. The first time, allow
the "converse" tool when Claude Code asks. Settings: $CONF_DIR/converse.env

To talk to Claude Code on another machine through this one's mic and
speakers, see ./connect-remote.sh.
EOF
