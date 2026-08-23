#!/usr/bin/env bash
# configure_agent.sh
#
# Adds a <localfile> block to the macOS Wazuh agent's ossec.conf so it
# tails the webhook listener's log file and ships events to the manager.
# Idempotent: checks for the marker before inserting, so re-running this
# won't create duplicate blocks. Backs up the config before editing.
#
# Run with sudo: sudo ./configure_agent.sh

set -euo pipefail

CONF="/Library/Ossec/etc/ossec.conf"
LOG_PATH="${WEBHOOK_LOG_PATH:-$HOME/wazuh-github-webhook/github_events.log}"
MARKER="wazuh-github-webhook"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs to run as root (it edits a file under /Library/Ossec)." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

if grep -q "$MARKER" "$CONF" 2>/dev/null; then
    echo "localfile block already present in $CONF, nothing to do."
else
    cp "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
    echo "Backed up $CONF"

    BLOCK="  <!-- $MARKER -->
  <localfile>
    <log_format>json</log_format>
    <location>$LOG_PATH</location>
  </localfile>
"
    # Insert right before the final closing </ossec_config> tag. Sibling
    # top-level blocks (wodle/localfile/etc.) can go in any order, so this
    # is always a safe insertion point regardless of what else is in the file.
    python3 - "$CONF" "$BLOCK" <<'PYEOF'
import sys
conf_path, block = sys.argv[1], sys.argv[2]
with open(conf_path) as f:
    content = f.read()
marker = "</ossec_config>"
idx = content.rfind(marker)
if idx == -1:
    raise SystemExit(f"Could not find {marker} in {conf_path}")
new_content = content[:idx] + block + content[idx:]
with open(conf_path, "w") as f:
    f.write(new_content)
PYEOF

    echo "Inserted localfile block pointing at $LOG_PATH"
fi

echo "Restarting agent..."
/Library/Ossec/bin/wazuh-control restart
