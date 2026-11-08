#!/usr/bin/env bash
# `herdr` launcher. Everything is the real binary except `update`, which runs our
# pipeline instead of upstream's downloader — official release assets are
# unpatched, and the pane-colour half of the patch is server-side, so installing
# one silently loses the fix.
#
# Install:
#   mkdir -p ~/.local/lib/herdr
#   mv "$(command -v herdr)" ~/.local/lib/herdr/herdr          # the real binary
#   install -m 755 herdr-wrapper.sh "$(dirname "$(command -v herdr)")/herdr"
#
# `herdr update` then behaves like:
#   herdr update --check          report whether upstream has a newer tag
#   herdr update                  rebase, build, install the artifact for this OS
#   herdr update --restart        ...and restart the server (panes resume via pi --session)
set -euo pipefail

real="${HERDR_REAL_BIN:-$HOME/.local/lib/herdr/herdr}"
selfupdate="${HERDR_SELFUPDATE:-/mnt/dev-antigravity/herdr/selfupdate.sh}"

if [ "${1:-}" = "update" ]; then
  shift
  [ -x "$selfupdate" ] || {
    echo "herdr update: $selfupdate not found — falling back to the stock updater" >&2
    exec "$real" update "$@"
  }
  exec "$selfupdate" "$@"
fi

exec "$real" "$@"
