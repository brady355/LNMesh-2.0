export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
mesh_mac=$(cat /sys/class/net/bat0/address)
sed -i '/^MESH_MAC=/d' /etc/lnmesh/mesh.env
printf 'MESH_MAC=%s\n' "$mesh_mac" >> /etc/lnmesh/mesh.env
python3 - <<'PY'
from pathlib import Path
p=Path('/usr/local/sbin/lnmesh-mesh')
s=p.read_text()
if 'ip link set bat0 address' not in s:
    s=s.replace('ip link set bat0 up','ip link set bat0 address "$MESH_MAC"\nip link set bat0 up')
p.write_text(s)
PY
bash -n /usr/local/sbin/lnmesh-mesh
cat /etc/lnmesh/mesh.env
sha256sum /usr/local/sbin/lnmesh-mesh
