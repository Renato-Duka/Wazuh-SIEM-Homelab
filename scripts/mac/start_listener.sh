#!/usr/bin/env bash
# start_listener.sh
#
# Starts the Python webhook listener and an ngrok tunnel pointed at it,
# both in the background, then prints the public URL to paste into GitHub's
# webhook settings. Writes PIDs and logs so you can stop things cleanly.
#
# Requires: ngrok already installed + authorized (see install_ngrok.sh),
# python3 on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$HOME/wazuh-github-webhook"
PORT="${LISTENER_PORT:-8000}"

mkdir -p "$RUN_DIR"

echo "Starting listener on port $PORT..."
LISTENER_PORT="$PORT" nohup python3 "$SCRIPT_DIR/webhook_listener.py" \
    > "$RUN_DIR/listener.out" 2>&1 &
echo $! > "$RUN_DIR/listener.pid"

echo "Starting ngrok tunnel..."
nohup ngrok http "$PORT" --log=stdout > "$RUN_DIR/ngrok.out" 2>&1 &
echo $! > "$RUN_DIR/ngrok.pid"

# Give ngrok a moment to establish the tunnel, then ask its local API
# (127.0.0.1:4040) what public URL it assigned -- avoids the user having
# to scrape it from the terminal output by hand.
echo "Waiting for tunnel to come up..."
for _ in $(seq 1 10); do
    sleep 1
    URL="$(curl -s http://127.0.0.1:4040/api/tunnels \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["tunnels"][0]["public_url"]) if d.get("tunnels") else print("")' \
        2>/dev/null || true)"
    if [ -n "$URL" ]; then
        break
    fi
done

if [ -z "${URL:-}" ]; then
    echo "Could not read the tunnel URL automatically. Check $RUN_DIR/ngrok.out"
    exit 1
fi

echo
echo "Listener PID: $(cat "$RUN_DIR/listener.pid")   (log: $RUN_DIR/listener.out)"
echo "ngrok PID:    $(cat "$RUN_DIR/ngrok.pid")   (log: $RUN_DIR/ngrok.out)"
echo
echo "Public webhook URL: $URL"
echo
echo "Paste that URL into GitHub -> Org Settings -> Webhooks -> Add webhook"
echo "(or pass it to scripts/github/create_org_webhook.sh as WEBHOOK_URL)"
echo
echo "To stop everything:"
echo "  kill \$(cat $RUN_DIR/listener.pid) \$(cat $RUN_DIR/ngrok.pid)"
