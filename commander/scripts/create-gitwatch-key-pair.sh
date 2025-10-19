#!/usr/bin/env bash
set -euo pipefail

: "${HOME:=/volume1/homes/dsm_admin}"
: "${SSH_PATH:=/volume1/homes/dsm_admin/.ssh}"
: "${SSH_KEY:=/volume1/homes/dsm_admin/.ssh/id_ed25519_github}"

chmod 755 "$HOME"; 

mkdir -p "$SSH_PATH"
chmod 700 "$SSH_PATH"; 

if [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "gitwatch-$(hostname)" >/dev/null
fi
chmod 600 "$SSH_KEY"
