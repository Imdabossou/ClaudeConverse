# Contributing to ClaudeConverse

Thanks for helping! A few things to know first.

- **Bugs:** open an issue with the output of `journalctl --user -u claude-converse` and the self-test (see [BUILDING.md](BUILDING.md)). Say which hyprwhspr backend you use.
- **Branches:** open pull requests against `development`. `main` only gets tested changes.
- **Checks:** `py_compile`, the ruff check and `shellcheck -S error *.sh` must pass. CI runs all three.
- **Stay contained:** install only into the user's home, never into system Python or `/usr`, and don't change hyprwhspr's config. Anything `install.sh` adds, `uninstall.sh` must remove.
- **Stay local:** the server listens only on 127.0.0.1 with a token, and the remote tunnel key can't open a shell. Changes must not weaken either.
- **Voices:** new bundled voices need a licence that allows redistribution. Otherwise, document the download with `./install.sh --voice` instead.
- **Licence:** contributions are accepted under the project's licence (GPL-3.0-or-later). Third-party code must be GPL-compatible.
- **Security issues:** please report them privately, see [SECURITY.md](SECURITY.md).
