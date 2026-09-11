export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
iperf3 -c 10.10.0.3 -B 10.10.0.2 -t 10 -J --connect-timeout 5000