#!/usr/bin/env bash
# Our update pipeline, wired in as `herdr update`.
#
# Upstream's `herdr update` downloads an official release asset, which is
# unpatched — installing it silently drops the pane-colour fix (that half is
# server-side). This script instead rebases the local patch onto the newest
# upstream tag, lets CI build both binaries from the patched source, and installs
# the artifact for this platform.
#
#   selfupdate.sh              update the binary for this host
#   selfupdate.sh --restart    ...and restart the server (panes resume via pi --session)
#   selfupdate.sh --check      only report whether upstream has a newer tag
#   selfupdate.sh --tag v0.9.7 update onto a specific tag
#
# Exit codes: 0 updated or already current, 1 failure, 2 usage.
set -euo pipefail

SRC="${HERDR_FORK:-/mnt/dev-antigravity/herdr}"
REPO="${HERDR_FORK_REPO:-adrianma00/herdr}"
BRANCH="${HERDR_FORK_BRANCH:-local/pane-theme}"
TIMEOUT_S="${HERDR_UPDATE_TIMEOUT:-1800}"

RESTART=0
CHECK_ONLY=0
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1 ;;
    --check) CHECK_ONLY=1 ;;
    --handoff) : ;; # upstream's flag: we restart deliberately, not silently
    --tag) shift; TAG="${1:-}" ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux)  ARTIFACT=herdr-linux-x86_64; BIN_NAME=herdr ;;
  Darwin) ARTIFACT=herdr-macos-aarch64; BIN_NAME=herdr ;;
  *) die "unsupported platform $(uname -s)" ;;
esac

command -v gh >/dev/null || die "gh CLI not found (needed to fetch the CI artifact)"

# The rebase only happens where the fork is checked out (the Linux server). A Mac
# client just pulls the artifact CI already built.
if [ -d "$SRC/.git" ]; then
  say "upstream state"
  git -C "$SRC" fetch -q --tags origin
  git -C "$SRC" fetch -q --tags upstream
  LATEST="$(git -C "$SRC" tag --list 'v*' --sort=-v:refname | head -1)"
  [ -n "$TAG" ] || TAG="$LATEST"
  CURRENT_BASE="$(git -C "$SRC" describe --tags --abbrev=0 "$BRANCH" 2>/dev/null || echo unknown)"
  echo "newest upstream tag : $TAG"
  echo "branch base         : $CURRENT_BASE"

  if [ "$CHECK_ONLY" = 1 ]; then
    if [ "$CURRENT_BASE" = "$TAG" ]; then
      echo "already on $TAG — nothing to do"
      exit 0
    fi
    echo "update available: $CURRENT_BASE -> $TAG"
    exit 0
  fi

  say "rebase the patch onto $TAG"
  if ! "$SRC/upgrade-herdr.sh" "$TAG" --no-build >/tmp/herdr-upgrade.log 2>&1; then
    tail -25 /tmp/herdr-upgrade.log >&2
    die "upgrade-herdr.sh failed (see /tmp/herdr-upgrade.log); resolve the rebase in $SRC and re-run"
  fi
  tail -4 /tmp/herdr-upgrade.log
else
  [ "$CHECK_ONLY" = 1 ] && { echo "no fork checkout at $SRC; latest CI artifact will be installed"; exit 0; }
  say "no fork checkout here — installing the newest CI artifact for $BRANCH"
fi

HEAD_SHA="$(gh api "/repos/$REPO/branches/$BRANCH" --jq .commit.sha 2>/dev/null || true)"
[ -n "$HEAD_SHA" ] || die "cannot read $REPO branch $BRANCH"

say "waiting for the CI build of $HEAD_SHA"
deadline=$(( $(date +%s) + TIMEOUT_S ))
run=""
while :; do
  run="$(gh run list -R "$REPO" -b "$BRANCH" -L 20 \
        --json databaseId,headSha,conclusion,status \
        --jq "[.[] | select(.headSha==\"$HEAD_SHA\")][0] | \"\(.databaseId) \(.status) \(.conclusion // \"-\")\"" 2>/dev/null || true)"
  case "$run" in
    *" completed success") break ;;
    *" completed "*) die "CI failed for $HEAD_SHA: gh run view ${run%% *} -R $REPO" ;;
    "") echo "no run yet for $HEAD_SHA" ;;
    *) echo "run ${run%% *}: ${run#* }" ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || die "timed out waiting for CI; gh run list -R $REPO -L 5"
  sleep 20
done
RUN_ID="${run%% *}"

say "downloading $ARTIFACT from run $RUN_ID"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gh run download "$RUN_ID" -R "$REPO" -n "$ARTIFACT" -D "$tmp" >/dev/null
NEW="$(find "$tmp" -type f -name "$ARTIFACT" -o -type f -name "$BIN_NAME" | head -1)"
[ -n "$NEW" ] || die "artifact $ARTIFACT not found in run $RUN_ID"
cat "$tmp/BUILD_INFO.txt" 2>/dev/null || true

TARGET="$(command -v herdr || true)"
[ -n "$TARGET" ] || die "herdr not on PATH"
REAL="$(readlink -f "$TARGET" 2>/dev/null || echo "$TARGET")"
# When the wrapper is installed, the real binary lives beside it under lib/.
LIB_REAL="$(cd "${TARGET%/*}/../lib/herdr" 2>/dev/null && pwd)/herdr"
if [ -x "$LIB_REAL" ]; then
  REAL="$LIB_REAL"
fi

say "installing"
cp "$REAL" "$REAL.bak"
cp "$NEW" "$REAL.new"
chmod +x "$REAL.new"
mv "$REAL.new" "$REAL"
echo "installed $REAL ($("$REAL" --version))"
echo "backup    $REAL.bak"

if [ "$(uname -s)" = Darwin ]; then
  cat <<'EOF'

Quit the herdr TUI (ctrl+b q detaches; the server and panes keep running) and
relaunch `herdr` — a config reload is not enough for a binary swap.
EOF
  exit 0
fi

if [ "$RESTART" = 1 ]; then
  say "restarting the server (panes resume through pi --session)"
  herdr server stop || true
else
  cat <<'EOF'

The running server still uses the old binary. Restart it when convenient:

    herdr server stop        # panes come back through `pi --session <path>`

or re-run this script with --restart.
EOF
fi
