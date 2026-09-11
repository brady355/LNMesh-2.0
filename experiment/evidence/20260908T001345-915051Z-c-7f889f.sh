export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
python3 -c 'import time,socket,json; print(json.dumps(dict(hostname=socket.gethostname(),time_ns=time.time_ns())))'