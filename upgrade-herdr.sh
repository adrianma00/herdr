#!/usr/bin/env bash
# Rebase the local herdr patch onto a newer release, rebuild, and optionally install.
#
#   ./upgrade-herdr.sh                 rebase onto the newest v* tag, build for this host
#   ./upgrade-herdr.sh v0.9.7          rebase onto a specific tag
#   ./upgrade-herdr.sh --install       ...and swap the binary into place
#   ./upgrade-herdr.sh --mac           cross-build the macOS client (aarch64) instead
#   ./upgrade-herdr.sh --mac --install ...and leave it at build/herdr-aarch64-macos
#
# The patch lives on branch `local/pane-theme` in SRC as one commit on top of the
# release tag, so an upgrade is a rebase, not a re-apply. If the rebase conflicts,
# resolve it in SRC and run `git rebase --continue`, then re-run this script.
set -euo pipefail

SRC="${SRC:-/mnt/dev-antigravity/herdr}"
BRANCH="${BRANCH:-local/pane-theme}"
ZIG="${ZIG:-/home/ama/build/zig-x86_64-linux-0.16.0/zig}"
PATCH_OUT="${PATCH_OUT:-/mnt/dev-antigravity/herdr/herdr-pane-theme.patch}"
REMOTE="${REMOTE:-origin}"
PUSH="${PUSH:-1}"

INSTALL=0
MAC=0
TAG=""
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --mac) MAC=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) TAG="$arg" ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$SRC/.git" ] || die "no checkout at $SRC"
git -C "$SRC" diff --quiet || die "uncommitted changes in $SRC — commit or stash them first"

say "fetching tags"
git -C "$SRC" fetch -q --tags origin
if [ -z "$TAG" ]; then
  TAG="$(git -C "$SRC" tag --list 'v*' --sort=-v:refname | head -1)"
fi
echo "target: $TAG ($(git -C "$SRC" log -1 --format=%s "$TAG"))"

say "rebasing $BRANCH onto $TAG"
git -C "$SRC" checkout -q "$BRANCH"
if ! git -C "$SRC" rebase "$TAG"; then
  cat <<EOF

Conflict while rebasing. Resolve it, then:

  cd $SRC
  git add -A && git rebase --continue
  $0 ${TAG}${INSTALL:+ --install}

EOF
  exit 1
fi
git -C "$SRC" diff "$TAG".."$BRANCH" > "$PATCH_OUT"
echo "patch: $PATCH_OUT ($(git -C "$SRC" diff --shortstat "$TAG".."$BRANCH"))"

if [ "$PUSH" = 1 ]; then
  say "pushing $BRANCH to $REMOTE"
  git -C "$SRC" push --force-with-lease "$REMOTE" "$BRANCH"
  echo "GitHub builds the macOS client on that push:"
  echo "  gh run watch -R adrianma00/herdr \$(gh run list -R adrianma00/herdr -L1 --json databaseId --jq '.[0].databaseId')"
  echo "  gh run download -R adrianma00/herdr -n herdr-macos-aarch64"
fi

if [ "$MAC" = 1 ]; then
  say "cross-building aarch64-apple-darwin (cargo zigbuild)"
  rustup target list --installed | grep -qx aarch64-apple-darwin \
    || rustup target add aarch64-apple-darwin
  command -v cargo-zigbuild >/dev/null || die "install it: cargo install cargo-zigbuild --locked"
  ( cd "$SRC" && ZIG="$ZIG" cargo zigbuild --release --locked --target aarch64-apple-darwin )
  BIN="$SRC/target/aarch64-apple-darwin/release/herdr"
  [ -x "$BIN" ] || die "cross-build produced no binary"
  OUT="/home/ama/build/herdr-aarch64-macos"
  cp "$BIN" "$OUT"
  file "$OUT"
  echo
  echo "copy to the Mac:  scp $OUT mac:~/herdr.new"
  echo "then on the Mac:  cp \$(command -v herdr) \$(command -v herdr).bak && mv ~/herdr.new \$(command -v herdr)"
  echo "                  ctrl+b q, then relaunch herdr"
else
  say "building for this host"
  ( cd "$SRC" && ZIG="$ZIG" cargo build --release --locked )
  BIN="$SRC/target/release/herdr"
  [ -x "$BIN" ] || die "build produced no binary"
  echo "binary: $BIN"
  if [ "$INSTALL" = 1 ]; then
    target="$(command -v herdr || true)"
    [ -n "$target" ] || die "herdr not on PATH"
    cp "$target" "$target.bak"
    cp "$BIN" "$target.new"
    mv "$target.new" "$target"
    echo "installed $target (backup $target.bak) — restart the server to use it"
  fi
fi
