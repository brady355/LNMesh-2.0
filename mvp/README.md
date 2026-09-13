# MVP: full Bitcoin nodes on every Pi and a Bitcoin bus a-b-c

Targets the lnmesh-a/b/c build (hostnames lnmesh-a, lnmesh-b, lnmesh-c,
SSH aliases of the same name with lnmesh-b and lnmesh-c jumping through
lnmesh-a). Edit `hosts.env` for your addresses.

Order on a running mesh:

```bash
# download bitcoin-29.1-aarch64-linux-gnu.tar.gz and SHA256SUMS from
# bitcoincore.org into /tmp, verify with sha256sum -c, then:
./mvp.sh copy       # tarball to all three Pis
./mvp.sh reset      # move old LND state to /var/backups/lnmesh on each Pi
./mvp.sh bitcoind   # install + configure bitcoind: a<-b<-c bus peering
./mvp.sh lnd        # LND on all three with local bitcoind (./mvp.sh lnd neutrino for light-client leaves)
./mvp.sh fund       # mine to a, send 2,000,000 sat on-chain to b and c
./mvp.sh verify     # heights, peers, backend, sync
./mvp.sh bus-test   # c opens a channel to b; funding tx must reach a through b
```

Expected `verify` output: same height on all three, a peers only with b,
c peers only with b, backend bitcoind, synced_to_chain true.
