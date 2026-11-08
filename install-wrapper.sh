#!/usr/bin/env bash
# Install the `herdr` launcher so `herdr update` runs this fork's pipeline instead
# of upstream's downloader (official release assets are unpatched, and the
# pane-colour half of the patch is server-side).
#
#   ./install-wrapper.sh              install into ~/.local (default)
#   HERDR_PREFIX=/opt/x ./install-wrapper.sh
#
# Layout afterwards:
#   ~/.local/bin/herdr          launcher  (intercepts `update`, execs the real binary otherwise)
#   ~/.local/lib/herdr/herdr    the real binary, with .bak beside it
#   ~/.local/lib/herdr/selfupdate.sh
#
# Safe to re-run: it refreshes the launcher and selfupdate.sh in place and never
# touches the real binary once the launcher is installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HERDR_PREFIX:-$HOME/.local}"
LIB="$PREFIX/lib/herdr"
BIN="$PREFIX/bin"
MARKER="HERDR_LAUNCHER_V1"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$HERE/herdr-wrapper.sh" ] || die "herdr-wrapper.sh must sit next to this script ($HERE)"
[ -f "$HERE/selfupdate.sh" ] || die "selfupdate.sh must sit next to this script ($HERE)"

command -v herdr >/dev/null || die "no herdr on PATH — install herdr first"
current="$(readlink -f "$(command -v herdr)" 2>/dev/null || command -v herdr)"

# A shell script on PATH is either our launcher or something we do not understand.
if [ "$(head -c2 "$current")" = "#!" ] && ! grep -q "$MARKER" "$current"; then
  die "$current is a shell script that is not our launcher — refusing to install over it"
fi

is_binary() {
  case "$(file -b "$1" 2>/dev/null)" in
    *ELF*|*Mach-O*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$current" in
  /nix/store/*|*/Cellar/*|*/.local/share/mise/*|*/.local/share/rtx/*)
    die "herdr at $current is package-managed; this launcher expects a direct install" ;;
esac

mkdir -p "$LIB" "$BIN"

if grep -q "$MARKER" "$current" 2>/dev/null; then
  say "launcher already installed"
  BIN="$(dirname "$current")"
else
  say "installing"
  if [ "$current" = "$LIB/herdr" ] || is_binary "$LIB/herdr" && [ "$(dirname "$current")" = "$LIB" ]; then
    : # already in place
  elif is_binary "$current"; then
    cp "$current" "$LIB/herdr"
    chmod +x "$LIB/herdr"
    echo "real binary  -> $LIB/herdr"
  else
    die "$current is not an executable binary — nothing to keep"
  fi
  BIN="$(dirname "$current")"
  [ -w "$BIN" ] || die "$BIN is not writable — re-run with HERDR_PREFIX pointing somewhere writable, or with sudo"
fi

install -m 755 "$HERE/selfupdate.sh" "$LIB/selfupdate.sh"
install -m 755 "$HERE/herdr-wrapper.sh" "$BIN/herdr"
echo "launcher     -> $BIN/herdr"
echo "selfupdate   -> $LIB/selfupdate.sh"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo
     echo "warning: $BIN is not on PATH — the launcher will not be picked up" ;;
esac

say "check"
"$BIN/herdr" --version
"$BIN/herdr" update --check || true
