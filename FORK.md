# This is a build fork of herdr

Upstream: [herdrdev/herdr](https://github.com/herdrdev/herdr) (Apache-2.0). This
repository exists to build a patched herdr for a handful of machines. It is not
upstream, and the herdr authors do not read issues or pull requests here.

Branch `local/pane-theme` = upstream tag `v0.9.5` + one code commit (the rest are
CI and tooling). The code change:

1. **Panes report the theme's colours.** herdr paints panes with its theme but
   left each pane's VT default fg/bg/ANSI palette at the host terminal's values
   (or libghostty's defaults), so a program inside a pane that asked for the
   background — OSC 10/11/4 — was told a colour the pane was not drawn on. That
   made TUIs derive unreadable palettes (light panels and pale text on a dark
   pane). The pane defaults now come from the active theme, are re-applied when
   the theme changes and to new panes, and OSC replies are rewritten to match.
   The theme wins over the host's reported colours deliberately: terminals report
   theirs once at startup, so after a macOS switch the host colour describes the
   previous appearance. A `terminal` theme (Reset tokens) keeps host colours.
2. **macOS appearance probe.** Apple Terminal never answers OSC colour queries and
   never sends `CSI ? 997`, so `theme.auto_switch` could not follow macOS. The
   client now polls `defaults read -g AppleInterfaceStyle` and injects the same
   report a reporting terminal would send.

Files touched: `src/terminal_theme.rs`, `src/app/theme_sync.rs`,
`src/app/mod.rs`, `src/terminal/runtime.rs`, `src/pane/terminal.rs`,
`src/client/mod.rs`. Upstream files are otherwise unmodified; the modifications
are marked with comments in the files they touch.

## Building

`.github/workflows/local-macos-client.yml` builds `herdr-linux-x86_64` on
ubuntu-latest and `herdr-macos-aarch64` on macos-latest from this source. Upstream
release assets are **not** suitable: they are unpatched, and the pane-colour half
is server-side.

## Updating

The fork is rebased onto each upstream tag by `upgrade-herdr.sh` (rebase,
regenerate the patch, push; CI builds). On an installed machine, `herdr update`
runs `selfupdate.sh`, which does exactly that and then installs the artifact for
the platform — see `install-wrapper.sh` for the launcher that wires it in.

On the server it finishes with a **live handoff** (`herdr server live-handoff
--import-exe`): the running server passes its sockets and pane PTYs to the new
binary, so panes and their child processes keep running — no `pi --session`
resume, no lost in-flight turn. `herdr update --restart` kills and restarts
instead (panes come back through `pi --session`), and a server too old to hand
off falls back to printing that command.

## Installing the tooling on a client machine

Keep the scripts out of `$HOME` itself:

```sh
mkdir -p ~/bin
scp antigravity:/mnt/dev-antigravity/herdr/{install-wrapper.sh,herdr-wrapper.sh,selfupdate.sh} ~/bin/
~/bin/install-wrapper.sh          # launcher -> ~/.local/bin/herdr, copies selfupdate.sh to ~/.local/lib/herdr
herdr update                      # fetches the published build, no gh or token needed
```

`install-wrapper.sh` only needs its two siblings in the same directory; where
they live is up to you. Afterwards the pieces are `~/.local/bin/herdr` (launcher),
`~/.local/lib/herdr/herdr` (binary, `.bak` beside it) and
`~/.local/lib/herdr/selfupdate.sh` — nothing else is written to `$HOME`.

## Upstreaming

Both behaviours are upstream-shaped bug fixes. If upstream takes either one, drop
that hunk from the branch rather than carrying it forever.
