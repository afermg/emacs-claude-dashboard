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
  :straight (:host github :repo "amunozgo/emacs_llm_dashboard"
             :files ("claude-dashboard.el"))
  :commands (claude-dashboard claude-dashboard-new))
```

Or load manually:

```elisp
(add-to-list 'load-path "/path/to/emacs_llm_dashboard")
(require 'claude-dashboard)
```

## Use

`M-x claude-dashboard` opens the dashboard buffer.

| Key   | Action                                 |
| ----- | -------------------------------------- |
| `n`   | new Claude instance (prompts for cwd)  |
| `RET` / `o` | pop to instance buffer            |
| `O`   | display instance buffer in other window |
| `d`   | dired in instance cwd                  |
| `m`   | magit-status on instance cwd           |
| `k`   | quit Claude gracefully (SIGINT)        |
| `K`   | kill the eat buffer outright           |
| `r`   | restart Claude in same buffer/cwd      |
| `g`   | refresh                                |
| `?`   | transient menu                         |
| `TAB` | fold/unfold a section                  |

Project root selection on `n` offers `project-known-project-roots` first,
then directories from `recentf-list`, then a free-form `read-directory-name`.

## Behavior notes

- Status glyphs: ● running, ◐ idle (>60s no terminal output), ○ exited.
- The eat buffer is kept alive after Claude exits so you can scroll back
  and `r` to restart. `K` removes it.
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
