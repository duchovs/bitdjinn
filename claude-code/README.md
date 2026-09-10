# Claude Code

An interactive Claude Code console in your Noctalia bar. Open a panel, talk to
Claude Code, watch it think and run tools, answer its permission requests, and
keep an eye on what the session is costing you against your plan — without a
terminal.

The session is **persistent**. One `claude` process is opened on first use and
reused for every message after that, so the second turn does not pay the Node
and MCP startup the first one did, and the cached system-prompt prefix stays
warm across the whole conversation instead of being rebuilt per message.

## Plugin

| Field | Value |
| --- | --- |
| ID | `duchovs/claude-code` |
| Entries | Service: `service` · Panel: `console` · Bar widget: `pill` · Control-center shortcut: `toggle` |

`service` is headless and owns the usage poll and the status mirror. `console` is
the chat panel and the only entry that talks to the sidecar's event stream.
`pill` and `toggle` are thin clients of the state `service` publishes, so putting
up all of them costs one poll.

## Requirements

- Noctalia at plugin API level **24** or newer.
- `claude` — the Claude Code CLI, on `PATH` and already authenticated. Run
  `claude` once in a terminal and sign in. The plugin never sees your
  credentials; it spawns the CLI, which reads its own `~/.claude`.
- `python3` — standard library only. No `pip install`, no `node_modules`.

Both are checked before anything is spawned, and a missing one is reported in
the panel rather than failing silently.

## Usage

Add the **Claude Code** widget to a bar, then click it. Or bind the panel:

```sh
noctalia msg panel-toggle duchovs/claude-code:console
```

Type in the composer and press **Enter** to send; **Shift+Enter** puts in a
newline. While a turn is running the send button becomes a stop button.

| Key | Does |
| --- | --- |
| `Enter` | Send |
| `Shift+Enter` | Newline |
| `Ctrl+C` | Interrupt the running turn — the session survives |
| `Ctrl+L` | Clear the transcript view |
| `Ctrl+K` | Toggle the slash-command palette |
| `Escape` | Close the panel (reserved by the shell) |

### Slash commands

Typing `/` opens a palette of the slash commands **your** session actually has —
built-ins, your skills, plugin commands, everything — read live from the session
at startup. It is not a hardcoded list, so it cannot go stale and it already
knows about commands that shipped after this plugin did.

Anything you type is forwarded to Claude Code verbatim, so `/model`, `/compact`,
`/context`, `/cost`, `/agents` and the rest work exactly as they do in the
terminal. A handful of commands are handled by the console itself, because they
are about the console rather than the conversation:

| Command | Does |
| --- | --- |
| `/new` | Start a fresh session |
| `/clear` | Clear the transcript view (the session keeps its history) |
| `/stop` | Interrupt the running turn |
| `/cwd <path>` | Change the working directory and restart the session there |

### Model and permission mode

The two chips in the header are pickers. The model list is the one your session
reports — display names, descriptions and all — and choosing from either applies
to the **live session**: no restart, no lost context. Under the hood these use
the CLI's own control protocol (`set_model`, `set_permission_mode`), the same
path the Agent SDK uses.

Permission modes are colored by how much rope they give: `Plan` reads and
reasons only, `Bypass` is styled as destructive because it is.

### Permission requests

When the session asks to use a tool, the request appears inline in the
transcript as a card with **Allow** and **Deny**, showing the tool and what it
is about to do. The turn waits for your answer. If you never answer, it is
denied after the configured timeout rather than hanging forever.

Set **Tool permission requests** to *Allow automatically* or *Deny
automatically* if you would rather not be asked — but prefer changing the
permission mode instead, which is what it is for.

### Plan usage

The bar pill shows your subscription usage: the 5-hour session window, the
weekly window, or whichever is higher. It reads the same endpoint Claude Code
itself uses for `/usage`, with the OAuth token the CLI already holds, so the
numbers are the real plan windows rather than a guess from counting local
tokens.

Usage polling is done **in the shell**, not in the sidecar. If you never open
the console, this plugin runs no background process at all — the bar pill costs
one HTTP request every few minutes and nothing else. The sidecar starts on first
use.

Hovering the pill gives you the plan, mode, model, both windows with their reset
countdowns, and the working directory. Middle-click interrupts a running turn;
right-click forces a usage refresh.

## Settings

Deliberately short. Model, permission mode, effort, output style, agent and
every other Claude Code option are runtime state the CLI already owns — they are
changed from the header chips or by typing a slash command, not stored here.
Pinning that surface into a settings screen is exactly what left the old v4
plugin advertising models that no longer existed.

| Setting | Default | Notes |
| --- | --- | --- |
| Claude Code binary | `claude` | Name or absolute path |
| Working directory | *(home)* | `/cwd` changes it live and remembers it |
| Tool permission requests | Ask in the console | Or auto-allow / auto-deny |
| Permission timeout | 120s | So a forgotten prompt cannot wedge the session |
| Idle shutdown | 0 (never) | Keeping it warm is the point; set a value to reclaim it |
| Usage refresh | 5 min | |
| Notify when closed | on | Turn finished, or permission pending |

## How it works

```
  bar pill ─┐                        ┌─ usage  ──→ api.anthropic.com
  shortcut ─┼─ noctalia.state ←── service.luau
            │                        └─ status (mirrors the bridge)
            │
  panel.luau ──── HTTP + SSE ────→ bridge.py ──stdin/stdout──→ claude -p
                                   (one process,   --input-format stream-json
                                    kept warm)     --output-format stream-json
```

Noctalia's Luau API can *read* a process (`runStream`) but cannot write to one —
there is no stdin. A persistent conversation needs to write a message into a
running session, so the session lives in `bridge.py`, which speaks the CLI's
stream-json protocol in both directions and re-exposes it over loopback HTTP:
`GET /events` is an SSE stream, `POST /send` and `POST /control` go the other
way. That is the entire reason the sidecar exists.

The bridge translates the raw protocol into render-ready transcript items, so
the panel does no parsing: it takes a snapshot on open and follows deltas after
that. Reopening the panel mid-turn shows the run already in progress, and
closing it does not stop anything — the run keeps going and notifies you when it
lands.

Rendering is coalesced onto the frame tick. Text deltas arrive about twelve
times a second; the panel marks itself dirty and draws once per frame, and stops
requesting frames entirely when nothing is streaming.

## Security notes

- The bridge binds **127.0.0.1 on an ephemeral port** and requires a random
  per-launch token, kept with the port in a `0600` file under
  `$XDG_RUNTIME_DIR/noctalia-claude-code/`.
- Nothing you type reaches a shell. The sidecar is launched with an argv table
  (no `/bin/sh -c`), and your prompts travel as an HTTP body, never as a command
  line.
- The plugin never reads, stores, or forwards your Anthropic credentials to
  anything but `api.anthropic.com`. The usage poll sends the CLI's own OAuth
  token to Anthropic and nowhere else, and never refreshes or rewrites it —
  rotating that token would break the CLI's own session, so an expired one is
  reported as "re-authenticate" instead.
- Claude Code in bypass mode has your shell and your files. Scope the working
  directory to a project and leave the permission mode alone unless you mean it.

## Troubleshooting

**"python3 was not found"** — install it; the bridge needs no packages beyond
the standard library.

**"The claude CLI was not found"** — install Claude Code, or put an absolute
path in the binary setting.

**Nothing streams / the panel says Not running** — run `claude` once in a
terminal and make sure it is authenticated. The bridge logs to the shell's
stderr prefixed `[claude-code-bridge]`.

**A turn is stuck** — `Ctrl+C` interrupts without killing the session. `/new`
starts over.

## License

MIT.
