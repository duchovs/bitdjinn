# Notes (local fork)

Quick markdown notes in a full-height side panel, stored as plain text files in
a directory you control - yours to sync, edit externally, and grep. Local fork
of [`noctalia/notes`](https://github.com/noctalia-dev/official-plugins/tree/main/notes)
that adds a rendered markdown preview, Obsidian-style: a note with content
opens showing rendered markdown, and clicking it drops you into raw editing.

## Plugin

| Field | Value |
| --- | --- |
| ID | `duchovs/notes` |
| Entries | Panel: `panel`; bar widget: `notes`; launcher provider: `launcher` |
| Launcher Prefix | `/nt` |

## Usage

1. Enable the plugin in Settings → Plugins.
2. Add the `notes` bar widget and click it, or run:

   ```sh
   noctalia msg panel-toggle duchovs/notes:panel
   ```

3. **+** creates a note named after the current time; rename it from the editor
   header (press Enter to apply). The editor autosaves a couple of seconds
   after you stop typing, when you navigate away, and when the panel closes;
   Ctrl+Enter saves immediately.
4. A note with content opens as a rendered markdown preview; click anywhere in
   it, or the eye button in the editor header, to switch to the raw editor. A
   blank note (new, or an empty scratchpad) opens straight into editing, since
   there's nothing yet to render. The eye button also flips back to preview.
   Click-to-edit is whole-note, not per-line - it doesn't place your cursor at
   the spot you clicked.
5. The pin button on a row keeps that note at the top of the list and ranks it
   higher in launcher results. Deleting asks for an inline confirmation.

A pinned **Scratchpad** note always sits at the top of the list - the place to
dump text instantly without naming anything.

The `/nt` launcher command writes down a thought without opening the panel:
type it, press Enter, done.

- `/nt buy milk` → **Add to scratchpad** appends the line to the scratchpad
  file; **New note** creates a note from it and opens the panel on it.
- The text also fuzzy-matches existing note names; activating a match opens it
  in the panel.
- Bare `/nt` lists the scratchpad, your notes, and **New note from clipboard**.
- **Add to scratchpad** is safe even if the scratchpad was left open in the
  editor: the appended line shows up there instead of being lost.

## IPC

```sh
noctalia msg panel-toggle duchovs/notes:panel   # toggle the panel
noctalia msg panel-open duchovs/notes:panel     # open it
noctalia msg panel-close                        # close the open panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notes_dir` | `folder` | `~/Documents/Notes` | Where the note files live. Created on first open if missing. |
| `extension` | `string` | `md` | Extension for note files (without the dot). Only files with this extension are listed. |
| `glyph` | `glyph` | `notes` | Bar widget icon. |

## Notes

- Pins are stored in a hidden `.pinned.json` sidecar inside the notes
  directory, so they sync with the notes.
- The panel remembers which note was open across close/reopen.
- Files are only written by autosave and the `/nt` actions; nothing else in
  the notes directory is touched.
