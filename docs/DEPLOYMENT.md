# Deployment contract

`install-gateway.sh` and `install-leaf.sh` install the scripts under
`/usr/local/lib/lnmesh`, install the Python control package without an online
package-manager dependency, configure systemd, and enable only the services
appropriate to that role. The process is safe to rerun with the same network
and deployment name.

The gateway installer produces
`/var/lib/lnmesh/export/bootstrap_authorized_key.pub`. Copy that public file to
each leaf and pass it to `install-leaf.sh --bootstrap-key FILE`. The private
half never leaves the gateway. Bootstrap access is a forced-command SSH key and
is removed from each leaf as soon as per-node control and tunnel keys have been
installed.

The installed lifecycle worker uses only restricted per-node SSH/RPC accounts
and implements the following gates before calling `sendpsbt`:

1. Bitcoin Core network is active, is not in IBD, has equal block/header heights,
   and has at least one peer.
2. Every participating leaf is caught up; mainnet tip age is at most two hours
   and testnet4 tip age is at most 24 hours.
3. The retention interlock is clear and `testmempoolaccept` accepts the signed
   transaction.
4. The signed PSBT and operation-state update have been fsynced before network
   publication.

The worker never places PSBTs, RPC passwords, seeds, or `emergency.recover`
exports in process arguments or logs. It transitions only along the state
machine in `lnmeshctl/state.py`.

`scripts/ibss-batman.sh` deliberately brings the physical radio up only on a
real target.  It contains no virtual-interface fallback: failure to enter IBSS
is an error, not permission to silently switch to infrastructure mode.
