#!/usr/bin/env bash
# Runs on the gateway. Builds xrpld 3.2.1 from source on the Pi 5 (aarch64,
# Debian 13, gcc 14) with Conan 2, CMake 3.31 and Ninja from a pip virtual
# environment in ~/xrpl-build-venv. The build needs no sudo. It took 2 hours on
# 13 September 2026 with JOBS=3, 80 minutes for the dependencies and 40 minutes
# for xrpld itself. The log goes to ~/lnmesh-xrp/logs/build-xrpld.log.
# Before the build:
#   git clone --depth 1 --branch 3.2.1 https://github.com/XRPLF/rippled.git ~/src/rippled
#   python3 -m venv ~/xrpl-build-venv && ~/xrpl-build-venv/bin/pip install conan 'cmake<4' ninja
# After the build:
#   strip -o ~/bin/xrpld ~/src/rippled/.build/xrpld
set -euo pipefail
export PATH=$HOME/xrpl-build-venv/bin:$PATH
SRC=$HOME/src/rippled
B=$SRC/.build
JOBS=${JOBS:-3}

while pgrep -f 'git clone' >/dev/null; do sleep 5; done
cd "$SRC"; git log -1 --oneline
# The conan.lock of the repository pins recipe revisions that no longer exist
# on the remotes, so the build ignores the lock file.
[ -f conan.lock ] && mv -f conan.lock conan.lock.disabled

conan profile detect --force >/dev/null 2>&1 || true
P=$(conan config home)/profiles/default
cat > "$P" <<PROF
[settings]
os=Linux
arch=armv8
build_type=Release
compiler=gcc
compiler.version=14
compiler.cppstd=20
compiler.libcxx=libstdc++11

[conf]
tools.build:jobs=$JOBS
PROF
cat "$P"
conan remote add --index 0 --force xrplf https://conan.xrplf.org/repository/conan/
conan remote list

mkdir -p "$B"; cd "$B"
echo "== conan install start $(date -u +%FT%TZ) =="
conan install .. --output-folder . --build missing --settings build_type=Release \
  -o '&:xrpld=True' -o '&:tests=False' -o '&:rocksdb=False'
echo "== conan install done $(date -u +%FT%TZ) =="
echo "== cmake configure $(date -u +%FT%TZ) =="
cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE:FILEPATH=build/generators/conan_toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release -Dxrpld=ON -Dtests=OFF -Drocksdb=OFF -Dunity=OFF ..
echo "== cmake build start $(date -u +%FT%TZ) =="
cmake --build . --parallel "$JOBS"
echo "== build done $(date -u +%FT%TZ) =="
ls -la "$B"/xrpld "$B"/rippled 2>/dev/null || find "$B" -maxdepth 2 -type f -name 'xrpld*' -o -maxdepth 2 -type f -name 'rippled'
