# claude-dashboard.el

A magit-style Emacs buffer for managing the Claude Code instances you launch
from Emacs. Each instance runs in its own [eat](https://codeberg.org/akib/emacs-eat)
terminal buffer rooted at a project directory; the dashboard lists them with
status, uptime, idle time, branch, model, and last user prompt, and exposes
keys to jump in, restart, or kill.

It only tracks instances **launched through it** — Claude processes started
elsewhere (in a regular terminal, in another Emacs) do not appear.

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
| `s`   | open the instance's STATUS.md          |
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

- Status glyphs: ● running, ◐ idle (>60s no terminal output), ○ exited.
- Each eat buffer is named `*claude-<project>-<sid8>*`. The session id
  isn't known until Claude has written its session metadata (~2s after
  launch), so the buffer is initially named `*claude-<project>-pending*`
  and renamed once enrichment completes.
- The eat buffer is kept alive after Claude exits so you can scroll back
  and `r` to restart. `K` removes it.
- A `STATUS.md` file is created in each instance's cwd on launch (with a
  starter template). The dashboard's `STATUS` column shows how long ago
  it was last modified. Press `s` to visit. Claude **does not** write to
  this file automatically — to make it useful, ask Claude in your first
  prompt to keep `STATUS.md` updated, e.g. _"Update STATUS.md after each
  significant step with what you did and what's next."_  Disable entirely
  by `(setq claude-dashboard-status-file nil)`.
- `~/.claude/sessions/<pid>.json` is read ~2s after launch to fill in the
  session id. The model is read from the latest JSONL in
  `~/.claude/projects/<encoded-cwd>/` once Claude has produced an assistant
  turn — refresh with `g` if it shows `—`.
- Last user prompt comes from the tail of `~/.claude/history.jsonl`,
  matched against the instance's cwd. Cached for 30s.
- A 5-second timer re-renders the dashboard whenever it's visible.

## Customization

```elisp
(setq claude-dashboard-program "claude"             ;; or absolute path
      claude-dashboard-program-args nil             ;; extra CLI args
      claude-dashboard-idle-threshold 60            ;; seconds → ◐
      claude-dashboard-refresh-interval 5
      claude-dashboard-cache-ttl 30)
```
