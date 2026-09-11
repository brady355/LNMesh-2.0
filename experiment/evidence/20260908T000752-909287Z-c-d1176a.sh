export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
systemd-run --unit=lnmesh-reboot --on-active=3s /usr/bin/systemctl reboot