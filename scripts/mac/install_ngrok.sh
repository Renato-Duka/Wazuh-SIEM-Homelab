#!/usr/bin/env bash
# install_ngrok.sh
#
# Installs the ngrok agent on macOS without requiring Homebrew. Safe to
# re-run (idempotent) -- it skips the download if ngrok is already on PATH.
#
# After this runs, you still need to authorize your account once:
#   1. Sign up free at https://ngrok.com
#   2. Copy your authtoken from the dashboard
#   3. Run: ngrok config add-authtoken <your-token>
# (Deliberately not scripted -- never put your authtoken in a committed file.)

set -euo pipefail

if command -v ngrok >/dev/null 2>&1; then
    echo "ngrok is already installed: $(ngrok version)"
    exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64) NGROK_ARCH="arm64" ;;
    x86_64) NGROK_ARCH="amd64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-${NGROK_ARCH}.zip"
echo "Downloading ngrok for darwin-${NGROK_ARCH}..."
curl -sSL "$ZIP_URL" -o "$TMP_DIR/ngrok.zip"

unzip -q "$TMP_DIR/ngrok.zip" -d "$TMP_DIR"
sudo mv "$TMP_DIR/ngrok" /usr/local/bin/ngrok
sudo chmod +x /usr/local/bin/ngrok

echo "Installed: $(ngrok version)"
echo
echo "Next step (one-time, manual): run 'ngrok config add-authtoken <your-token>'"
echo "Get your token from https://dashboard.ngrok.com/get-started/your-authtoken"
