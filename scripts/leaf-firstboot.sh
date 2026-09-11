#!/usr/bin/env bash
# First-boot identity setup for the reusable leaf image.
set -euo pipefail
IFS=$'\n\t'

readonly MARKER="/var/lib/lnmesh/.firstboot-complete"
readonly BOOTSTRAP_KEY="/etc/lnmesh/bootstrap_authorized_key"

die() { echo "leaf-firstboot: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "must run as root"
[[ ! -e "$MARKER" ]] || exit 0

# The image must have had these artefacts removed before it was cloned.
systemd-machine-id-setup
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
install -d -m 0700 /var/lib/lnmesh /var/lib/lnmesh/journal
[[ -s "$BOOTSTRAP_KEY" ]] || die "missing deployment bootstrap public key"
install -d -m 0700 /root/.ssh
key_material="$(cat "$BOOTSTRAP_KEY")"
printf 'restrict,command="/usr/local/lib/lnmesh/bootstrap-shell.sh" %s\n' "$key_material" > /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

# Do not create Core Lightning state here.  Enrollment assigns the identity,
# per-node RPC slot, and hostname before lightningd is allowed to start.
touch "$MARKER"
chmod 0600 "$MARKER"
systemctl start lnmesh-ibss.service
