#!/usr/bin/env python3
"""Small local Canon CCAPI fixture used to test SnapBooth without firing a camera."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import sys
import threading


PORT = 18080
IMAGE = Path(__file__).parents[1] / "SnapBooth" / "Assets" / "wedding-welcome-cover.png"
capture_count = 0
capture_delay = float(os.environ.get("CANON_CAPTURE_DELAY", "0"))


def finish_capture():
    global capture_count
    capture_count += 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stdout.write("CCAPI " + (fmt % args) + "\n")
        sys.stdout.flush()

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_image(self):
        body = IMAGE.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/ccapi", "/ccapi/"):
            return self.send_json({"api": ["ver100"]})
        if path == "/ccapi/ver100/deviceinformation":
            return self.send_json({"productname": "Canon EOS R50 V · SIMULATOR", "version": "1.0"})
        if path.startswith("/ccapi/ver100/shooting/liveview"):
            return self.send_image()
        if path == "/ccapi/ver100/contents":
            return self.send_json({"path": ["/ccapi/ver100/contents/sd"]})
        if path == "/ccapi/ver100/contents/sd":
            return self.send_json({"path": ["/ccapi/ver100/contents/sd/100CANON"]})
        if path == "/ccapi/ver100/contents/sd/100CANON":
            photos = [
                f"/ccapi/ver100/contents/sd/100CANON/IMG_{number:04d}.jpg"
                for number in range(capture_count + 1, 0, -1)
            ]
            return self.send_json({"path": photos, "pagenumber": 0})
        if path.endswith(".jpg") and "/contents/sd/100CANON/IMG_" in path:
            return self.send_image()
        self.send_json({"message": "not found", "path": self.path}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        if self.path == "/ccapi/ver100/shooting/liveview":
            return self.send_json({"status": "ok"})
        if self.path == "/ccapi/ver100/shooting/control/shutterbutton":
            if capture_delay > 0:
                threading.Timer(capture_delay, finish_capture).start()
                return self.send_json({"message": "During shooting or recording"}, 503)
            finish_capture()
            return self.send_json({"status": "ok"})
        self.send_json({"message": "not found"}, 404)

    def do_DELETE(self):
        if self.path == "/ccapi/ver100/shooting/liveview":
            return self.send_json({"status": "ok"})
        self.send_json({"message": "not found"}, 404)


if __name__ == "__main__":
    print(f"Canon CCAPI simulator: http://127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
