# claude-dashboard.el

A magit-style Emacs buffer for managing the Claude Code instances you launch
from Emacs. Each instance runs in its own [eat](https://codeberg.org/akib/emacs-eat)
terminal buffer rooted at a project directory; the dashboard lists them with
status, uptime, idle time, branch, model, and last user prompt, and exposes
keys to jump in, restart, or kill.

It only tracks instances **launched through it** — Claude processes started
elsewhere (in a regular terminal, in another Emacs) do not appear.

Per-row info: project tag, state (RUN/MON/ASK/IDL/EXT), uptime, deploy
branch, session id, todos remaining and age, and conversation name.
TAB unfolds a row to show the agent's current TodoWrite snapshot.

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

`M-x claude-dashboard` opens the dashboard buffer.

Keybindings follow ibuffer's conventions: `n`/`p` move between rows,
`m`/`u`/`t`/`U` mark/unmark/toggle/unmark-all, `D` and `x` operate on
all marked rows (or the current row if no marks). Capitalised `N`
launches a new instance, freeing single-letter `n` for navigation.

| Key   | Action                                 |
| ----- | -------------------------------------- |
| `n` / `p` / `SPC` | next / previous instance row |
| `RET` / `o` | pop to instance buffer            |
| `O`   | display instance buffer in other window |
| `d`   | dired in instance cwd                  |
| `v`   | magit-status on instance cwd           |
| `m` / `u` | mark / unmark current row          |
| `t` / `U` | toggle all marks / unmark all      |
| `D`   | quit (graceful) marked, or current     |
| `x`   | kill eat buffer for marked, or current |
| `k` / `K` / `r` | quit / kill buffer / restart current row |
| `N`   | new Claude instance (prompts for cwd)  |
| `c`   | `claude --continue` in chosen cwd      |
| `R`   | resume picker (all past sessions); on a row, defaults to that cwd |
| `g`   | refresh                                |
| `?`   | transient menu                         |
| `TAB` | fold/unfold a section                  |

Project root selection on `n` offers `project-known-project-roots` first,
then directories from `recentf-list`, then a free-form `read-directory-name`.

## Behavior notes

- Status glyphs: ● running (active spinner), ↻ monitoring (long bash /
  sleeping), ? awaiting (menu of options visible), ◐ idle, ○ exited.
- Each eat buffer is named `*claude-<project>-<sid8>*`. The session id
  isn't known until Claude has written its session metadata (~2s after
  launch), so the buffer is initially named `*claude-<project>-pending*`
  and renamed once enrichment completes.
- The eat buffer is kept alive after Claude exits so you can scroll back
  and `r` to restart. `K` removes it.
- The `TODO` column shows `<remaining> <age>` for the agent's latest
  `TodoWrite` snapshot — number of pending+in-progress items and the
  age of the most recent update. `TAB` on a row unfolds the full todo
  list as the per-instance overview. No file is written; everything is
  read from the per-session transcript at
  `~/.claude/projects/<slug>/<sid>.jsonl`.
- The session name shown in `TOPIC` is taken first from the live
  `~/.claude/sessions/<PID>.json` `name` field (updated on every
  `/rename`), then transcript `customTitle` events, then the worktree
  branch (if launched via `b`), then the first user prompt, then
  Claude's auto-assigned slug.
- A 5-second timer re-renders the dashboard whenever it's visible;
  expensive lookups (branch, project name, topic) are cached for 30 s.

## Customization

```elisp
(setq claude-dashboard-program "claude"             ;; or absolute path
      claude-dashboard-program-args nil             ;; extra CLI args
      claude-dashboard-idle-threshold 60            ;; seconds → ◐
      claude-dashboard-refresh-interval 5
      claude-dashboard-cache-ttl 30)
```

