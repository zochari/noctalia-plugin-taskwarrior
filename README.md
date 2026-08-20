# Taskwarrior

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin backed by [Taskwarrior](https://taskwarrior.org). Click the bar glyph to toggle a panel that lists your **pending** tasks. You can add tasks, edit descriptions, cycle priority (H → M → L → none), complete, or delete them through the `task` CLI. The bar glyph's tooltip shows the pending count and refreshes every two seconds.

It never writes task files itself: every read and write goes through `task`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lpzchr/taskwarrior` |
| Plugin API | 22 (relative `require()`, compatible with Noctalia 5.0.0-beta.8+, which supports API ≤ 23) |
| Entries | Bar widget: `todo`, panel: `panel` |

## Usage

Add the `todo` widget from Noctalia's widget picker and click it to open the task panel. You can also open the panel directly or bind it in your compositor:

```sh
noctalia msg panel-toggle lpzchr/taskwarrior:panel
```

| Action | Effect |
| --- | --- |
| Left click (bar glyph) | Open/close the Taskwarrior panel |
| **+** (panel header) | Start typing a new task |
| **Enter**, or ✓ | Commit the edit: `task add` / `task <uuid> modify` |
| Click the text, or ✎ (pencil) | Edit the task's description |
| Colour chip (row) | Cycle priority: H → M → L → none → H |
| ☐ button (row) | Complete the task (`task <uuid> done`, pending-only view, so it leaves the list) |
| 🗑 button (row) | Permanently delete the task (`task <uuid> delete`, non-interactive) |
| ⚙ button (panel header) | Open this plugin's page in *Settings → Plugins* |

That settings page also opens from the command line:

```sh
noctalia msg settings-open-plugin lpzchr/taskwarrior
```

## Behaviour

- **Pending only.** The panel and bar read `task status:pending export`. Completed and deleted tasks stay in Taskwarrior's history but never appear in the panel.

- **Refresh policy.** The bar poll updates the pending count every two seconds. The panel refreshes after each in-panel write and on open. Changes made in a terminal while the panel is open appear on the next write or reopen.

- **No manual ordering.** Taskwarrior has no user-defined task order. The panel always sorts by priority (H → M → L → none), then description, then UUID. The todo plugin's manual drag-reorder mode is intentionally dropped.

- **Commit-on-submit editing.** Inline edits only reach Taskwarrior when you press **Enter** or ✓. Closing the panel discards an uncommitted edit.

- **Serialized writes.** All panel `task` processes run one at a time through a FIFO. Rapid clicks cannot cause writes to race. After writes drain, one `task export` refreshes the list. A failed command shows an error notification and the refresh restores the real state.

- **Descriptions are literal.** The plugin builds commands as argv vectors and POSIX single-quotes each element. It passes them to `runAsync`'s string form, placing `--` before descriptions. Text such as `project:looks-like-attr`, `-leading dash`, `$(rm -rf)` or `'; rm -rf'` is never interpreted by the shell or Taskwarrior.

## Settings

| Setting | What it does |
| --- | --- |
| Task binary | Command or absolute path of the `task` CLI. Defaults to `task` on `PATH`. |
| Task rc file | Alternate Taskwarrior rc file, passed as `task rc:<path>`. Empty uses `~/.taskrc` (or `$XDG_CONFIG_HOME/task/taskrc`). |
| Task data directory | Data directory passed as `rc.data.location=<dir>`. Empty uses the rc file's `data.location`. Together with **Task rc file** this lets the plugin use an isolated Taskwarrior instance/directory. |
| Bar glyph | The glyph shown for the widget on the bar. |

## Install

Local development: add this checkout as a path source, then enable the plugin. The `.luau` files hot-reload, and manifest changes need a config reload.

```sh
noctalia msg plugins source add dev path /path/to/noctalia-plugin-taskwarrior
noctalia msg plugins enable lpzchr/taskwarrior
```

Alternatively copy the `taskwarrior/` directory into `~/.local/share/noctalia/plugins/`.

## Requirements

- noctalia v5 build supporting plugin API 22 (5.0.0-beta.8 or newer). See [Plugin API Versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/)

- Taskwarrior on `PATH` (or set the **Task binary** setting), with a working `task status:pending export`

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
