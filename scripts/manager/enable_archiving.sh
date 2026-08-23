#!/usr/bin/env bash
# enable_archiving.sh
#
# Optional diagnostic helper, not required for the pipeline to work.
#
# Flips <logall> and <logall_json> from "no" to "yes" in the manager's
# ossec.conf. This makes analysisd write EVERY event it receives (alerted
# or not) into /var/ossec/logs/archives/archives.log, which is invaluable
# for answering "is data even reaching the manager?" while debugging a new
# log source, before you've written a rule for it yet.
#
# Run on the Wazuh manager, with sudo: sudo ./enable_archiving.sh

set -euo pipefail

CONF="/var/ossec/etc/ossec.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "This needs to run as root." >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

cp "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
echo "Backed up $CONF"

sed -i.tmp \
    -e 's#<logall>no</logall>#<logall>yes</logall>#' \
    -e 's#<logall_json>no</logall_json>#<logall_json>yes</logall_json>#' \
    "$CONF"
rm -f "$CONF.tmp"

echo "logall / logall_json set to yes. Restarting manager..."
/var/ossec/bin/wazuh-control restart

echo
echo "Tail the archive with:"
echo "  sudo tail -f /var/ossec/logs/archives/archives.log"
