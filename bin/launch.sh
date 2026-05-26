#!/bin/bash
# Wrapper used by `podman exec -d` so the cwd is right before exec'ing serve.sh.
# Points at the live serve.sh in $HOME; if you make this repo the source of truth,
# switch to: cd "$(dirname "$0")/.." && exec ./serve.sh
cd "$HOME" || exit 1
exec ./serve.sh
