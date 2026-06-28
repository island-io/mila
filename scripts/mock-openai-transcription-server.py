#!/usr/bin/env python3
"""Minimal OpenAI-compatible transcription server for end-to-end testing.

Stands in for OpenAI's API (or a self-hosted faster-whisper server like
`speaches`) so CI can exercise Mila's `RemoteWhisperEngine` over a real HTTP
socket — without downloading a multi-GB model or running Docker (which the
macOS GitHub runners can't do).

It does NOT transcribe. Instead it *validates the request contract* and
**echoes** what it received back through the response, so the client test can
prove it built the request correctly:

  GET  /v1/models                 -> 200 {"data":[...]}    (the connectivity probe)
  POST /v1/audio/transcriptions   -> verbose_json whose segments encode the
                                     received `model` and `language` fields.

The POST is rejected (4xx) unless the request satisfies the contract a real
server would require:
  * Authorization: Bearer <token>      (we require a token here)
  * a non-empty `model` form field
  * a `file` part that is a real MP4/M4A payload (contains the `ftyp` box)

A 2xx + echoed values therefore proves the client sent a well-formed multipart
upload with the right headers, and that it parsed `verbose_json` (segments +
timestamps) back correctly.

Stdlib only — no pip install, so it starts instantly and can't break on a
dependency resolution.
"""

import argparse
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _parse_multipart(body: bytes, boundary: bytes):
    """Return (fields: dict[str,str], file_bytes: bytes|None).

    Deliberately small/forgiving — just enough to pull form field values and
    the file part out of a well-formed multipart/form-data body.
    """
    fields = {}
    file_bytes = None
    delimiter = b"--" + boundary
    for part in body.split(delimiter):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        header_blob, _, content = part.partition(b"\r\n\r\n")
        if not _:
            continue
        headers = header_blob.decode("utf-8", "replace")
        disp = next((l for l in headers.splitlines()
                     if l.lower().startswith("content-disposition")), "")
        name_match = re.search(r'name="([^"]*)"', disp)
        if not name_match:
            continue
        name = name_match.group(1)
        if "filename=" in disp:
            file_bytes = content
        else:
            fields[name] = content.decode("utf-8", "replace").strip()
    return fields, file_bytes


class Handler(BaseHTTPRequestHandler):
    # Quieter logs; CI captures stderr anyway.
    def log_message(self, *args):
        sys.stderr.write("[mock-server] " + (args[0] % args[1:]) + "\n")

    def _send_json(self, status: int, payload: dict):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send_json(200, {
                "object": "list",
                "data": [{"id": "mock-whisper", "object": "model"}],
            })
        else:
            self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.path.endswith("/audio/transcriptions"):
            self._send_json(404, {"error": {"message": "not found"}})
            return

        # Contract: a real OpenAI endpoint requires a bearer token.
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._send_json(401, {"error": {"message": "missing bearer token"}})
            return

        ctype = self.headers.get("Content-Type", "")
        m = re.search(r"boundary=([^;]+)", ctype)
        if "multipart/form-data" not in ctype or not m:
            self._send_json(400, {"error": {"message": "expected multipart/form-data"}})
            return
        boundary = m.group(1).strip().strip('"').encode("utf-8")

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        fields, file_bytes = _parse_multipart(body, boundary)

        model = fields.get("model", "")
        if not model:
            self._send_json(400, {"error": {"message": "missing model field"}})
            return
        if not file_bytes or b"ftyp" not in file_bytes[:64]:
            self._send_json(400, {"error": {"message": "missing or non-m4a file part"}})
            return

        language = fields.get("language", "none")

        # Echo the received model + language back through the transcript so the
        # client test can assert it transmitted them (and parsed the segments).
        self._send_json(200, {
            "task": "transcribe",
            "language": language,
            "duration": 1.0,
            "text": f"model={model} lang={language}",
            "segments": [
                {"id": 0, "seek": 0, "start": 0.0, "end": 0.5, "text": f"model={model}"},
                {"id": 1, "seek": 0, "start": 0.5, "end": 1.0, "text": f"lang={language}"},
            ],
        })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8123)
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    # Flushed line CI can wait on before pointing the client at us.
    print(f"mock-openai-transcription-server listening on "
          f"http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
