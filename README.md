# Taskwarrior

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin backed by [Taskwarrior](https://taskwarrior.org). Click the bar glyph to toggle a panel that lists your **pending** tasks. A capture box sits at the top: type a task, press Enter, and it lands in Taskwarrior while the box clears and keeps focus. New tasks are tagged `inbox` by default. Rows show description, project, tags, and due date. You can complete, edit descriptions, filter, or delete tasks through the `task` CLI. The bar glyph's tooltip shows the pending count and refreshes every two seconds.

It never writes task files itself: every read and write goes through `task`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lpzchr/taskwarrior` |
| Plugin API | 24 |
| Entries | Bar widget: `todo`, panel: `panel` |

## Usage

Add the `todo` widget from Noctalia's widget picker and click it to open the task panel. You can also open the panel directly or bind it in your compositor:

```sh
noctalia msg panel-toggle lpzchr/taskwarrior:panel
```

| Action | Effect |
| --- | --- |
| Left click (bar glyph) | Open/close the Taskwarrior panel |
| Type + **Enter** (capture box) | Add the task (`task add`), then clear the box and keep focus |
| Click the text, or ✎ (hover) | Edit the task's description |
| ☐ button (row) | Complete the task (`task <uuid> done`; it leaves the pending list) |
| 🗑 button (hover) | First click arms, second click permanently deletes (`task <uuid> delete`) |
| **Undo** (panel header) | Revert the most recent complete or delete (`task undo`); visible for a few seconds |
| Filter chips (panel top) | Apply a saved Taskwarrior filter, configured in the plugin settings |
| 🔍 button (panel top) | Reveal a filter box that accepts any Taskwarrior filter expression |
| ⚙ button (panel header) | Open this plugin's page in *Settings → Plugins* |

That settings page also opens from the command line:

```sh
noctalia msg settings-open-plugin lpzchr/taskwarrior
```

## Behaviour

- **Taskwarrior syntax in the capture box.** `fix the sink +home project:house.kitchen due:fri` sets the tag, project, and due date, exactly as the CLI would. Chips under the box show the recognised attribute tokens before you commit. Everything else becomes the description verbatim.

- **Pending only, waiting excluded.** The panel and bar read `task status:pending -WAITING export`. A task you defer with `wait:` disappears from the panel and the bar count until its wait expires.

- **Sorted by urgency by default.** Taskwarrior's computed urgency score decides the order. The settings offer newest-first, oldest-first, and alphabetical instead. Priority is never displayed: the plugin does not read, set, or colour it.

- **Refresh policy.** The bar poll updates the pending count every two seconds. The panel refreshes after each in-panel write, on open, and when a plugin setting changes. Changes made in a terminal while the panel is open appear on the next write or reopen.

- **Commit-on-submit editing.** Inline edits only reach Taskwarrior when you press **Enter**. Closing the panel discards an uncommitted edit.

- **Serialized writes.** All panel `task` processes run one at a time through a FIFO. Rapid clicks cannot cause writes to race. After writes drain, one `task export` refreshes the list. A failed command shows an error notification and the refresh restores the real state.

- **No shell quoting hazards.** Commands run as argv vectors (`runAsync`'s array form), with `--` before description text. `project:looks-like-attr` typed mid-sentence stays part of the description. Text such as `$(rm -rf)` or `'; rm -rf'` is never interpreted by a shell.

## Settings

| Setting | What it does |
| --- | --- |
| Default tags | Tags added to a captured task when the typed line names none itself. Comma separated; default `inbox`. |
| Saved filters | Filter chips shown above the list, comma separated Taskwarrior filter expressions. |
| Sort tasks by | Urgency (default), newest first, oldest first, or description A–Z. |
| Task binary | Command or absolute path of the `task` CLI. Defaults to `task` on `PATH`. |
| Task rc file | Alternate Taskwarrior rc file, passed as `task rc:<path>`. Empty uses `~/.taskrc` (or `$XDG_CONFIG_HOME/task/taskrc`). |
| Task data directory | Data directory passed as `rc.data.location=<dir>`. Empty uses the rc file's `data.location`. Together with **Task rc file** this lets the plugin use an isolated Taskwarrior instance/directory. |
| Bar glyph | The glyph shown for the widget on the bar. |

## Install

Local development: add this checkout as a path source, then enable the plugin. The `.luau` files hot-reload, and manifest changes need a plugin disable/enable cycle.

```sh
noctalia msg plugins source add dev path /path/to/noctalia-plugin-taskwarrior
noctalia msg plugins enable lpzchr/taskwarrior
```

Alternatively copy the `taskwarrior/` directory into `~/.local/share/noctalia/plugins/`.

## Requirements

- noctalia v5 build supporting plugin API 24. See [Plugin API Versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/)

- Taskwarrior 3.x on `PATH` (or set the **Task binary** setting), with a working `task export`. Undo needs Taskwarrior 2.4 or newer.

## Development

```
taskwarrior/
  plugin.toml         # manifest: id, settings, panel + widget entries
  todo.luau           # bar widget (2s pending-count poll)
  panel.luau          # panel UI + serial task queue
  taskwarrior.luau    # shared client: export/parse + argv builders
  translations/en.json
  README.md
  thumbnail.webp
```

`noctalia.d.luau` at the repo root (gitignored) is the type definition file for the editor, fetched from `noctalia-dev/official-plugins`. `.luaurc` sets nonstrict mode for luau-lsp.

## License

MIT.

## References

`nightwatch75/todo`.
