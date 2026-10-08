"""Plummy's voice: a persistent local Kokoro TTS server.

The Mac app launches this once (model loads in a few seconds, then stays warm)
and POSTs each reply here; the WAV comes back and is streamed to the phone.

    GET  /health          -> 200 "ok" once the model is loaded
    POST /say {"text":..} -> audio/wav (24 kHz mono PCM16)

Local only: binds 127.0.0.1. Voice is Kokoro af_heart (Tony's pick, 10-08).
"""
import io
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
import soundfile as sf
from kokoro import KPipeline

VOICE = "af_heart"
PORT = 4777

pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
# Warm the graph so the first real reply doesn't pay compile cost.
_ = [a for (_, _, a) in pipeline("Ready.", voice=VOICE)]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the app's stdout quiet
        pass

    def do_GET(self):
        if self.path == "/health":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/say":
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            body = {}
        text = (body.get("text") or "").strip()
        if not text:
            self.send_response(400)
            self.end_headers()
            return
        chunks = [a for (_, _, a) in pipeline(text, voice=body.get("voice") or VOICE)]
        audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype="float32")
        buf = io.BytesIO()
        sf.write(buf, audio, 24000, format="WAV", subtype="PCM_16")
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
