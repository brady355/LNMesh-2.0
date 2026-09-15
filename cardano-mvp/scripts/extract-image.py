#!/usr/bin/env python3
"""Extracts a Docker image layer tarball into a directory without Docker.

The hydra-node image is a nix closure, so its directories are read-only with
mode 0555. GNU tar trips over that as an ordinary user, so this script uses the
tarfile module of Python and adds the owner write bit to everything it creates.

Usage: extract-image.py hydra-layer.tar.gz hydra-image
"""
import os
import shutil
import stat
import sys
import tarfile

layer, dest = sys.argv[1], sys.argv[2]

if os.path.isdir(dest):
    for root, dirs, files in os.walk(dest):
        for d in dirs:
            os.chmod(os.path.join(root, d), 0o700)
    shutil.rmtree(dest)
os.makedirs(dest)


def fix(member, path):
    member = tarfile.tar_filter(member, path)
    member.mode |= 0o700 if member.isdir() else 0o200
    return member


with tarfile.open(layer) as t:
    t.extractall(dest, filter=fix)
open(os.path.join(dest, ".ok"), "w").close()
print("extracted", layer, "to", dest)
