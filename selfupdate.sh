#!/usr/bin/env bash
# Our update pipeline, wired in as `herdr update`.
#
# Upstream's `herdr update` downloads an official release asset, which is
# unpatched — installing it silently drops the pane-colour fix (that half is
# server-side). This script instead rebases the local patch onto the newest
# upstream tag, lets CI build both binaries from the patched source, and installs
# the build for this platform.
#
#   selfupdate.sh              update the binary and hand the server over to it
#   selfupdate.sh --restart    kill and restart the server instead (panes resume via pi --session)
#   selfupdate.sh --check      only report whether upstream has a newer tag
#   selfupdate.sh --tag v0.9.7 update onto a specific tag
#
# Where the fork is checked out (the Linux server) it rebases and pushes; anywhere
# else it just installs the newest published build. `gh` is optional: the binaries
# are published as assets of a moving release, which plain HTTPS can fetch.
#
# Exit codes: 0 updated or already current, 1 failure, 2 usage.
set -euo pipefail

SRC="${HERDR_FORK:-/mnt/dev-antigravity/herdr}"
REPO="${HERDR_FORK_REPO:-adrianma00/herdr}"
BRANCH="${HERDR_FORK_BRANCH:-local/pane-theme}"
RELEASE="${HERDR_RELEASE_TAG:-local-latest}"
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
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux)  ARTIFACT=herdr-linux-x86_64 ;;
  Darwin) ARTIFACT=herdr-macos-aarch64 ;;
  *) die "unsupported platform $(uname -s)" ;;
esac

HAVE_GH=0
command -v gh >/dev/null 2>&1 && HAVE_GH=1

# 1. Rebase where the fork lives; elsewhere the build is already published.
if [ -d "$SRC/.git" ]; then
  say "upstream state"
  # --force: the release job moves the local-latest tag on every build, and a plain
  # `fetch --tags` refuses to clobber it, which failed the whole update.
  git -C "$SRC" fetch -q --tags --force origin
  git -C "$SRC" fetch -q --tags --force upstream
  LATEST="$(git -C "$SRC" tag --list 'v*' --sort=-v:refname | head -1)"
  [ -n "$TAG" ] || TAG="$LATEST"
  # --match v*: the release job also tags the branch head `local-latest`.
  CURRENT_BASE="$(git -C "$SRC" describe --tags --abbrev=0 --match 'v*' "$BRANCH" 2>/dev/null || echo unknown)"
  echo "newest upstream tag : $TAG"
  echo "branch base         : $CURRENT_BASE"

  if [ "$CHECK_ONLY" = 1 ]; then
    [ "$CURRENT_BASE" = "$TAG" ] && { echo "already on $TAG — nothing to do"; exit 0; }
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
  if [ "$CHECK_ONLY" = 1 ]; then
    echo "no fork checkout at $SRC — this host installs the published build"
    exit 0
  fi
  say "no fork checkout here — installing the newest published build"
fi

# 2. Wait for the build of this commit (needs gh and the fork's history).
if [ "$HAVE_GH" = 1 ]; then
  HEAD_SHA="$(gh api "/repos/$REPO/branches/$BRANCH" --jq .commit.sha 2>/dev/null || true)"
  if [ -n "$HEAD_SHA" ]; then
    say "waiting for the CI build of $HEAD_SHA"
    deadline=$(( $(date +%s) + TIMEOUT_S ))
    started=$(date +%s)
    while :; do
      run="$(gh run list -R "$REPO" -b "$BRANCH" -L 20 \
            --json databaseId,headSha,conclusion,status \
            --jq "[.[] | select(.headSha==\"$HEAD_SHA\")][0] | \"\(.databaseId) \(.status) \(.conclusion // \"-\")\"" 2>/dev/null || true)"
      # A docs-only commit is skipped by the workflow's paths-ignore, so a run for
      # the head sha may never appear. Fall back to the newest successful build.
      if [ -z "$run" ] && [ $(( $(date +%s) - started )) -gt 120 ]; then
        newest="$(gh run list -R "$REPO" -b "$BRANCH" -L 20 --json headSha,conclusion \
          --jq '[.[] | select(.conclusion=="success")][0].headSha' 2>/dev/null || true)"
        if [ -n "$newest" ] && [ "$newest" != "$HEAD_SHA" ]; then
          echo "no run for $HEAD_SHA (docs-only commit?) — using the newest build, ${newest:0:8}"
          HEAD_SHA="$newest"
        fi
      fi
      case "$run" in
        *" completed success") break ;;
        *" completed "*) die "CI failed for $HEAD_SHA: gh run view ${run%% *} -R $REPO" ;;
        "") echo "no run yet for $HEAD_SHA" ;;
        *) echo "run ${run%% *}: ${run#* }" ;;
      esac
      [ "$(date +%s)" -lt "$deadline" ] || die "timed out waiting for CI; gh run list -R $REPO -L 5"
      sleep 20
    done
  fi
fi

# 3. Download. Release assets are public HTTPS; CI artifacts need a token.
say "downloading $ARTIFACT"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if curl -fsSL -o "$tmp/$ARTIFACT" \
    "https://github.com/$REPO/releases/download/$RELEASE/$ARTIFACT" 2>/dev/null; then
  echo "from release $RELEASE"
elif [ "$HAVE_GH" = 1 ]; then
  gh run download -R "$REPO" -n "$ARTIFACT" -D "$tmp" >/dev/null
  echo "from the newest CI run"
else
  die "no release asset at $REPO and no gh CLI to fall back on"
fi
curl -fsSL -o "$tmp/BUILD_INFO.txt" \
  "https://github.com/$REPO/releases/download/$RELEASE/BUILD_INFO.txt" 2>/dev/null || true
cat "$tmp/BUILD_INFO.txt" 2>/dev/null || true

# 4. Install beside the launcher, keeping a backup.
TARGET="$(command -v herdr || true)"
[ -n "$TARGET" ] || die "herdr not on PATH"
REAL="$(readlink -f "$TARGET" 2>/dev/null || echo "$TARGET")"
LIB_REAL="$(cd "${TARGET%/*}/../lib/herdr" 2>/dev/null && pwd)/herdr"
[ -x "$LIB_REAL" ] && REAL="$LIB_REAL"

say "installing"
cp "$REAL" "$REAL.bak"
cp "$tmp/$ARTIFACT" "$REAL.new"
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

# Hand the running server over to the new binary. This is the update path's own
# mechanism: the old server passes its sockets and pane PTYs to the new process,
# so panes and their child processes keep running — no `pi --session` resume, no
# lost in-flight turn.
if [ "$RESTART" = 1 ]; then
  say "restarting the server (panes resume through pi --session)"
  herdr server stop || true
else
  say "handing the server over to the new binary"
  if out="$(herdr server live-handoff --import-exe "$REAL" 2>&1)"; then
    printf '%s\n' "$out" | tail -2
  else
    printf '%s\n' "$out" | tail -3
    cat <<'EOF'

Live handoff failed (the running server may predate it). Restart when convenient:

    herdr server stop        # panes come back through `pi --session <path>`

or re-run this script with --restart.
EOF
  fi
fi
