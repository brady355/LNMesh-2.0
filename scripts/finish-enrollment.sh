#!/usr/bin/env bash
set -euo pipefail
systemctl disable --now lnmesh-enrollment.service >/dev/null 2>&1 || true
systemctl restart lnmesh-ibss.service
systemctl restart lnmesh-isolation.service
