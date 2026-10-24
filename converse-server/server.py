#!/usr/bin/env python3
"""converse-server: hands-free voice conversations for Claude Code.

One MCP tool, `converse`: speak a message with Piper, then listen on the
microphone until the user stops talking, transcribe it with hyprwhspr (the
dictation daemon's already-loaded Whisper), and return the text.

Serves MCP over streamable HTTP on 127.0.0.1 with a bearer token, so Claude Code
on this machine, and on remote machines through an SSH tunnel, connect the same
way. Configuration comes from environment variables (see the CONFIG block).
"""
import asyncio, hmac, json, os, queue, socket, tempfile, threading, time, wave
from pathlib import Path

import numpy as np
import sounddevice as sd
import uvicorn
import webrtcvad
from mcp.server.mcpserver import Context, MCPServer
from piper import PiperVoice, SynthesisConfig

# ---------------------------------------------------------------- CONFIG
env = os.environ.get
HOST = env("CONVERSE_HOST", "127.0.0.1")
PORT = int(env("CONVERSE_PORT", "8765"))
TOKEN = env("CONVERSE_TOKEN") or (
    Path(env("CONVERSE_TOKEN_FILE")).read_text().strip() if env("CONVERSE_TOKEN_FILE") else None)
VOICE_DIR = Path(env("CONVERSE_VOICE_DIR", Path.home() / ".local/share/piper-voices"))
DEFAULT_VOICE = env("CONVERSE_VOICE", "glados")
SILENCE_S = float(env("CONVERSE_SILENCE", "1.2"))   # pause that ends your turn
VAD_LEVEL = int(env("CONVERSE_VAD", "2"))           # 0 (lenient) .. 3 (strict)
CHIMES = env("CONVERSE_CHIMES", "1") != "0"
HOLD_S = float(env("CONVERSE_HOLD", "30"))          # how long a session keeps the floor
RUNTIME_DIR = Path(env("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
HYPRWHSPR_SOCKET = Path(env("HYPRWHSPR_SOCKET", RUNTIME_DIR / "hyprwhspr/hyprwhspr.sock"))

REC_RATE = 16000          # what Whisper wants
FRAME = 480               # 30 ms at 16 kHz, a webrtcvad frame size
PREROLL_FRAMES = 10       # keep 300 ms before speech starts
START_FRAMES = 3          # 90 ms of speech counts as "started talking"


# ---------------------------------------------------------------- speech out
_voices: dict[Path, PiperVoice] = {}


def voice_files():
    """{name: path}; en_US-glados-medium.onnx -> "glados"."""
    return {p.stem.split("-")[1] if p.stem.count("-") >= 2 else p.stem: p
            for p in VOICE_DIR.glob("*.onnx")}


def load_voice(name=None):
    files = voice_files()
    if not files:
        raise RuntimeError(f"no Piper voices (*.onnx) in {VOICE_DIR}")
    path = files.get(name or DEFAULT_VOICE) or files.get(DEFAULT_VOICE) or next(iter(files.values()))
    if path not in _voices:
        _voices[path] = PiperVoice.load(str(path))
    return _voices[path]


def speak(text, voice_name=None, speed=1.0):
    """Synthesise sentence by sentence in a thread while earlier ones play."""
    voice = load_voice(voice_name)
    cfg = SynthesisConfig(length_scale=1.0 / max(speed, 0.25))
    chunks: queue.Queue = queue.Queue(maxsize=8)

    def produce():
        try:
            for chunk in voice.synthesize(text, syn_config=cfg):
                chunks.put(chunk.audio_int16_array)
        finally:
            chunks.put(None)

    threading.Thread(target=produce, daemon=True).start()
    with sd.OutputStream(samplerate=voice.config.sample_rate, channels=1, dtype="int16") as out:
        while (audio := chunks.get()) is not None:
            out.write(audio.reshape(-1, 1))


def chime(rising=True):
    """Two short tones: rising = "your turn", falling = "got it"."""
    if not CHIMES:
        return
    rate = 24000
    tones = (660, 990) if rising else (990, 660)
    t = np.arange(int(rate * 0.07)) / rate
    fade = np.minimum(1, np.minimum(t, t[::-1]) / 0.01)
    beep = np.concatenate([np.sin(2 * np.pi * f * t) * fade for f in tones])
    lead = np.zeros(int(rate * 0.1))  # wakes Bluetooth/HDMI sinks before the tone
    sd.play((np.concatenate([lead, beep]) * 0.25).astype(np.float32), rate, blocking=True)


# ---------------------------------------------------------------- speech in
def listen(max_s=120.0, min_s=1.0):
    """Record until the user has spoken and then paused for SILENCE_S.

    Returns 16 kHz mono int16 PCM, or None if nobody spoke within max_s.
    """
    vad = webrtcvad.Vad(VAD_LEVEL)
    frames: queue.Queue = queue.Queue()
    stream = sd.InputStream(samplerate=REC_RATE, channels=1, dtype="int16", blocksize=FRAME,
                            callback=lambda data, *_: frames.put(bytes(data)))
    preroll, speech, voiced_run, silent_s = [], [], 0, 0.0
    started, talk_start = False, 0.0
    begin = time.monotonic()
    with stream:
        while time.monotonic() - begin < max_s:
            try:
                frame = frames.get(timeout=1)
            except queue.Empty:
                continue
            voiced = vad.is_speech(frame, REC_RATE)
            if not started:
                preroll = (preroll + [frame])[-PREROLL_FRAMES:]
                voiced_run = voiced_run + 1 if voiced else 0
                if voiced_run >= START_FRAMES:
                    started, speech, talk_start = True, list(preroll), time.monotonic()
                continue
            speech.append(frame)
            silent_s = 0.0 if voiced else silent_s + FRAME / REC_RATE
            if silent_s >= SILENCE_S and time.monotonic() - talk_start >= min_s:
                break
    return b"".join(speech) if started else None


BUSY = ("while recording", "already processing", "already running", "finalizing",
        "retry shortly", "long-form session")


def transcribe(pcm, wait=8.0):
    """Ask hyprwhspr to transcribe; waits up to `wait` s while it's busy dictating."""
    with tempfile.NamedTemporaryFile(suffix=".wav", dir=RUNTIME_DIR) as f:
        with wave.open(f, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(REC_RATE)
            w.writeframes(pcm)
        f.flush()
        deadline = time.monotonic() + wait
        while True:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(120)
                    s.connect(str(HYPRWHSPR_SOCKET))
                    s.sendall(json.dumps({"verb": "transcribe_file", "path": f.name}).encode() + b"\n")
                    reply = json.loads(s.makefile("rb").readline() or b"{}")
            except OSError as e:
                raise RuntimeError(f"hyprwhspr not reachable at {HYPRWHSPR_SOCKET} ({e}); "
                                   "is it running? systemctl --user start hyprwhspr")
            if reply.get("ok"):
                return reply["text"].strip()
            error = reply.get("error", "no reply from hyprwhspr")
            if error.startswith("Transcription produced no text"):
                return ""
            if not any(b in error for b in BUSY) or time.monotonic() > deadline:
                raise RuntimeError(f"hyprwhspr: {error}")
            time.sleep(0.5)


# ---------------------------------------------------------------- the floor
# One speaker at a time across sessions (e.g. desktop and a remote machine).
# A session holding the floor (hold_conch) keeps it for HOLD_S between turns.
_audio = asyncio.Lock()
_floor = {"owner": None, "until": 0.0}


async def take_floor(owner, wait_s=60.0):
    deadline = time.monotonic() + wait_s
    while True:
        now = time.monotonic()
        if _floor["owner"] in (None, owner) or _floor["until"] < now:
            _floor.update(owner=owner, until=now + HOLD_S)
            return True
        if now > deadline:
            return False
        await asyncio.sleep(0.2)


# ---------------------------------------------------------------- MCP
mcp = MCPServer(
    "converse",
    instructions="Voice conversation with the user through their desktop's microphone and speakers. "
                 "Call `converse` repeatedly to keep talking; keep spoken messages short and plain "
                 "(no markdown, code or file paths).",
)


@mcp.tool()
async def converse(
    message: str,
    wait_for_response: bool = True,
    hold_conch: bool = False,
    voice: str | None = None,
    speed: float = 1.0,
    listen_duration_max: float = 120.0,
    listen_duration_min: float = 1.0,
    ctx: Context | None = None,
) -> str:
    """Speak `message` aloud, then (if wait_for_response) listen and return what the user says.

    - hold_conch: keep the floor for the next turn so other Claude sessions wait.
    - voice: Piper voice name (default from the server's config, e.g. "glados").
    - speed: speech rate, 1.0 = normal.
    - listen_duration_max: give up after this many seconds without a reply.
    Your turn ends when the user pauses; their words come back as text.
    """
    headers = (ctx.headers if ctx else None) or {}
    owner = headers.get("mcp-session-id", "anonymous")
    if not await take_floor(owner):
        return "Another Claude session is talking to the user right now; try again shortly."
    try:
        async with _audio:
            started = time.monotonic()
            await asyncio.to_thread(speak, message, voice, speed)
            if not wait_for_response:
                return "Spoken."
            await asyncio.to_thread(chime, True)
            pcm = await asyncio.to_thread(listen, listen_duration_max, listen_duration_min)
            await asyncio.to_thread(chime, False)
            if pcm is None:
                return f"(no speech heard for {listen_duration_max:.0f} s)"
            heard = time.monotonic()
            text = await asyncio.to_thread(transcribe, pcm)
            took = time.monotonic() - heard
            return f"User said: {text or '(nothing intelligible)'}  [transcribed in {took:.1f} s, " \
                   f"turn {heard - started:.0f} s]"
    finally:
        if hold_conch and wait_for_response:
            _floor["until"] = time.monotonic() + HOLD_S
        else:
            _floor.update(owner=None, until=0.0)


class TokenGuard:
    """Require `Authorization: Bearer <token>` on everything except /health."""

    def __init__(self, app, token):
        self.app, self.expected = app, f"Bearer {token}".encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            if scope["path"] == "/health":
                body = json.dumps({"ok": True, "voices": sorted(voice_files())}).encode()
                await send({"type": "http.response.start", "status": 200,
                            "headers": [(b"content-type", b"application/json")]})
                return await send({"type": "http.response.body", "body": body})
            auth = dict(scope["headers"]).get(b"authorization", b"")
            if not hmac.compare_digest(auth, self.expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                return await send({"type": "http.response.body", "body": b"unauthorized\n"})
        await self.app(scope, receive, send)


def selftest():
    """Synthesise a phrase, transcribe it with hyprwhspr, and print the result."""
    voice = load_voice()
    audio = np.concatenate([c.audio_int16_array for c in voice.synthesize("Testing the voice setup.")])
    # Piper's rate -> 16 kHz for Whisper (linear interpolation is fine for a test)
    n = int(len(audio) * REC_RATE / voice.config.sample_rate)
    pcm = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.int16)
    print(json.dumps({"voices": sorted(voice_files()), "heard": transcribe(pcm.tobytes())}))


def main():
    import sys
    if "--selftest" in sys.argv:
        return selftest()
    if not TOKEN:
        raise SystemExit("set CONVERSE_TOKEN or CONVERSE_TOKEN_FILE")
    load_voice()  # load the default voice now, not on the first call
    app = TokenGuard(mcp.streamable_http_app(host=HOST), TOKEN)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
