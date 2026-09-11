# noctalia-plugins

Personal collection of forked/patched [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugins.

Each top-level directory is one plugin, laid out exactly like upstream's
`official-plugins`/`community-plugins` repos (a `plugin.toml` at its root, entry
`.luau` files, etc.) so this whole repo can be registered directly as a
Noctalia plugin *source*.

## Plugins

- [`claude-code/`](claude-code) — original, not a fork. An interactive Claude Code
  console: a persistent streaming session behind a small Python sidecar (the Luau
  API can read a process but not write to one), a transcript that formats
  thinking, tool calls and their output, inline Allow/Deny cards for tool
  permission requests, and subscription usage in the bar. Model and permission
  mode are read from the live session and changed through the CLI's own control
  protocol, so nothing about Claude Code's options is hardcoded here.
- [`bitdjinn/`](bitdjinn) — fork of [nirvam/bitdjinn](https://github.com/noctalia-dev/community-plugins/tree/main/bitdjinn),
  renamed to `duchovs/bitdjinn`. Adds click-through to TradingView, in-panel
  add/remove of tickers, and drag-to-reorder tickers in the panel.
- [`notes/`](notes) — fork of [noctalia/notes](https://github.com/noctalia-dev/official-plugins/tree/main/notes),
  renamed to `duchovs/notes`. Adds an eye-button toggle in the editor header
  that swaps the raw buffer for a rendered `ui.markdown` preview (requires
  `plugin_api >= 21`).
- [`tasks/`](tasks) — original plugin, `duchovs/tasks`. Nextcloud Tasks lists
  synced over CalDAV, with per-list color coding, filters, and quick capture
  from a bar widget, side panel, and `/td` launcher prefix.

## Setting up on a new device

```sh
git clone https://github.com/duchovs/noctalia-plugins ~/.local/share/noctalia-plugins-local
noctalia msg plugins source add personal path ~/.local/share/noctalia-plugins-local
noctalia msg plugins enable duchovs/bitdjinn   # and any other plugin folders you want
```

Then add the plugin's bar/panel widgets to `~/.config/noctalia/config.toml`
under `[bar.default]` (e.g. `duchovs/bitdjinn:bar` in the `start`/`center`/`end`
array) if it has one.

## Adding another forked plugin

1. If forking a plugin out of a monorepo (official-plugins/community-plugins),
   preserve its history with `git subtree split --prefix=<plugin-dir> --branch=<plugin>-only`
   from a fresh clone of the upstream repo, then push that branch here as a
   new top-level directory (same pattern as `bitdjinn/` — see its commit history).
2. Give the plugin a unique `id` in its `plugin.toml` (e.g. `duchovs/<name>`)
   so it doesn't collide with the original if both are ever installed side by
   side.
3. Fix any place inside the plugin that hardcodes its own old plugin id
   (e.g. `noctalia.togglePanel("<old-id>:panel")` in bar/desktop widgets) to
   use the new id.
4. `noctalia msg plugins source update personal` (or whatever the source is
   named on that machine) to pick up the new folder, then
   `noctalia msg plugins enable duchovs/<name>`.
