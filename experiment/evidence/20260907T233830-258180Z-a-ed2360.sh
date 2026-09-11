export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
/usr/local/bin/lnmesh-measure /usr/local/bin/lncli-mesh openchannel --node_key 0203692afabd31195b4c27e28c4f8ee76bfb651c84c17b1acab85b1a6219bde1ae --local_amt 1000000 --private --sat_per_vbyte 1 --push_amt 400000