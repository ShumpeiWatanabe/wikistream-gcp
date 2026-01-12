import os
import json
import time
import threading
import datetime as dt
from typing import List
import sys

import requests
from flask import Flask, Response

# ----------------------------
# Config (env)
# ----------------------------
STREAM_URL = os.getenv("STREAM_URL", "https://stream.wikimedia.org/v2/stream/recentchange")
USER_AGENT = os.getenv(
    "USER_AGENT",
    "wikistream-cloudrun/0.1 (+https://example.invalid; contact=you@example.invalid)"
)

# ----------------------------
# App
# ----------------------------
app = Flask(__name__)

def sse_consume_forever() -> None:
    """
    Consume Wikimedia EventStreams (SSE).
    Reconnect on errors with backoff.
    """
    backoff = 1.0
    headers = {
        "Accept": "text/event-stream",
        "User-Agent": USER_AGENT,
    }

    while True:
        try:
            print(f"[sse] connecting: {STREAM_URL}")
            with requests.get(STREAM_URL, headers=headers, stream=True, timeout=(10, 60)) as r:
                r.raise_for_status()
                backoff = 1.0

                for raw in r.iter_lines(decode_unicode=True):
                    if raw is None:
                        continue
                    line = raw.strip()

                    # We only care "data: {...}"
                    if not line.startswith("data:"):
                        continue

                    data = line[len("data:"):].strip()
                    if not data:
                        continue

                    try:
                        event = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    event_dt = event.get("meta", {}).get("dt")
                    id = event.get("meta", {}).get("id")
                    wrapped = {
                        "kind": "wiki_edit",
                        "dt": event_dt,
                        "id": id,
                        "raw_json": data,
                    }
                    print(json.dumps(wrapped, ensure_ascii=False))

        except Exception as e:
            print(f"[sse] error: {e}. reconnecting in {backoff:.1f}s", file=sys.stderr)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60.0)

@app.get("/")
def root():
    # Simple health endpoint
    return Response("ok\n", mimetype="text/plain")

def start_background_thread_once():
    t = threading.Thread(target=sse_consume_forever, daemon=True)
    t.start()
    print("[app] background SSE consumer started")

# Cloud Run will start the container once; start background worker on import time.
start_background_thread_once()

if __name__ == "__main__":
    # Cloud Run uses PORT env
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
