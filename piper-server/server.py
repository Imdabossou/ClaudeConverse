#!/usr/bin/env python3
"""Minimal OpenAI-compatible TTS server (/v1/audio/speech) backed by Piper.

Lets VoiceMode (or anything that speaks the OpenAI speech API) use Piper
voices. Voices are the *.onnx files (+ .onnx.json) in PIPER_VOICE_DIR,
named by the middle part of the file name: en_US-glados-medium.onnx -> "glados".

Piper voices are 16-22 kHz; output is resampled (soxr) to 24 kHz because
VoiceMode plays raw PCM at 24 kHz, and un-resampled audio sounds fast and crispy.
"""
import io, json, os, subprocess, wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from piper import PiperVoice

VOICE_DIR = Path(os.environ.get("PIPER_VOICE_DIR", Path.home() / ".local/share/piper-voices"))
PORT = int(os.environ.get("PIPER_PORT", "8881"))
DEFAULT_VOICE = os.environ.get("PIPER_DEFAULT_VOICE", "glados")
OUT_RATE = 24000  # VoiceMode assumes 24 kHz like OpenAI/Kokoro
_cache = {}


def resample(pcm, src, dst):
    """High-quality (soxr) resample of 16-bit mono PCM via ffmpeg."""
    if src == dst:
        return pcm
    return subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "s16le", "-ar", str(src), "-ac", "1", "-i", "pipe:0",
         "-af", "aresample=resampler=soxr:precision=28", "-ar", str(dst), "-f", "s16le", "pipe:1"],
        input=pcm, capture_output=True).stdout


def voices():
    return {p.stem.split("-")[1] if p.stem.count("-") >= 2 else p.stem: p
            for p in VOICE_DIR.glob("*.onnx")}


def load(name):
    available = voices()
    if not available:
        raise SystemExit(f"No Piper voices (*.onnx) found in {VOICE_DIR}")
    path = available.get(name) or available.get(DEFAULT_VOICE) or next(iter(available.values()))
    if path not in _cache:
        _cache[path] = PiperVoice.load(str(path))
    return _cache[path]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/v1/audio/voices", "/health"):
            v = sorted(voices())
            self._send(200, json.dumps({"object": "list", "voices": v,
                "data": [{"id": "tts-1", "object": "model"}, {"id": "piper", "object": "model"}]}).encode())
        else:
            self._send(404, b"{}")

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/audio/speech":
            return self._send(404, b"{}")
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        voice = load(req.get("voice", DEFAULT_VOICE))
        pcm = b"".join(c.audio_int16_bytes for c in voice.synthesize(req.get("input", "")))
        pcm = resample(pcm, voice.config.sample_rate, OUT_RATE)
        fmt = req.get("response_format", "mp3")
        if fmt == "pcm":
            return self._send(200, pcm, "audio/pcm")
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(OUT_RATE)
            w.writeframes(pcm)
        if fmt == "wav":
            return self._send(200, buf.getvalue(), "audio/wav")
        # mp3 / opus / aac / flac: encode with ffmpeg
        codec = {"opus": ["-c:a", "libopus", "-f", "ogg"], "aac": ["-f", "adts"]}.get(fmt, ["-b:a", "96k", "-f", fmt])
        out = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", *codec, "pipe:1"],
                             input=buf.getvalue(), capture_output=True).stdout
        self._send(200, out, f"audio/{fmt}")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    load(DEFAULT_VOICE)  # warm up
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
