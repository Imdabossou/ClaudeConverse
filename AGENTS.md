# AGENTS.md

Voice conversations for Claude Code on Arch Linux. One Python MCP server (`converse-server/server.py`, streamable HTTP on 127.0.0.1:8765), shell installers, a systemd user service. Speech-to-text goes through hyprwhspr's control socket; speech is Piper.

## Commands

- Checks: `python3 -m py_compile converse-server/server.py`, `pipx run ruff check --select E9,F converse-server`, `shellcheck -S error *.sh`
- Reinstall after changes: `./install.sh && systemctl --user restart claude-converse`
- Self-test: `~/.local/share/claude-converse/venv/bin/python ~/.local/share/claude-converse/server.py --selftest`
- Logs: `journalctl --user -u claude-converse -f`
- More in [BUILDING.md](BUILDING.md); user settings in [docs/guide.md](docs/guide.md)

## Conventions

- Branches: work on `development`; `main` only gets tested changes.
- Everything installs into the user's home: venv in `~/.local/share/claude-converse`, config in `~/.config/claude-converse`. Never pip-install into system Python or `/usr`, and never change hyprwhspr's config.
- `uninstall.sh` must remove everything `install.sh` adds, apart from pacman packages.
- The server only listens on 127.0.0.1 and every request needs the token. Keep it that way.
- The remote tunnel key must stay restricted to the one port forward (`restrict,port-forwarding,permitlisten=...,command="/usr/bin/false"`). It must never get a shell.
- Use placeholder hosts like `user@192.168.1.50` in examples, never real ones.
- Keep README.md short. User how-to goes in `docs/guide.md`, developer detail in BUILDING.md.

## Traps

- On Arch, the `piper` command is a gaming-mouse tool. This project uses the Piper Python library in its own venv; don't call a system `piper`.
- hyprwhspr does one thing at a time. While the user is dictating, `transcribe_file` fails and the server retries after a few seconds.
- hyprwhspr's `realtime-ws` backend doesn't support `transcribe_file`.
- An Arch Python upgrade breaks the venv. Rerunning `install.sh` rebuilds it.
- Testing real conversations needs a desktop with a mic, speakers and a running hyprwhspr.
