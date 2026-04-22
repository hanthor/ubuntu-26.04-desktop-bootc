#!/usr/bin/env bash

set -xeuo pipefail

git clone "https://github.com/hanthor/bootc.git" .
# Use ZFS dataset block-device fix from hanthor/bootc
git checkout 71fcbe5de06eabb7ebf90643442ec704976de06f

make bin install-all DESTDIR=/output
