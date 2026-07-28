# llm-dashboard.el

A magit-style Emacs buffer for managing TUI agent instances you launch
from Emacs — Pi by default, with opt-in support for Claude Code,
[opencode](https://opencode.ai/), and Codex.
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
(use-package llm-dashboard
  :straight (:host github :repo "afermg/emacs-claude-dashboard"
             :files ("llm-dashboard.el"))
  :commands (llm-dashboard llm-dashboard-new
             llm-dashboard-continue llm-dashboard-resume))
```

With `package-vc-install` (Emacs 29+, no straight.el needed):

```elisp
(unless (package-installed-p 'llm-dashboard)
  (package-vc-install
   '(llm-dashboard
     :url "https://github.com/afermg/emacs-claude-dashboard")))
(require 'llm-dashboard)
```

Or load manually:

```elisp
(add-to-list 'load-path "/path/to/emacs-claude-dashboard")
(require 'llm-dashboard)
```

The package was renamed from `claude-dashboard` to `llm-dashboard` in
this release. Transitional aliases at the bottom of `llm-dashboard.el`
keep `(require 'claude-dashboard)`, `(use-package claude-dashboard ...)`,
`M-x claude-dashboard`, and the `claude-dashboard-*` defcustoms working
for one cycle so existing init files don't break.

## Use

`M-x llm-dashboard` opens the dashboard. With the default settings it
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
| `i`   | send the backend's in-band interrupt key to the row     |
| `m` / `u`         | mark / unmark current row                  |
| `t` / `U`         | toggle all marks / unmark all              |
| `D`   | quit (graceful) marked, or current — also kills its buffer |
| `x`   | kill eat buffer for marked, or current                 |
| `k` / `K` | quit (also kills buffer) / kill buffer outright    |
| `N`   | new agent instance (prompts for cwd)                   |
| `b`   | new git worktree + branch + agent (backend-specific worktree layout) |
| `c`   | continue the most recent session in chosen cwd         |
| `R`   | resume picker (all past sessions, sorted newest-first); on a row, defaults to that cwd |
| `g`   | refresh                                                |
| `?`   | transient menu                                         |

In a managed terminal buffer, `C-c C-i` sends the backend's in-band interrupt
key to the current agent.

`M-x llm-dashboard-interrupt-instance` also works directly from a managed
terminal buffer, not just from the dashboard.

To add your own terminal-buffer bindings, customize
`llm-dashboard-managed-terminal-mode-map`, for example:

```elisp
(with-eval-after-load 'llm-dashboard
  (define-key llm-dashboard-managed-terminal-mode-map
              (kbd "M-<up>") #'my-command))
```

`r` (restart) is **not** bound by default — restart spawns a fresh agent
without a session resume, dropping the conversation, and a single-letter
binding makes that footgun too easy. Reachable via
`M-x llm-dashboard-restart`.

Project root selection offers `project-known-project-roots` first, then
directories from `recentf-list`, then a free-form `read-directory-name`.

## Backends

The dashboard multiplexes over backend CLIs that share the same shape
(a TUI agent, a per-user state directory, a `--resume` / `--continue`
convention). Three are wired up out of the box:

| Backend    | Program    | State dir                  | Transcripts | Status                                       |
| ---------- | ---------- | -------------------------- | ----------- | -------------------------------------------- |
| `pi`       | `pi`       | `~/.pi/agent`              | Session JSONL | Full support; default — session discovery, topic, activity, and `/name` via split-write. |
| `claude`   | `claude`   | `~/.claude`                | JSONL         | Full support; includes kind classifier. |
| `opencode` | `opencode` | `~/.local/share/opencode`  | SQLite        | Full support — sessions, topic, activity, exchange body via the built-in SQLite reader. No `/rename` (opencode lacks the slash command). Requires Emacs built with `--with-sqlite3` (Emacs 30 default). |
| `codex`    | `codex`    | `~/.codex`                 | Rollout JSONL | Full support — session discovery, topic, activity, and `/rename` via split-write. Topic falls back to the worktree slug since codex has no live name file. |

Switch with a single defcustom:

```elisp
;; Default — Pi
(setq llm-dashboard-backend 'pi)

;; Or switch to another backend
(setq llm-dashboard-backend 'claude)
(setq llm-dashboard-backend 'opencode)
(setq llm-dashboard-backend 'codex)
```

`llm-dashboard-backend` only controls the **default** for new
sessions. Each instance captures its backend symbol at launch time
into a `:backend` struct slot and persists it in the manifest, so a
single dashboard can mix pi / claude / opencode / codex rows side by side —
every row dispatches its own session-id, topic, activity, and rename
through the adapter it was launched against.

Each row's TOPIC column gets a one-glyph colored badge — `P` for
pi, `C` for claude, `O` for opencode, `X` for codex — so multi-backend dashboards
are visually distinguishable without an extra column.

The `llm-dashboard-program`, `llm-dashboard-claude-dir`,
`llm-dashboard-spinner-regexp`, and `llm-dashboard-manifest-file`
defcustoms still work — when set, they override the backend defaults,
which is useful for pinning an absolute path or sharing a manifest
across backends. Leave them at their nil / `auto` defaults to let the
active backend supply the value.

### Adding a new backend

Append an entry to `llm-dashboard-backends`. The static keys are
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
| `:interrupt-fn`       | `(proc) → bool`          | Inject the backend's in-band abort key; `nil` means unsupported. |

See the `llm-dashboard-backends` docstring for the complete shape
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
  `llm-dashboard-side` (default `bottom`), with `window-height = fit-window-to-buffer`.
  It re-sizes on every refresh as instances appear and disappear.
- Each row carries the latest activity (first sentence of Claude's most
  recent assistant text, or a `<Tool> <hint>` summary when the latest
  content item is a tool_use) and the conversation's TOPIC (the live
  backend name when available, then the transcript's recorded name,
  then a worktree or prompt-derived slug, with `—` as the last
  resort).
- `TAB` on a row reveals recent user queries (`❯ …`); each assistant
  response is a level deeper. Magit's `1`/`2`/`3` (or
  `M-1`/`M-2`/`M-3` for the whole buffer) cycle through the depth. The
  dashboard renders only the most recent 20 exchanges by default so
  refresh cost stays bounded; the backend transcript remains complete.

### Refresh + caching

- A 5-second timer re-renders the dashboard whenever it's visible.
- Terminal launches and buffer-selection hooks queue one coalesced redraw
  after the current command, so switching buffers is not blocked by render work.
- Expensive lookups (branch name, project name, topic) are cached for
  30 s per instance.
- Active Pi transcripts are parsed incrementally. Once a JSONL file has been
  seen, refreshes read only bytes appended since the previous pass instead of
  reparsing the full conversation.

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
a fresh launch.  Use `M-x llm-dashboard-resume-all` to relaunch
every session recorded in the manifest.

## Potential issues

### Repeated `llm-dashboard--on-window-size-change` errors on Emacs 30+

If `*Messages*` contains entries like:

```text
Error muted by safe_call: (llm-dashboard--on-window-size-change #<window ... on *LLM Dashboard*>) signaled (error "Window is on a different frame")
```

then a buffer-local `window-size-change-functions` callback is being
called with a **window**, not a frame.  Emacs calls default/global entries
in that hook with a frame argument, but buffer-local entries with the
changed window.  A handler that assumes it always receives a frame can
spam errors during frame resizes, focus changes, or dashboard refreshes;
with `debug-on-error` enabled this can drop Emacs into the debugger and
make a client frame feel stuck.

The fix is for the callback to accept both a frame and a window, processing
`(list window)` for the buffer-local case and `(window-list frame ...)` for
the global case.  As a temporary workaround, remove the buffer-local hook
from the dashboard buffer:

```elisp
(with-current-buffer "*LLM Dashboard*"
  (remove-hook 'window-size-change-functions
               #'llm-dashboard--on-window-size-change t))
```

## Customization

```elisp
;; Backend selection (default `pi'; `claude', `opencode', and `codex' also supported)
(setq llm-dashboard-backend 'pi)

;; Process / launch — leave program/state-dir nil to inherit from backend
(setq llm-dashboard-program nil                   ;; or "claude" / abs path
      llm-dashboard-program-args nil              ;; extra CLI args
      llm-dashboard-claude-dir nil)               ;; nil = backend default

;; Layout
(setq llm-dashboard-fit-window t                  ;; nil = use default
      llm-dashboard-fit-min-height 4
      llm-dashboard-side 'bottom)                 ;; 'top or 'bottom

;; Refresh + classifier (nil spinner-regexp = backend default)
(setq llm-dashboard-refresh-interval 5
      llm-dashboard-cache-ttl 30
      llm-dashboard-overview-max-exchanges 20     ;; nil = full history
      llm-dashboard-tail-chars 2000
      llm-dashboard-spinner-regexp nil)

;; Auto-naming
(setq llm-dashboard-auto-name-after-turns 5)      ;; nil disables

;; Custom keys in managed terminal buffers launched by llm-dashboard
(with-eval-after-load 'llm-dashboard
  (define-key llm-dashboard-managed-terminal-mode-map
              (kbd "M-<up>") #'my-command))
```
