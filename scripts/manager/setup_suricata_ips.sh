#!/usr/bin/env bash
# setup_suricata_ips.sh
#
# Installs Suricata on the Wazuh manager VM (Ubuntu) and runs it as an inline
# IPS via netfilter NFQUEUE, then forwards its EVE JSON alerts into Wazuh.
#
#   1. Installs suricata + suricata-update and pulls the ET Open ruleset
#   2. Converts high-confidence malware/exploit groups to drop rules (drop.conf)
#   3. Installs a systemd drop-in so Suricata reads from NFQUEUE 0
#   4. Sends INPUT/OUTPUT traffic to NFQUEUE with --queue-bypass (fail-open:
#      if Suricata isn't running, traffic still flows instead of being cut off)
#   5. Persists the iptables rules across reboots
#   6. Adds the eve.json <localfile> block to the manager's ossec.conf
#
# Idempotent where practical: skips the iptables rules and the localfile block
# if they're already present. Backs up ossec.conf before editing.
#
# Take a VM snapshot first: a bad NFQUEUE setup can cut the VM's network.
# Run on the Wazuh manager, from the repo root, with sudo:
#   sudo ./scripts/manager/setup_suricata_ips.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OSSEC_CONF="/var/ossec/etc/ossec.conf"
DROPIN_DIR="/etc/systemd/system/suricata.service.d"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs to run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

echo "Installing Suricata..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q suricata suricata-update iptables-persistent

echo "Installing drop.conf and local test rules..."
cp "$REPO_DIR/config/suricata/drop.conf" /etc/suricata/drop.conf
mkdir -p /etc/suricata/rules
# Install the rules file empty: the test signatures in the repo copy are for
# manual validation only (see README), and the drop rule would block 8.8.8.8.
: > /etc/suricata/rules/local.rules

if ! grep -q "/etc/suricata/rules/local.rules" /etc/suricata/suricata.yaml; then
    sed -i 's|^  - suricata.rules$|  - suricata.rules\n  - /etc/suricata/rules/local.rules|' /etc/suricata/suricata.yaml
    echo "Added local.rules to suricata.yaml"
fi

echo "Updating rules (ET Open + drop conversions)..."
suricata-update

echo "Validating config..."
suricata -T -c /etc/suricata/suricata.yaml

echo "Installing NFQUEUE systemd drop-in..."
mkdir -p "$DROPIN_DIR"
cp "$REPO_DIR/config/suricata/override.conf" "$DROPIN_DIR/override.conf"
systemctl daemon-reload
systemctl enable suricata
systemctl restart suricata

echo "Routing traffic through NFQUEUE..."
for CHAIN in INPUT OUTPUT; do
    if iptables -C "$CHAIN" -j NFQUEUE --queue-bypass 2>/dev/null; then
        echo "  $CHAIN rule already present"
    else
        iptables -I "$CHAIN" -j NFQUEUE --queue-bypass
        echo "  $CHAIN rule added"
    fi
done
netfilter-persistent save

if grep -q "/var/log/suricata/eve.json" "$OSSEC_CONF"; then
    echo "eve.json localfile already in $OSSEC_CONF, nothing to do."
else
    cp "$OSSEC_CONF" "$OSSEC_CONF.bak.$(date +%Y%m%d%H%M%S)"
    echo "Backed up $OSSEC_CONF"
    python3 - "$OSSEC_CONF" <<'PYEOF'
import sys
path = sys.argv[1]
block = """  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>

"""
with open(path) as f:
    content = f.read()
marker = "</ossec_config>"
idx = content.rfind(marker)
if idx == -1:
    raise SystemExit(f"Could not find a closing {marker} in {path}")
with open(path, "w") as f:
    f.write(content[:idx] + block + content[idx:])
PYEOF
    echo "Added eve.json localfile block"
fi

echo "Restarting manager..."
systemctl restart wazuh-manager

echo
echo "Done. Drop rules enabled: $(grep -c '^drop' /var/lib/suricata/rules/suricata.rules || true)"
echo "Verify with: sudo systemctl status suricata  and  sudo tail /var/log/suricata/fast.log"
