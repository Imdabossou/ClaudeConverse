#!/usr/bin/env bash
# Undo install.sh and any ./connect-remote.sh tunnels. hyprwhspr is left alone.
set -uo pipefail
UNIT_DIR="$HOME/.config/systemd/user"

echo "Stopping the converse server and remote tunnels..."
for u in "$UNIT_DIR"/claude-converse-tunnel@*.service; do
  [[ -e "$u" ]] || continue
  systemctl --user disable --now "$(basename "$u")" 2>/dev/null
  rm -f "$u"
done
systemctl --user disable --now claude-converse 2>/dev/null
rm -f "$UNIT_DIR/claude-converse.service"
systemctl --user daemon-reload

echo "Removing it from Claude Code..."
claude mcp remove --scope user converse >/dev/null 2>&1
rm -f "$HOME/.claude/commands/converse.md"

echo "Removing files..."
rm -rf "$HOME/.local/share/claude-converse" "$HOME/.config/claude-converse"

echo "Done. The tunnel key ~/.ssh/claude_converse_tunnel was kept."
echo "Remote machines keep their /converse command and MCP entry; see ./connect-remote.sh --remove."
