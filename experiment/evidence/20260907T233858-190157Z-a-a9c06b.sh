export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
/usr/local/bin/lnmesh-measure /usr/local/bin/lncli-mesh openchannel --node_key 030b7a54e192c3c99b05b97e3a90e3598e44173726b0f0a889e07c3bc82495f2c1 --local_amt 1000000 --private --sat_per_vbyte 1 --push_amt 400000