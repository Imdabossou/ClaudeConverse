---
description: Start a hands-free voice conversation (speaks and listens through the desktop)
---
Start an ongoing voice conversation with the user by calling the `converse` tool from the `converse` MCP server. The microphone and speakers are on the user's desktop; if this is a remote machine, it only runs Claude.

- If `$ARGUMENTS` is non-empty, speak it as the opening message; otherwise choose a short, natural opener.
- Each `converse` call speaks your message, then listens and returns what the user said. Keep calling it with `hold_conch: true` to continue, until the user says to stop or end voice mode; then send a short goodbye with `wait_for_response: false`.
- Before each call, show what you'll say as `> **Claude:** …`, and after it, what the user said as `> **You:** …`, so the conversation stays readable on screen.
- Keep spoken messages short and conversational: no markdown, code or file paths read aloud. Put details in your text reply instead.
- If the user's words look like they're talking to someone else in the room, ask whether that was meant for you, and stop listening if they're busy.
- If the tool is unavailable or errors with a connection failure, tell the user the desktop's converse server or tunnel is probably down (on the desktop: `systemctl --user status claude-converse`).
