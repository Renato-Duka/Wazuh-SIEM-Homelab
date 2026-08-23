#!/usr/bin/env bash
# add_custom_rule.sh
#
# Adds a custom Wazuh rule that recognizes events coming from the GitHub
# webhook log file and raises them to alert level 5 (Wazuh's default alert
# threshold is 3), so they land in alerts.log and show up in the dashboard
# instead of only sitting in the archive.
#
# Idempotent: skips insertion if rule id 100100 is already present.
# Backs up local_rules.xml before editing.
#
# Run on the Wazuh manager, with sudo: sudo ./add_custom_rule.sh

set -euo pipefail

RULES_FILE="/var/ossec/etc/rules/local_rules.xml"
RULE_ID="100100"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs to run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

if grep -q "id=\"$RULE_ID\"" "$RULES_FILE" 2>/dev/null; then
    echo "Rule $RULE_ID already present in $RULES_FILE, nothing to do."
else
    cp "$RULES_FILE" "$RULES_FILE.bak.$(date +%Y%m%d%H%M%S)"
    echo "Backed up $RULES_FILE"

    RULE="  <rule id=\"$RULE_ID\" level=\"5\">
    <location>github_events.log</location>
    <description>GitHub webhook event received</description>
    <group>github,</group>
  </rule>
"
    # Insert just before the last closing </group> tag in the file.
    python3 - "$RULES_FILE" "$RULE" <<'PYEOF'
import sys
path, rule = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
marker = "</group>"
idx = content.rfind(marker)
if idx == -1:
    raise SystemExit(f"Could not find a closing {marker} in {path}")
new_content = content[:idx] + rule + content[idx:]
with open(path, "w") as f:
    f.write(new_content)
PYEOF

    echo "Inserted rule $RULE_ID"
fi

echo "Restarting manager..."
/var/ossec/bin/wazuh-control restart
