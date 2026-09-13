#!/bin/bash
# Move LND state (wallet, channels, graph, logs) into a backup directory and start over.
# The bitcoind chain is kept. Usage: sudo bash < reset-lnd.sh
set -euo pipefail
D=/var/backups/lnmesh/lnd-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$D"
systemctl stop lnd 2>/dev/null || true
for x in /var/lib/lnd/data /var/lib/lnd/logs /etc/lnmesh/mine.addr; do [ -e "$x" ] && mv "$x" "$D/"; done
chown -R root:root "$D"; chmod 700 "$D"
echo "$(hostname): LND state moved to $D"
