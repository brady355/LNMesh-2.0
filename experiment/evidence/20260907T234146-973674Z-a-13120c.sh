export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
systemd-run --unit=lnmesh-iperf-b-a-3 --property=RuntimeMaxSec=30 /usr/bin/iperf3 -s -1 -B 10.10.0.1 -J