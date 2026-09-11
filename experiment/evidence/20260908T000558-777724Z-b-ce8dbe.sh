export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ip neigh show 10.10.0.3; ip neigh replace 10.10.0.3 lladdr a2:8a:1f:07:7e:04 nud reachable dev bat0