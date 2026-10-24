#!/usr/bin/env bash
# Let Claude Code on another machine (a server, a mini PC, ...) talk to you
# through THIS machine's microphone, speakers and GPU.
#
#   remote Claude ──► 127.0.0.1:PORT on the remote
#        ──(SSH reverse tunnel, started from here)──► VoiceMode on 127.0.0.1:8765 here
#
# Run ./install.sh on this machine first. The remote only needs Claude Code
# and an SSH server; nothing else is installed there.
#
# Usage: ./connect-remote.sh user@host [remote-port]      (default port: 18765)
#        ./connect-remote.sh --remove user@host
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="$HOME/.ssh/voicemode_tunnel"
TOKEN_FILE="$HOME/.voicemode/serve-token"
UNIT_DIR="$HOME/.config/systemd/user"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✔\033[0m %s\n' "$*"; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

REMOVE=0
if [[ "${1:-}" == "--remove" ]]; then REMOVE=1; shift; fi
TARGET="${1:-}"
PORT="${2:-18765}"
[[ "$TARGET" == *@* ]] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
# One tunnel unit per remote, e.g. voicemode-tunnel@claude-192.168.0.8
UNIT="voicemode-tunnel@${TARGET//@/-}.service"

if [[ $REMOVE == 1 ]]; then
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  echo "Tunnel to $TARGET removed."
  echo "On $TARGET, you can also run: claude mcp remove --scope user voicemode"
  echo "and delete ~/.claude/commands/converse.md and the 'voicemode-tunnel@' line in ~/.ssh/authorized_keys."
  exit 0
fi

[[ -s "$TOKEN_FILE" ]] || die "run ./install.sh on this machine first"
systemctl --user is-active -q voicemode-serve || die "voicemode-serve isn't running (systemctl --user start voicemode-serve)"

# ---------------------------------------------------------------- key
step "Creating an SSH key for the tunnel"
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "voicemode-tunnel@$(cat /etc/hostname 2>/dev/null || uname -n)" -f "$KEY"
ok "$KEY"

ssh_r() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$@"; }

# 0 = full shell access, 255 = key not authorised yet,
# anything else = key already restricted to the tunnel by an earlier run
rc=0; ssh_r true 2>/dev/null || rc=$?
if [[ $rc == 255 ]]; then
  step "Authorising the key on $TARGET (type its password once)"
  ssh-copy-id -i "$KEY.pub" "$TARGET"
  rc=0; ssh_r true 2>/dev/null || rc=$?
  [[ $rc == 0 ]] || die "still can't log in to $TARGET with the key"
fi

# ---------------------------------------------------------------- remote side
if [[ $rc != 0 ]]; then
  ok "$TARGET was already set up by an earlier run (key restricted); only restarting the tunnel"
else
step "Setting up Claude Code on $TARGET"
ssh_r bash -s -- "$PORT" "$(cat "$TOKEN_FILE")" "$(base64 -w0 "$REPO_DIR/commands/converse.md")" <<'EOF'
set -e
port=$1; token=$2
export PATH="$HOME/.local/bin:$PATH"
command -v claude >/dev/null || { echo "Claude Code isn't installed on this machine"; exit 1; }
if ss -ltn | grep -q "[:.]$port "; then echo "port $port is already in use here; pick another: ./connect-remote.sh user@host OTHER_PORT"; exit 1; fi
claude mcp remove --scope user voicemode >/dev/null 2>&1 || true
claude mcp add --scope user --transport http voicemode "http://127.0.0.1:$port/mcp" \
  --header "Authorization: Bearer $token" >/dev/null
mkdir -p ~/.claude/commands
echo "$3" | base64 -d > ~/.claude/commands/converse.md
echo "    registered VoiceMode on 127.0.0.1:$port and added /converse"
EOF

step "Restricting the key to this tunnel only (no shell)"
ssh_r bash -s -- "$PORT" <<'EOF'
f=~/.ssh/authorized_keys
cp "$f" "$f.bak-voicemode"
sed -i "/voicemode-tunnel@/{/^restrict/!s|^|restrict,port-forwarding,permitlisten=\"127.0.0.1:$1\",command=\"/usr/bin/false\" |}" "$f"
EOF
ok "the key can now only forward 127.0.0.1:$PORT (backup: ~/.ssh/authorized_keys.bak-voicemode)"
fi

# ---------------------------------------------------------------- tunnel
step "Starting the tunnel (reconnects automatically, starts at login)"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=VoiceMode tunnel: $TARGET 127.0.0.1:$PORT -> this machine's VoiceMode (127.0.0.1:8765)
After=network-online.target voicemode-serve.service
Wants=voicemode-serve.service

[Service]
ExecStart=/usr/bin/ssh -N -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes \\
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \\
  -R 127.0.0.1:$PORT:127.0.0.1:8765 $TARGET
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null 2>&1
systemctl --user restart "$UNIT"
sleep 5
systemctl --user is-active -q "$UNIT" || die "tunnel didn't start (journalctl --user -u '$UNIT')"
ok "$UNIT is running"

cat <<EOF

$(printf '\033[1;32mDone!\033[0m') On $TARGET, start a NEW Claude Code session and run:

    /converse

It speaks and listens through this machine, so this machine must be on.
The first time, allow the "voicemode converse" tool when asked.
EOF
