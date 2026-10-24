#!/usr/bin/env bash
# Undo install.sh. VoiceMode itself is left installed unless you pass --all.
set -uo pipefail
UNIT_DIR="$HOME/.config/systemd/user"
VM_ENV="$HOME/.voicemode/voicemode.env"

echo "Removing the Piper TTS service..."
systemctl --user disable --now voicemode-piper 2>/dev/null
rm -f "$UNIT_DIR/voicemode-piper.service"
rm -rf "$HOME/.voicemode/services/piper"

echo "Removing the VoiceMode server, remote tunnels and /converse..."
for u in "$UNIT_DIR"/voicemode-tunnel@*.service; do
  [[ -e "$u" ]] || continue
  systemctl --user disable --now "$(basename "$u")" 2>/dev/null
  rm -f "$u"
done
systemctl --user disable --now voicemode-serve 2>/dev/null
claude mcp remove --scope user voicemode >/dev/null 2>&1
rm -f "$HOME/.claude/commands/converse.md"
[[ -f "$VM_ENV" ]] && sed -i '/^VOICEMODE_SERVE_\(HOST\|PORT\|TOKEN\)=/d' "$VM_ENV"
rm -f "$HOME/.voicemode/serve-token"

echo "Removing the Kokoro ROCm override..."
rm -rf "$UNIT_DIR/voicemode-kokoro.service.d/amd-gpu.conf" "$HOME/.voicemode/services/kokoro/start-rocm.sh"
systemctl --user daemon-reload

cfg="$HOME/.config/hyprwhspr/config.json"
if [[ -f "$cfg.before-voicemode" ]]; then
  echo "Restoring hyprwhspr's original config..."
  mv "$cfg.before-voicemode" "$cfg"
  systemctl --user restart hyprwhspr 2>/dev/null
fi

[[ -f "$VM_ENV" ]] && sed -i '/^VOICEMODE_TTS_BASE_URLS=/d; /^VOICEMODE_VOICES=/d' "$VM_ENV"

if [[ "${1:-}" == "--all" ]]; then
  echo "Removing VoiceMode completely..."
  for s in whisper kokoro; do systemctl --user disable --now "voicemode-$s" 2>/dev/null; done
  claude plugin uninstall voicemode@voicemode 2>/dev/null
  uv tool uninstall voice-mode 2>/dev/null
  rm -rf "$HOME/.voicemode"
fi

echo "Done. Voice files in ~/.local/share/piper-voices and ~/.ssh/voicemode_tunnel were kept."
echo "Remote machines keep their /converse command and MCP entry; see ./connect-remote.sh --remove."
