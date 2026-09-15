#!/usr/bin/env bash
# Installed as ~/lnmesh-ada/bin/hydra-node on the gateway and on the leaves.
# Runs the nix-built hydra-node 2.4.1 from the linux/arm64 Docker image
# ghcr.io/cardano-scaling/hydra-node:2.4.1 without Docker and without root. The
# glibc loader of the image resolves the bundled shared libraries. The Hydra
# project publishes no aarch64 Linux binary in its GitHub releases, and the Pis
# have neither Docker nor sudo, so this wrapper fills the gap.
IMG=${HYDRA_IMAGE:-$HOME/lnmesh-ada/hydra-image}
LD=$(echo "$IMG"/nix/store/*-glibc-*/lib/ld-linux-aarch64.so.1)
BIN=$(echo "$IMG"/nix/store/*-hydra-node-exe-hydra-node-*/bin/hydra-node)
LIBS=""
for d in "$IMG"/nix/store/*/lib; do
  ls "$d"/*.so* >/dev/null 2>&1 && LIBS="$LIBS$d:"
done
export LANG=C.UTF-8 LC_ALL=C.UTF-8   # hydra-node writes a micro sign to stderr, so it crashes without a UTF-8 locale
export PATH=$HOME/lnmesh-ada/bin:$PATH
exec "$LD" --library-path "$LIBS" "$BIN" "$@"
