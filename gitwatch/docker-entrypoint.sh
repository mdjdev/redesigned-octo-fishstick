#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/gitwatch-pre-flight.sh || exit 1

exec /usr/local/bin/gitwatch "$@" 1>&1 2>&1

# exec /usr/local/bin/gitwatch "$@" 1>&1 2>&1 &
# git --git-dir=/mnt/.git --work-tree=/mnt/repo diff -z --name-only \
#   | xargs -0 -r -I{} touch -m "/mnt/repo/{}"