#!/usr/bin/env bash
# Emit the version-pinned manifest consumed by a future image-builder pipeline.
set -euo pipefail
IFS=$'\n\t'

out="${1:-build/manifest.json}"
mkdir -p "$(dirname "$out")"
printf '%s\n' \
  '{' \
  '  "bitcoin_core": "31.1",' \
  '  "bitcoin_core_arm64_sha256": "dcf1873f2208ba4f962f3398d47e154c39c0084be8f4553e05c940d0ace3d004",' \
  '  "core_lightning": "26.06.7",' \
  '  "core_lightning_ubuntu_24_04_arm64_sha256": "322c8a3093c97fdad90fe289687dd5b38214845c81bd0b4a393abb7f7217217e",' \
  '  "platform": "Raspberry Pi OS Lite 64-bit Trixie",' \
  '  "kernel": "6.18",' \
  '  "networks": ["regtest", "testnet4", "bitcoin"],' \
  '  "roles": ["gateway", "node"],' \
  '  "image_artifacts": 6,' \
  '  "note": "Fetch release manifests and verify signatures in the image-builder CI before binary installation."' \
  '}' > "$out"
printf 'wrote %s\n' "$out"
