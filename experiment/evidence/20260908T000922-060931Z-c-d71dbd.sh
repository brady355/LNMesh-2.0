export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -e
test -z "$(ip -4 route show default)"
test -z "$(ip -6 route show default)"
test -z "$(ip -o addr show dev eth0)"