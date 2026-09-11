#!/usr/bin/env bash
set -euo pipefail
readonly SERVICE_FILE=/etc/avahi/services/lnmesh-enrollment.service
case "${1:-}" in
  start)
    install -d -m 0755 /etc/avahi/services
    printf '%s\n' \
      '<?xml version="1.0" standalone="no"?>' \
      '<!DOCTYPE service-group SYSTEM "avahi-service.dtd">' \
      '<service-group>' \
      '  <name replace-wildcards="yes">LNMesh enrollment on %h</name>' \
      '  <service><type>_lnmesh-enroll._tcp</type><port>22</port></service>' \
      '</service-group>' > "$SERVICE_FILE"
    systemctl reload avahi-daemon.service
    ;;
  stop)
    if [[ -e "$SERVICE_FILE" ]]; then
      rm -f -- "$SERVICE_FILE"
      systemctl reload avahi-daemon.service
    fi
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
