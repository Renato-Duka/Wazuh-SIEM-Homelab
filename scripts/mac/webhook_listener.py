#!/usr/bin/env python3
"""
webhook_listener.py

Tiny local HTTP server that receives GitHub webhook deliveries and appends
each one as a single line of JSON to a log file. Wazuh's agent later tails
that file (see scripts/mac/configure_agent.sh) and ships it to the manager.

Why it exists: GitHub's organization audit-log REST API
(GET /orgs/{org}/audit-log) is gated behind GitHub Enterprise Cloud. Webhooks
are available on every plan, so instead of polling that API, GitHub pushes
events to us directly.

Usage:
    python3 webhook_listener.py
    (leave it running; pair it with an ngrok tunnel pointed at the same port)

Env vars (all optional):
    LISTENER_PORT   - port to listen on (default 8000)
    LISTENER_LOGFILE - where to write events (default ~/wazuh-github-webhook/github_events.log)
"""
import http.server
import json
import os
import datetime
from pathlib import Path

PORT = int(os.environ.get("LISTENER_PORT", "8000"))
LOG_FILE = Path(
    os.environ.get(
        "LISTENER_LOGFILE",
        str(Path.home() / "wazuh-github-webhook" / "github_events.log"),
    )
)
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        event_type = self.headers.get("X-GitHub-Event", "unknown")

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {"raw": body}

        record = {
            "received_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "github_event_type": event_type,
            "payload": payload,
        }

        # One JSON object per line -- this is what lets Wazuh's
        # <log_format>json</log_format> localfile reader parse each
        # event as structured, field-searchable data.
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(record) + "\n")

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, format, *args):
        print(f"Received a '{self.headers.get('X-GitHub-Event', 'unknown')}' event from GitHub")


if __name__ == "__main__":
    with http.server.HTTPServer(("127.0.0.1", PORT), WebhookHandler) as httpd:
        print(f"Listening on port {PORT}, logging events to {LOG_FILE}")
        httpd.serve_forever()
