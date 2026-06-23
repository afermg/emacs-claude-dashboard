# claude-dashboard.el

A magit-style Emacs buffer for managing TUI agent instances you launch
from Emacs — Claude Code by default, with opt-in support for [opencode](https://opencode.ai/).
Each instance runs in its own [eat](https://codeberg.org/akib/emacs-eat)
terminal buffer rooted at a project directory; the dashboard docks at the
bottom of the frame and shows them as a single line each — project tag,
state, uptime, deploy branch, session id, latest activity, and the
conversation's name.

The dashboard tracks only instances **launched through it**.  Each
backend process runs as a direct Emacs subprocess (no multiplexer
wrapping) and dies when Emacs exits.

## Install

Requires Emacs 29.1+, [magit-section](https://elpa.nongnu.org/nongnu/magit-section.html),
[transient](https://elpa.gnu.org/packages/transient.html), and
[eat](https://codeberg.org/akib/emacs-eat). With straight.el:

```elisp
(use-package claude-dashboard
  :straight (:host github :repo "afermg/emacs-claude-dashboard"
             :files ("claude-dashboard.el"))
  :commands (claude-dashboard claude-dashboard-new
             claude-dashboard-continue claude-dashboard-resume))
```

With `package-vc-install` (Emacs 29+, no straight.el needed):

```elisp
(unless (package-installed-p 'claude-dashboard)
  (package-vc-install
   '(claude-dashboard
     :url "https://github.com/afermg/emacs-claude-dashboard")))
(require 'claude-dashboard)
```

Or load manually:

```elisp
(add-to-list 'load-path "/path/to/emacs-claude-dashboard")
(require 'claude-dashboard)
```

## Use

`M-x claude-dashboard` opens the dashboard. With the default settings it
docks as a side window at the bottom of the frame, sized exactly to the
number of instance rows (heading + column header + one line per agent).

Keybindings follow ibuffer's conventions: `n`/`p` move between rows,
`m`/`u`/`t`/`U` mark/unmark/toggle/unmark-all, `D` and `x` operate on
all marked rows (or the current row if no marks). Capitalised `N`
launches a new instance, freeing single-letter `n` for navigation.

| Key   | Action                                                 |
| ----- | ------------------------------------------------------ |
| `n` / `p` / `SPC` | next / previous instance row              |
| `RET` / `o` | pop to instance buffer                          |
| `O`   | display instance buffer in other window                |
| `TAB` | fold/unfold a row's body (last user query + response)  |
| `1` / `2` / `3` | depth-N expand at point (per-row queries / responses) |
| `M-1` / `M-2` / `M-3` | same applied to the whole buffer         |
| `d`   | dired in instance cwd                                  |
| `v`   | magit-status on instance cwd                           |
| `w`   | copy the row's TOPIC to the kill ring                  |
| `f`   | copy the row's cwd to the kill ring                    |
| `T`   | interactive `/name <slug>` for the agent at point      |
| `m` / `u`         | mark / unmark current row                  |
| `t` / `U`         | toggle all marks / unmark all              |
| `D`   | quit (graceful) marked, or current — also kills its buffer |
| `x`   | kill eat buffer for marked, or current                 |
| `k` / `K` | quit (also kills buffer) / kill buffer outright    |
| `N`   | new Claude instance (prompts for cwd)                  |
| `b`   | new git worktree + branch + agent (Claude Code's `.claude/worktrees/<branch>` layout) |
| `c`   | `claude --continue` in chosen cwd                      |
| `R`   | resume picker (all past sessions, sorted newest-first); on a row, defaults to that cwd |
| `g`   | refresh                                                |
| `?`   | transient menu                                         |

`r` (restart) is **not** bound by default — restart spawns a fresh `claude`
without `--resume`, dropping the conversation, and a single-letter binding
makes that footgun too easy. Reachable via `M-x claude-dashboard-restart`.

Project root selection offers `project-known-project-roots` first, then
directories from `recentf-list`, then a free-form `read-directory-name`.

## Backends

The dashboard multiplexes over backend CLIs that share the same shape
(a TUI agent, a per-user state directory, a `--resume` / `--continue`
convention). Three are wired up out of the box:

| Backend    | Program    | State dir                  | Transcripts | Status                                       |
| ---------- | ---------- | -------------------------- | ----------- | -------------------------------------------- |
| `claude`   | `claude`   | `~/.claude`                | JSONL       | Full support; default; includes kind classifier. |
| `opencode` | `opencode` | `~/.local/share/opencode`  | SQLite      | Full support — sessions, topic, activity, exchange body via the built-in SQLite reader. No `/rename` (opencode lacks the slash command). Requires Emacs built with `--with-sqlite3` (Emacs 30 default). |
| `codex`    | `codex`    | `~/.codex`                 | Rollout JSONL | Full support — session discovery, topic, activity, and `/rename` via split-write. Topic falls back to the worktree slug since codex has no live name file. |

Switch with a single defcustom:

```elisp
;; Default — Claude Code
(setq claude-dashboard-backend 'claude)

;; Or opt in
(setq claude-dashboard-backend 'opencode)
(setq claude-dashboard-backend 'codex)
```

`claude-dashboard-backend` only controls the **default** for new
sessions. Each instance captures its backend symbol at launch time
into a `:backend` struct slot and persists it in the manifest, so a
single dashboard can mix claude / opencode / codex rows side by side —
every row dispatches its own session-id, topic, activity, and rename
through the adapter it was launched against.

Each row's TOPIC column gets a one-glyph colored badge — `C` for
claude, `O` for opencode, `X` for codex — so multi-backend dashboards
are visually distinguishable without an extra column.

The `claude-dashboard-program`, `claude-dashboard-claude-dir`,
`claude-dashboard-spinner-regexp`, and `claude-dashboard-manifest-file`
defcustoms still work — when set, they override the backend defaults,
which is useful for pinning an absolute path or sharing a manifest
across backends. Leave them at their nil / `auto` defaults to let the
active backend supply the value.

### Adding a new backend

Append an entry to `claude-dashboard-backends`. The static keys are
`:program`, `:state-dir`, `:spinner-regexp`, `:resume-flag`,
`:continue-flag`, `:worktree-subdir`, `:transcript-style`, `:badge`,
`:badge-color`, and `:supports-auto-name`.

The function-valued keys (each a symbol naming a defun, or `nil` to
opt out) drive the per-row column extractors:

| Slot                  | Signature                | Purpose                                            |
| --------------------- | ------------------------ | -------------------------------------------------- |
| `:session-id-fn`      | `(inst) → sid \| nil`    | Discover the live session-id for INST.             |
| `:session-name-fn`    | `(inst) → name \| nil`   | Live user-set name (post-`/rename`).               |
| `:transcript-path-fn` | `(cwd sid) → path \| nil`| Locate the transcript for a given session.         |
| `:transcript-walk-fn` | `(path) → list-of-msgs`  | Returns chronological normalized msgs: `((role . SYM) (text . STR) (ts . FLOAT) (raw . OBJ))`. Drives ACTIVITY, exchanges, first-prompt, turn-counts. |
| `:list-sessions-fn`   | `() → list-of-past`      | Resumable session enumeration for the picker.      |
| `:rename-fn`          | `(proc slug) → bool`     | Inject a rename command; `nil` means unsupported.  |

See the `claude-dashboard-backends` docstring for the complete shape
and the `--claude-*-fn` / `--opencode-*-fn` / `--codex-*-fn`
implementations for working examples.

## Behavior notes

### Status

Three states only — earlier `awaiting` / `monitoring` heuristics misfired
too often and were removed:

- **● `RUN`** — the active backend's progress spinner is visible in the
  eat buffer tail (`esc to interrupt` for Claude); the agent is
  producing output or running a tool.
- **◐ `IDL`** — process alive, no spinner.
- **○ `EXT`** — process gone.

### Layout

- The dashboard docks via `display-buffer-in-side-window` at
  `claude-dashboard-side` (default `bottom`), with `window-height = fit-window-to-buffer`.
  It re-sizes on every refresh as instances appear and disappear.
- Each row carries the latest activity (first sentence of Claude's most
  recent assistant text, or a `<Tool> <hint>` summary when the latest
  content item is a tool_use) and the conversation's TOPIC (the live
  `~/.claude/sessions/<PID>.json` `name` field, updated on every
  `/rename`, with a chain of fallbacks down to Claude's auto-assigned
  slug).
- `TAB` on a row reveals the last user query (`❯ …`) and the latest
  assistant response. The full per-query / per-response history is a
  level deeper — magit's `1`/`2`/`3` (or `M-1`/`M-2`/`M-3` for whole
  buffer) cycle through the depth.

### Refresh + caching

- A 5-second timer re-renders the dashboard whenever it's visible.
- Expensive lookups (branch name, project name, topic) are cached for
  30 s per instance.

### Process lifecycle

The backend process runs as a direct Emacs subprocess inside an
`eat`-allocated PTY.  When Emacs exits, the PTY closes and the agent
exits too — there is no terminal-multiplexer integration.  Earlier
branches experimented with both GNU `screen` and `dtach`; neither
survived enough of the visual artifacts and per-keystroke latency
they introduced into eat to be worth the survival benefit.  If you
need to pick a conversation back up after restart, the per-session
transcripts live at `<state-dir>/projects/<slug>/<sid>.jsonl` (for
Claude: `~/.claude/projects/…`) and `claude --resume <sid>` works on
a fresh launch.  Use `M-x claude-dashboard-resume-all` to relaunch
every session recorded in the manifest.

## Customization

```elisp
;; Backend selection (default `claude'; `opencode' also supported)
(setq claude-dashboard-backend 'claude)

;; Process / launch — leave program/state-dir nil to inherit from backend
(setq claude-dashboard-program nil                   ;; or "claude" / abs path
      claude-dashboard-program-args nil              ;; extra CLI args
      claude-dashboard-claude-dir nil)               ;; nil = backend default

;; Layout
(setq claude-dashboard-fit-window t                  ;; nil = use default
      claude-dashboard-fit-min-height 4
      claude-dashboard-side 'bottom)                 ;; 'top or 'bottom

;; Refresh + classifier (nil spinner-regexp = backend default)
(setq claude-dashboard-refresh-interval 5
      claude-dashboard-cache-ttl 30
      claude-dashboard-tail-chars 2000
      claude-dashboard-spinner-regexp nil)

;; Auto-naming
(setq claude-dashboard-auto-name-after-turns 5)      ;; nil disables
```
