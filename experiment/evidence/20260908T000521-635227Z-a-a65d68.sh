export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ip neigh show 10.10.0.3; ip neigh del 10.10.0.3 dev bat0; ping -c 3 -W 2 10.10.0.3; ip neigh show 10.10.0.3