export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
/usr/local/bin/lnmesh-measure /usr/local/bin/lncli-mesh openchannel --node_key 03cd827eec8b43eca89da7b1720ea7e37460bb7c0a06b48de5964f234125aede2f --local_amt 500000 --push_amt 200000 --private --sat_per_vbyte 1