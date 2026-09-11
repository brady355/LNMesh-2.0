export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
sed -i 's/^externalip=.*/externalip=10.10.0.3:9736/' /etc/lnd/breach.conf
lncli-breach connect 0203692afabd31195b4c27e28c4f8ee76bfb651c84c17b1acab85b1a6219bde1ae@10.10.0.2:9735
lncli-breach listpeers