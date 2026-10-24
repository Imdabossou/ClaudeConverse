---
description: Start a voice conversation (audio plays on the desktop via VoiceMode)
---
Start an ongoing voice conversation with the user by calling the `converse` tool from the `voicemode` MCP server. The microphone and speakers are on the user's desktop; if this is a remote machine, it only runs Claude.

- If `$ARGUMENTS` is non-empty, speak it as the opening message; otherwise choose a short, natural opener.
- Keep calling `converse` (with `hold_conch: true`) to continue the conversation, until the user says to stop or end voice mode; then send a short goodbye with `wait_for_response: false`.
- Keep spoken messages short and conversational: no markdown, code or file paths read aloud. Put details in your text reply instead.
- If the tool is unavailable or errors with a connection failure, tell the user the desktop's VoiceMode server or tunnel is probably down (on the desktop: `systemctl --user status voicemode-serve voicemode-tunnel`).
