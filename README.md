# claude-dashboard.el

A magit-style Emacs buffer for managing the Claude Code instances you launch
from Emacs. Each instance runs in its own [eat](https://codeberg.org/akib/emacs-eat)
terminal buffer rooted at a project directory; the dashboard docks at the
bottom of the frame and shows them as a single line each — project tag,
state, uptime, deploy branch, session id, latest activity, and the
conversation's name.

The dashboard tracks only instances **launched through it**.  Each
`claude` runs as a direct Emacs subprocess (no multiplexer wrapping)
and dies when Emacs exits.

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

## Behavior notes

### Status

Three states only — earlier `awaiting` / `monitoring` heuristics misfired
too often and were removed:

- **● `RUN`** — Claude Code's progress spinner (`esc to interrupt`) is
  visible in the eat buffer tail; the agent is producing output or
  running a tool.
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

`claude` runs as a direct Emacs subprocess inside an `eat`-allocated
PTY.  When Emacs exits, the PTY closes and `claude` exits too —
there is no terminal-multiplexer integration.  Earlier branches
experimented with both GNU `screen` and `dtach`; neither survived
enough of the visual artifacts and per-keystroke latency they
introduced into eat to be worth the survival benefit.  If you need
to pick a conversation back up after restart, the per-session
transcripts live at `~/.claude/projects/<slug>/<sid>.jsonl` and
`claude --resume <sid>` works on a fresh launch.

## Customization

```elisp
;; Process / launch
(setq claude-dashboard-program "claude"             ;; or absolute path
      claude-dashboard-program-args nil)            ;; extra CLI args

;; Layout
(setq claude-dashboard-fit-window t                 ;; nil = use default
      claude-dashboard-fit-min-height 4
      claude-dashboard-side 'bottom)                ;; 'top or 'bottom

;; Refresh + classifier
(setq claude-dashboard-refresh-interval 5
      claude-dashboard-cache-ttl 30
      claude-dashboard-tail-chars 2000
      claude-dashboard-spinner-regexp "esc to interrupt")

;; Auto-naming
(setq claude-dashboard-auto-name-after-turns 5)     ;; nil disables
```
