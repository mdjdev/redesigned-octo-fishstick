#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/gitwatch-pre-flight.sh || exit 1

exec /usr/local/bin/gitwatch "$@" 1>&1 2>&1
