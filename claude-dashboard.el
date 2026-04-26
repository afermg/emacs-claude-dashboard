;;; claude-dashboard.el --- Magit-style dashboard for Claude Code instances -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.5") (eat "0.9"))
;; Keywords: tools, processes
;; URL: https://github.com/afermg/emacs-claude-dashboard

;;; Commentary:

;; A single buffer that lists Claude Code instances launched from Emacs,
;; each running in its own eat terminal buffer rooted at a project
;; directory.  Press `n' to launch a new instance, RET to jump in, `k'
;; to exit it gracefully, `r' to restart, `g' to refresh, `?' for the
;; transient menu.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'transient)
(require 'project)
(require 'recentf)
(require 'eat)

(defgroup claude-dashboard nil
  "Dashboard for managing Claude Code instances."
  :group 'tools
  :prefix "claude-dashboard-")

(defcustom claude-dashboard-program "claude"
  "Executable used to launch a Claude Code instance."
  :type 'string)

(defcustom claude-dashboard-program-args nil
  "Extra arguments passed to `claude-dashboard-program' on launch."
  :type '(repeat string))

(defcustom claude-dashboard-buffer-name "*Claude Dashboard*"
  "Name of the dashboard buffer."
  :type 'string)

(defcustom claude-dashboard-idle-threshold 60
  "Seconds with no terminal output after which an instance is shown as idle."
  :type 'number)

(defcustom claude-dashboard-refresh-interval 5
  "Seconds between automatic refreshes when the dashboard is visible."
  :type 'number)

(defcustom claude-dashboard-cache-ttl 30
  "Seconds to cache git branch and last-prompt lookups per instance."
  :type 'number)

(defcustom claude-dashboard-claude-dir
  (expand-file-name "~/.claude")
  "Root of Claude Code's per-user state directory."
  :type 'directory)

(defcustom claude-dashboard-status-file "STATUS.md"
  "Path of the per-instance status file, relative to the instance cwd.
The file is created on launch with a starter template if missing.
Set to nil to disable the STATUS.md feature entirely."
  :type '(choice (const :tag "Disabled" nil) (string :tag "Relative path")))

(defcustom claude-dashboard-status-system-prompt
  "Maintain ./STATUS.md as a brief, current snapshot of this session: \
what you just did, what you're doing now, and what's next. Update it \
after every meaningful step (file edit, command, decision). Keep it \
short (≤ 30 lines)."
  "System-prompt fragment auto-appended to each launch.
Passed through `--append-system-prompt' so Claude keeps
`claude-dashboard-status-file' up to date.  Set to nil to disable
injection."
  :type '(choice (const :tag "Disabled" nil) (string :tag "Prompt fragment")))

;;; Data model

(cl-defstruct claude-dashboard-instance
  buffer cwd started-at last-output
  session-id model
  branch-cache worktree-cache main-worktree-cache last-prompt-cache
  project-name-cache)

(defvar claude-dashboard--instances (make-hash-table :test 'eq)
  "Map from eat buffer to `claude-dashboard-instance' struct.")

(defvar claude-dashboard--marks (make-hash-table :test 'eq)
  "Set of marked instance buffers (value t).")

(defvar claude-dashboard--deploy-branches (make-hash-table :test 'eq)
  "Map buffer → branch name captured at instance registration time.
This is the branch that was checked out in the instance's cwd at the
moment the agent was launched.  Frozen for the lifetime of the
instance, so the dashboard reports what the agent was deployed
against rather than what the worktree currently points at.")

(defvar claude-dashboard--refresh-timer nil
  "Idle timer rendering the dashboard when visible.")

;;; Helpers

(defun claude-dashboard--instances-list ()
  "Return all known instances, dropping entries whose buffer was killed."
  (let (result dead)
    (maphash (lambda (buf inst)
               (if (buffer-live-p buf)
                   (push inst result)
                 (push buf dead)))
             claude-dashboard--instances)
    (dolist (buf dead) (remhash buf claude-dashboard--instances))
    (nreverse result)))

(defun claude-dashboard--instance-process (inst)
  "Return the live process object of INST's eat buffer, or nil."
  (when (buffer-live-p (claude-dashboard-instance-buffer inst))
    (get-buffer-process (claude-dashboard-instance-buffer inst))))

(defcustom claude-dashboard-awaiting-regexp
  "❯ +\\(?:[0-9]+\\.\\|Yes\\b\\|No\\b\\)"
  "Regexp matched against the tail of the eat buffer.
Designed to match the cursor on a Claude Code menu of options
\(numbered options like \"❯ 1.\" or a Yes/No prompt arrow).  A match
means the user has options to choose from, not just that Claude is
quiet."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-awaiting-tail-chars 300
  "Number of trailing eat-buffer chars to scan for a pending menu.
A real Claude Code menu cursor + remaining option lines fits in a
few hundred chars, so once Claude streams any new output after the
menu the cursor falls out of this window and the row stops showing
the awaiting glyph."
  :type 'integer :group 'claude-dashboard)

(defun claude-dashboard--awaiting-input-p (inst)
  "Return non-nil when INST is presenting a menu of options to the user.
Looks only at the last `claude-dashboard-awaiting-tail-chars' of the
eat buffer.  Requires the menu-cursor regexp AND a sibling option
\(another numbered line or Yes/No token) appearing strictly after the
cursor, anchoring the match to the visible bottom of the terminal."
  (when-let* ((buf (claude-dashboard-instance-buffer inst))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (let ((tail-start (max (point-min)
                               (- (point-max)
                                  claude-dashboard-awaiting-tail-chars))))
          (when (re-search-backward claude-dashboard-awaiting-regexp
                                    tail-start t)
            (let ((cursor-end (match-end 0)))
              (save-excursion
                (goto-char cursor-end)
                (re-search-forward "^\\s-*[0-9]+\\.\\|\\bNo\\b\\|\\bYes\\b"
                                   (point-max) t)))))))))

(defcustom claude-dashboard-monitoring-regexp
  "[0-9]+m[ \t]+[0-9]+s[^\n]*esc to interrupt"
  "Regexp for a *live* monitoring spinner in the eat buffer tail.
Matches a Claude Code progress spinner whose elapsed time has
crossed one minute (e.g. `1m 30s · ↑ 2k tokens · esc to interrupt')."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-monitoring-tail-chars 400
  "Trailing eat-buffer chars to scan for a live monitoring spinner.
Tight enough that once the tool finishes and Claude streams a few
hundred chars of new output, the spinner falls out of the window."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-auto-name-after-turns 5
  "Send `/name <topic>' once an instance reaches this many user turns.
The injected name is derived from the first user prompt (lowercased,
kebab-cased, capped at ~30 chars).  Set to nil to disable the auto-
naming entirely.  Only fires when the agent is `idle' so a stray
keystroke doesn't interrupt mid-stream output."
  :type '(choice (const :tag "Disabled" nil) (integer :tag "Turn threshold"))
  :group 'claude-dashboard)

(defvar claude-dashboard--name-injected (make-hash-table :test 'eq)
  "Set of buffers we've already sent `/name' to (value t).")

(defvar claude-dashboard--worktree-names (make-hash-table :test 'eq)
  "Map buffer → branch/worktree name when launched via the
worktree workflow.  Used as the immediate TOPIC value and as the
slug sent to `/name' once the agent is ready (skipping the usual
turn-threshold wait).")

(defun claude-dashboard--count-user-turns (cwd sid)
  "Return the number of `type:user' entries in SID's transcript, or 0."
  (or (and cwd sid
           (let* ((proj-dir (expand-file-name
                             (format "projects/%s"
                                     (claude-dashboard--encode-cwd cwd))
                             claude-dashboard-claude-dir))
                  (file (expand-file-name (concat sid ".jsonl") proj-dir)))
             (when (file-readable-p file)
               (with-temp-buffer
                 (insert-file-contents file)
                 (goto-char (point-min))
                 (let ((n 0))
                   (while (not (eobp))
                     (when (looking-at "{[^\n]*\"type\":\"user\"")
                       (setq n (1+ n)))
                     (forward-line 1))
                   n)))))
      0))

(defun claude-dashboard--kebab-from-prompt (prompt)
  "Turn PROMPT into a short kebab-case slug suitable for `/name'."
  (when (and prompt (stringp prompt))
    (let* ((stripped (replace-regexp-in-string "[^[:alnum:][:space:]]" " "
                                               (downcase prompt)))
           (words (seq-filter
                   (lambda (w) (and (> (length w) 1)
                                    (not (member w '("the" "a" "an" "is"
                                                     "are" "was" "were"
                                                     "and" "or" "but" "to"
                                                     "of" "in" "on" "for"
                                                     "with" "this" "that"
                                                     "it" "i" "we" "you"
                                                     "do" "does" "did"
                                                     "can" "could" "would"
                                                     "should" "be" "been"
                                                     "have" "has" "had"
                                                     "my" "your")))))
                   (split-string stripped "[[:space:]]+" t)))
           (chosen (seq-take words 5))
           (slug (mapconcat #'identity chosen "-")))
      (when (> (length slug) 0)
        (substring slug 0 (min 30 (length slug)))))))

(defun claude-dashboard--maybe-auto-name (inst)
  "Send `/name <slug>' when an instance is ready for one.
Two trigger paths:
- INST was launched via the worktree workflow — fire immediately on
  first idle, using the registered worktree/branch name.
- Otherwise, wait until INST has had at least
  `claude-dashboard-auto-name-after-turns' user turns, then derive
  a slug from the first prompt.
Either way, only fires once per buffer (tracked via
`claude-dashboard--name-injected') and only when the agent is `idle'
so the keystroke doesn't collide with active output."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (cwd (claude-dashboard-instance-cwd inst))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst)))
         (proc (claude-dashboard--instance-process inst))
         (preassigned (and buf (gethash buf claude-dashboard--worktree-names))))
    (when (and buf (buffer-live-p buf) cwd proc (process-live-p proc)
               (not (gethash buf claude-dashboard--name-injected))
               (eq (claude-dashboard--status inst) 'idle)
               (or preassigned
                   (and claude-dashboard-auto-name-after-turns
                        sid
                        (null (claude-dashboard--session-name-from-transcript
                               cwd sid))
                        (>= (claude-dashboard--count-user-turns cwd sid)
                            claude-dashboard-auto-name-after-turns))))
      (let ((slug (or preassigned
                      (claude-dashboard--kebab-from-prompt
                       (claude-dashboard--first-prompt-from-transcript
                        cwd sid)))))
        (when (and slug (not (string-empty-p slug)))
          (puthash buf t claude-dashboard--name-injected)
          (process-send-string proc (format "/name %s\n" slug))
          (message "claude-dashboard: named %s → %s"
                   (buffer-name buf) slug))))))

(defun claude-dashboard-copy-topic ()
  "Copy the topic of the instance at point to the kill ring.
Uses the same resolution chain as the displayed TOPIC column —
custom name set via `/name' first, then derived prompts, with the
auto-assigned slug as the last fallback."
  (interactive)
  (let* ((inst (claude-dashboard--current-instance))
         (topic (claude-dashboard--instance-topic inst)))
    (if (and topic (not (string= topic "—")))
        (progn
          (kill-new topic)
          (message "Copied: %s" topic))
      (user-error "No topic available for this instance"))))

(defun claude-dashboard-name-instance ()
  "Manually send `/name <slug>' to the instance at point.
Prompts for a name (default derived from the session's first
user prompt).  Useful when you want to override or backfill."
  (interactive)
  (let* ((inst (claude-dashboard--current-instance))
         (cwd (claude-dashboard-instance-cwd inst))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst)))
         (default (or (and cwd sid
                           (claude-dashboard--kebab-from-prompt
                            (claude-dashboard--first-prompt-from-transcript
                             cwd sid)))
                      ""))
         (name (read-string (format "/name (default %s): " default)
                            nil nil default))
         (proc (claude-dashboard--instance-process inst)))
    (unless (and proc (process-live-p proc))
      (user-error "Instance has no live process"))
    (process-send-string proc (format "/name %s\n" name))
    (puthash (claude-dashboard-instance-buffer inst) t
             claude-dashboard--name-injected)
    (message "Sent /name %s to %s" name
             (buffer-name (claude-dashboard-instance-buffer inst)))))

(defcustom claude-dashboard-monitoring-keywords-regexp
  (concat "\\(?:"
          "pgrep\\|pidof\\|\\bps \\b\\|ps -\\b\\|ps a\\b"
          "\\|tail -[fnFN]"
          "\\|screen -ls\\|tmux ls\\|watch \\b"
          "\\|journalctl\\|systemctl status"
          "\\|nvidia-smi\\|rocm-smi\\|htop\\|top -b"
          "\\|kubectl get\\|kubectl logs\\|docker ps\\|docker logs"
          "\\|\\bsleep [0-9]\\|ping \\b"
          "\\)")
  "Regexp of shell verbs that read process / log / cluster state.
Used to classify the agent's *most recent* Bash tool call as
monitoring vs. one-shot work."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-monitoring-intent-regexp
  "^●\\s-+\\(?:Sleeping\\|Waiting\\|Polling\\|Monitoring\\|Watching\\)\\b"
  "Regexp matching an assistant message declaring monitoring intent.
A message like `● Sleeping while nb03 exports.' means the agent is
deliberately waiting on an external process even though no spinner
or tool call is currently active."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-monitoring-cmd-tail-chars 2000
  "Trailing eat-buffer chars to scan for the most recent Bash tool call.
A monitoring agent's last tool call is its most recent poll, so this
just needs to be wide enough to find that call between polls."
  :type 'integer :group 'claude-dashboard)

(defun claude-dashboard--monitoring-p (inst)
  "Return non-nil when INST appears to be monitoring an external process.
Three signals (any one is enough):
- a live `>1m … esc to interrupt' spinner in the very tail, OR
- a recent `● Sleeping/Waiting/Polling/…' assistant message
  declaring monitoring intent, OR
- the agent's most-recent `● Bash(…)' tool call invokes a process /
  log / cluster reader (the command body, including any wrapped
  continuation lines, is matched against
  `claude-dashboard-monitoring-keywords-regexp').
Anchoring on the latest tool call avoids classifying every agent
that ran `ps' once during investigation as monitoring."
  (when-let* ((buf (claude-dashboard-instance-buffer inst))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (save-excursion
        (or
         ;; Live spinner: tight tail.
         (let ((tail-start (max (point-min)
                                (- (point-max)
                                   claude-dashboard-monitoring-tail-chars))))
           (goto-char (point-max))
           (re-search-backward claude-dashboard-monitoring-regexp
                               tail-start t))
         ;; Explicit "Sleeping/Waiting/…" intent in a recent message.
         (let ((tail-start (max (point-min)
                                (- (point-max)
                                   claude-dashboard-monitoring-cmd-tail-chars))))
           (goto-char (point-max))
           (re-search-backward claude-dashboard-monitoring-intent-regexp
                               tail-start t))
         ;; Latest executed bash tool call IS a monitoring one.
         (let ((tail-start (max (point-min)
                                (- (point-max)
                                   claude-dashboard-monitoring-cmd-tail-chars))))
           (goto-char (point-max))
           (when (re-search-backward "●\\s-+Bash(" tail-start t)
             (let* ((cmd-start (match-end 0))
                    ;; Read up to the closing paren (or 800 chars cap),
                    ;; spanning wrapped continuation lines so commands
                    ;; like `… ; ps aux | …' on line 2 still count.
                    (cmd-end (save-excursion
                               (goto-char cmd-start)
                               (if (re-search-forward
                                    ")" (min (point-max) (+ cmd-start 800))
                                    t)
                                   (match-beginning 0)
                                 (min (point-max) (+ cmd-start 800)))))
                    (cmd (buffer-substring-no-properties cmd-start cmd-end)))
               (string-match-p
                claude-dashboard-monitoring-keywords-regexp cmd)))))))))

(defun claude-dashboard--status (inst)
  "Return a symbol summarizing INST's current state.
One of `running' (Claude is actively producing output),
`awaiting' (Claude is showing a menu of options for the user to pick),
`monitoring' (Claude is waiting on a long-running external tool),
`idle' (process alive but quiet for a while, no pending menu),
or `exited' (process is gone)."
  (let ((proc (claude-dashboard--instance-process inst)))
    (cond
     ((not (and proc (process-live-p proc))) 'exited)
     ((claude-dashboard--awaiting-input-p inst) 'awaiting)
     ((claude-dashboard--monitoring-p inst) 'monitoring)
     ((let ((last (claude-dashboard-instance-last-output inst)))
        (and last (> (- (float-time) last)
                     claude-dashboard-idle-threshold)))
      'idle)
     (t 'running))))

(defun claude-dashboard--state-color (status)
  (pcase status
    ('running    "#22cc22")
    ('awaiting   "#f5a623")
    ('monitoring "#36c0c0")
    ('idle       "#3b9bff")
    ('exited     "#ff4d4d")
    (_           "gray60")))

(defun claude-dashboard--status-glyph (status)
  (let ((face `(:foreground ,(claude-dashboard--state-color status) :weight bold)))
    (pcase status
      ('running    (propertize "●" 'face face))
      ('awaiting   (propertize "?" 'face face))
      ('monitoring (propertize "↻" 'face face))
      ('idle       (propertize "◐" 'face face))
      ('exited     (propertize "○" 'face face)))))

(defun claude-dashboard--humanize-duration (secs)
  "Format SECS as a short human-readable string (e.g. 12s, 3m, 2h)."
  (let ((s (truncate secs)))
    (cond ((< s 60)    (format "%ds" s))
          ((< s 3600)  (format "%dm" (/ s 60)))
          ((< s 86400) (format "%dh" (/ s 3600)))
          (t           (format "%dd" (/ s 86400))))))

(defun claude-dashboard--git-project-name (cwd)
  "Return the VCS-derived project name for CWD, or nil if not a git repo.
Prefers the basename of `remote.origin.url' (with any `.git' stripped),
falling back to the basename of the repo's main worktree."
  (when (file-directory-p cwd)
    (with-temp-buffer
      (let ((default-directory cwd))
        (cond
         ((zerop (process-file "git" nil t nil
                               "config" "--get" "remote.origin.url"))
          (let ((url (string-trim (buffer-string))))
            (when (string-match "\\([^/:]+?\\)\\(?:\\.git\\)?\\'" url)
              (match-string 1 url))))
         ((progn
            (erase-buffer)
            (zerop (process-file "git" nil t nil
                                 "worktree" "list" "--porcelain")))
          (goto-char (point-min))
          (when (re-search-forward "^worktree \\(.+\\)$" nil t)
            (file-name-nondirectory
             (directory-file-name (match-string 1))))))))))

(defun claude-dashboard--project-name (cwd)
  "Best-effort project name for CWD: VCS first, folder name as fallback."
  (or (claude-dashboard--git-project-name cwd)
      (file-name-nondirectory (directory-file-name cwd))))

;;; Branch + last-prompt caching

(defun claude-dashboard--git-branch (cwd)
  "Return current git branch of CWD, or nil if not a git checkout."
  (when (file-directory-p cwd)
    (with-temp-buffer
      (let ((default-directory cwd))
        (when (zerop (process-file "git" nil t nil
                                   "symbolic-ref" "--short" "-q" "HEAD"))
          (string-trim (buffer-string)))))))

(defun claude-dashboard--main-worktree (cwd)
  "Return the main worktree directory for CWD's repo.
Falls back to CWD when CWD is not inside a git repository."
  (or
   (when (file-directory-p cwd)
     (with-temp-buffer
       (let ((default-directory cwd))
         (when (zerop (process-file "git" nil t nil
                                    "worktree" "list" "--porcelain"))
           (goto-char (point-min))
           (when (re-search-forward "^worktree \\(.+\\)$" nil t)
             (file-name-as-directory (match-string 1)))))))
   (file-name-as-directory cwd)))

(defun claude-dashboard--worktree-name (cwd)
  "If CWD is a linked git worktree, return its name (final dir of `.git').
For the main checkout return \"main\".  For non-git directories return nil."
  (when (file-directory-p cwd)
    (with-temp-buffer
      (let ((default-directory cwd))
        (when (zerop (process-file "git" nil t nil
                                   "rev-parse" "--absolute-git-dir"))
          (let ((gd (string-trim (buffer-string))))
            (cond
             ;; Linked worktree: <repo>/.git/worktrees/<name>
             ((string-match "/worktrees/\\([^/]+\\)/?\\'" gd)
              (match-string 1 gd))
             (t "main"))))))))

(defun claude-dashboard--cached (slot inst fetcher)
  "Read INST's cache SLOT (a (text . time) cons) or refresh via FETCHER."
  (let* ((cur (pcase slot
                (:branch (claude-dashboard-instance-branch-cache inst))
                (:worktree (claude-dashboard-instance-worktree-cache inst))
                (:main-worktree (claude-dashboard-instance-main-worktree-cache inst))
                (:prompt (claude-dashboard-instance-last-prompt-cache inst))
                (:project-name (claude-dashboard-instance-project-name-cache inst))))
         (now (float-time)))
    (if (and cur (< (- now (cdr cur)) claude-dashboard-cache-ttl))
        (car cur)
      (let* ((value (funcall fetcher))
             (entry (cons value now)))
        (pcase slot
          (:branch (setf (claude-dashboard-instance-branch-cache inst) entry))
          (:worktree (setf (claude-dashboard-instance-worktree-cache inst) entry))
          (:main-worktree (setf (claude-dashboard-instance-main-worktree-cache inst) entry))
          (:prompt (setf (claude-dashboard-instance-last-prompt-cache inst) entry))
          (:project-name (setf (claude-dashboard-instance-project-name-cache inst) entry)))
        value))))

(defun claude-dashboard--last-prompt-for (cwd)
  "Tail ~/.claude/history.jsonl and return the most recent prompt for CWD."
  (let ((file (expand-file-name "history.jsonl" claude-dashboard-claude-dir)))
    (when (file-readable-p file)
      (with-temp-buffer
        (let* ((size (file-attribute-size (file-attributes file)))
               (start (max 0 (- size 65536))))
          (insert-file-contents file nil start size)
          (goto-char (point-max))
          (catch 'found
            (while (not (bobp))
              (forward-line -1)
              (when (looking-at "{")
                (let ((parsed (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
                  (goto-char (line-beginning-position))
                  (when parsed
                    (let ((entry-cwd (alist-get 'cwd parsed))
                          (entry-proj (alist-get 'project parsed))
                          (display (alist-get 'display parsed)))
                      (when (and display
                                 (or (and entry-cwd (string= entry-cwd cwd))
                                     (and entry-proj (string= entry-proj cwd))))
                        (throw 'found display)))))))
            nil))))))

;;; Session-info enrichment

(defun claude-dashboard--read-session-json (pid)
  "Read ~/.claude/sessions/<PID>.json and return its alist, or nil."
  (let ((file (expand-file-name (format "sessions/%d.json" pid)
                                claude-dashboard-claude-dir)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (ignore-errors
          (json-parse-buffer :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))))))

(defun claude-dashboard--latest-jsonl (project-dir)
  "Return path to most recently modified .jsonl in PROJECT-DIR, or nil."
  (when (file-directory-p project-dir)
    (car (sort (directory-files project-dir t "\\.jsonl\\'" t)
               (lambda (a b)
                 (time-less-p (file-attribute-modification-time
                               (file-attributes b))
                              (file-attribute-modification-time
                               (file-attributes a))))))))

(defun claude-dashboard--encode-cwd (cwd)
  "Encode CWD the way Claude names per-project session dirs.
Claude's slug rule maps both `/' and `_' to `-' and strips trailing
separators, so e.g. `/home/me/projects/gsk_broad/' becomes
`-home-me-projects-gsk-broad'."
  (concat "-"
          (replace-regexp-in-string
           "[/_]" "-"
           (directory-file-name (string-trim-left cwd "/")))))

(defun claude-dashboard--enrich-instance (inst)
  "Fill in session-id and model on INST from on-disk session metadata."
  (let* ((proc (claude-dashboard--instance-process inst))
         (pid (and proc (process-id proc)))
         (json (and pid (claude-dashboard--read-session-json pid))))
    (when json
      (when-let ((sid (alist-get 'sessionId json)))
        (setf (claude-dashboard-instance-session-id inst) sid)))
    (unless (claude-dashboard-instance-model inst)
      (let* ((cwd (claude-dashboard-instance-cwd inst))
             (proj-dir (expand-file-name
                        (format "projects/%s"
                                (claude-dashboard--encode-cwd cwd))
                        claude-dashboard-claude-dir))
             (jsonl (claude-dashboard--latest-jsonl proj-dir)))
        (when (and jsonl (file-readable-p jsonl))
          (with-temp-buffer
            (let* ((size (file-attribute-size (file-attributes jsonl)))
                   (start (max 0 (- size 32768))))
              (insert-file-contents jsonl nil start size)
              (goto-char (point-min))
              (forward-line 1)
              (catch 'found
                (while (not (eobp))
                  (when (looking-at "{")
                    (let* ((entry (ignore-errors
                                    (json-parse-buffer
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil)))
                           (msg (and entry (alist-get 'message entry)))
                           (model (and msg (alist-get 'model msg))))
                      (when model
                        (setf (claude-dashboard-instance-model inst) model)
                        (throw 'found nil))))
                  (forward-line 1))))))))
    (claude-dashboard--retag-buffer inst)))

;;; STATUS.md helpers

(defun claude-dashboard--status-path (cwd)
  "Return the absolute STATUS.md path for CWD, or nil if disabled."
  (and claude-dashboard-status-file
       (expand-file-name claude-dashboard-status-file cwd)))

(defun claude-dashboard--ensure-status-file (cwd)
  "Create STATUS.md in CWD with a starter template if absent."
  (when-let ((path (claude-dashboard--status-path cwd)))
    (unless (file-exists-p path)
      (let ((dir (file-name-directory path)))
        (when (and dir (not (file-exists-p dir)))
          (make-directory dir t)))
      (with-temp-file path
        (insert "# Status — "
                (claude-dashboard--project-name cwd) "\n\n"
                "_Auto-created by claude-dashboard at "
                (format-time-string "%Y-%m-%d %H:%M") "._\n\n"
                "Ask Claude to keep this file updated as work progresses,\n"
                "for example:\n\n"
                "    Update STATUS.md after each significant step\n"
                "    with what you did and what's next.\n")))
    path))

(defun claude-dashboard--status-mtime (cwd)
  "Return the mtime of STATUS.md in CWD, or nil if missing."
  (when-let ((path (claude-dashboard--status-path cwd)))
    (and (file-readable-p path)
         (file-attribute-modification-time (file-attributes path)))))

(defun claude-dashboard--status-snippet (cwd)
  "Return a short cell value summarizing STATUS.md age, or \"—\"."
  (let ((mtime (claude-dashboard--status-mtime cwd)))
    (if mtime
        (claude-dashboard--humanize-duration
         (- (float-time) (float-time mtime)))
      "—")))

;;; Activity tracking via eat-update-hook

(defun claude-dashboard--note-activity ()
  "Buffer-local hook on `eat-update-hook' that bumps last-output time."
  (let ((inst (gethash (current-buffer) claude-dashboard--instances)))
    (when inst
      (setf (claude-dashboard-instance-last-output inst) (float-time)))))

;;; Launch

;;; Past-session enumeration (for resume / continue)

(cl-defstruct claude-dashboard-past-session
  session-id cwd mtime first-prompt jsonl-path)

(defun claude-dashboard--read-jsonl-cwd-and-prompt (jsonl-path)
  "Return a (CWD . FIRST-PROMPT-OR-NIL) cons read from the head of JSONL-PATH.
CWD comes from the first entry that has a `cwd' field; FIRST-PROMPT is
the first user-typed prompt found, truncated to 80 chars."
  (let (cwd prompt)
    (with-temp-buffer
      (let ((size (file-attribute-size (file-attributes jsonl-path))))
        (when size
          (insert-file-contents jsonl-path nil 0 (min size 32768))
          (goto-char (point-min))
          (catch 'done
            (while (not (eobp))
              (when (looking-at "{")
                (let* ((entry (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil)))
                       (entry-cwd (and entry (alist-get 'cwd entry)))
                       (entry-type (and entry (alist-get 'type entry)))
                       (msg (and entry (alist-get 'message entry)))
                       (role (and msg (alist-get 'role msg)))
                       (content (and msg (alist-get 'content msg))))
                  (when (and (not cwd) entry-cwd) (setq cwd entry-cwd))
                  (when (and (not prompt)
                             (or (equal entry-type "user")
                                 (equal role "user"))
                             content)
                    (setq prompt
                          (cond
                           ((stringp content) content)
                           ((listp content)
                            (let ((text-block
                                   (cl-find-if
                                    (lambda (b)
                                      (and (listp b)
                                           (equal (alist-get 'type b) "text")))
                                    content)))
                              (and text-block (alist-get 'text text-block)))))))
                  (when (and cwd prompt) (throw 'done nil))))
              (forward-line 1))))))
    (cons cwd
          (and prompt
               (let ((s (string-trim
                         (replace-regexp-in-string
                          "[\n\r\t]+" " " prompt))))
                 (if (> (length s) 80) (concat (substring s 0 77) "...") s))))))

(defun claude-dashboard--past-sessions ()
  "Scan ~/.claude/projects/ and return a list of `claude-dashboard-past-session'.
Sorted by mtime, newest first."
  (let* ((root (expand-file-name "projects" claude-dashboard-claude-dir))
         (acc '()))
    (when (file-directory-p root)
      (dolist (proj-dir (directory-files root t "^[^.]" t))
        (when (file-directory-p proj-dir)
          (dolist (jsonl (directory-files proj-dir t "\\.jsonl\\'" t))
            (let* ((bn (file-name-nondirectory jsonl))
                   (sid (file-name-sans-extension bn))
                   (mtime (file-attribute-modification-time
                           (file-attributes jsonl)))
                   (info (claude-dashboard--read-jsonl-cwd-and-prompt jsonl))
                   (cwd (car info))
                   (prompt (cdr info)))
              (when cwd
                (push (make-claude-dashboard-past-session
                       :session-id sid
                       :cwd cwd
                       :mtime mtime
                       :first-prompt prompt
                       :jsonl-path jsonl)
                      acc)))))))
    (sort acc (lambda (a b)
                (time-less-p (claude-dashboard-past-session-mtime b)
                             (claude-dashboard-past-session-mtime a))))))

(defun claude-dashboard--read-past-session (&optional default-cwd)
  "Prompt for a past session via `completing-read'.
If DEFAULT-CWD is non-nil, only show sessions for that cwd.
Returns a `claude-dashboard-past-session' or signals."
  (let* ((all (claude-dashboard--past-sessions))
         (filtered (if default-cwd
                       (cl-remove-if-not
                        (lambda (s) (equal (claude-dashboard-past-session-cwd s)
                                           default-cwd))
                        all)
                     all))
         (_ (unless filtered (user-error "No past sessions found")))
         (table
          (mapcar
           (lambda (s)
             (let* ((sid (claude-dashboard-past-session-session-id s))
                    (cwd (claude-dashboard-past-session-cwd s))
                    (proj (claude-dashboard--project-name cwd))
                    (when-ts (format-time-string
                              "%Y-%m-%d %H:%M"
                              (claude-dashboard-past-session-mtime s)))
                    (prompt (or (claude-dashboard-past-session-first-prompt s)
                                ""))
                    (label (format "%s  %s  %-22s  %s"
                                   when-ts
                                   (substring sid 0 8)
                                   (truncate-string-to-width proj 22 nil ?\s "…")
                                   (propertize prompt 'face
                                               'font-lock-comment-face))))
               (cons label s)))
           filtered))
         (choice (completing-read "Resume session: "
                                  (mapcar #'car table) nil t)))
    (cdr (assoc choice table))))

(defun claude-dashboard--candidate-projects ()
  "Return a deduped list of candidate project roots."
  (let ((known (project-known-project-roots))
        (recent (and (boundp 'recentf-list)
                     (mapcar #'file-name-directory recentf-list)))
        seen)
    (cl-loop for d in (append known recent)
             for abs = (and d (file-name-as-directory (expand-file-name d)))
             when (and abs (not (member abs seen)))
             do (push abs seen)
             finally return (nreverse seen))))

(defun claude-dashboard--read-project ()
  "Prompt for a project root.
Offers `project-known-project-roots' and `recentf-list'; falls back
to a free-form directory pick."
  (let* ((cands (claude-dashboard--candidate-projects))
         (choice (completing-read "Project root (RET=other): " cands nil nil)))
    (cond
     ((and choice (member choice cands)) choice)
     ((and choice (file-directory-p choice))
      (file-name-as-directory (expand-file-name choice)))
     (t
      (file-name-as-directory
       (read-directory-name "Project root: " nil nil t))))))

(defun claude-dashboard--buffer-name (project sid-tag)
  "Build a buffer name for PROJECT with SID-TAG suffix.
SID-TAG is typically the first 8 chars of the session id, or `pending'."
  (format "*claude-%s-%s*" project sid-tag))

(defun claude-dashboard--unique-buffer-name (cwd)
  "Build an initially-unique buffer name for CWD."
  (let* ((proj (claude-dashboard--project-name cwd))
         (base (claude-dashboard--buffer-name proj "pending"))
         (name base)
         (n 2))
    (while (get-buffer name)
      (setq name (format "*claude-%s-pending<%d>*" proj n)
            n (1+ n)))
    name))

(defun claude-dashboard--retag-buffer (inst)
  "Rename INST's buffer to include its (now known) session id."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (sid (claude-dashboard-instance-session-id inst)))
    (when (and (buffer-live-p buf) sid)
      (let* ((proj (claude-dashboard--project-name
                    (claude-dashboard-instance-cwd inst)))
             (target (claude-dashboard--buffer-name
                      proj (substring sid 0 8))))
        (unless (equal (buffer-name buf) target)
          (with-current-buffer buf
            (rename-buffer target t)))))))

(defun claude-dashboard--normalize-cwd (cwd)
  "Strip a `.git[/…]' tail from CWD so it points at the repo working tree."
  (if (and (stringp cwd)
           (string-match "\\(.*?\\)/\\.git\\(?:/[^\0]*\\)?/?\\'" cwd))
      (file-name-as-directory (match-string 1 cwd))
    cwd))

(defun claude-dashboard--register (buffer cwd)
  "Insert BUFFER as an instance rooted at CWD into the registry."
  (let* ((cwd (claude-dashboard--normalize-cwd cwd))
         (inst (make-claude-dashboard-instance
                :buffer buffer
                :cwd cwd
                :started-at (float-time)
                :last-output (float-time)))
         (deploy-branch (claude-dashboard--git-branch cwd)))
    (puthash buffer inst claude-dashboard--instances)
    (when deploy-branch
      (puthash buffer deploy-branch claude-dashboard--deploy-branches))
    (with-current-buffer buffer
      (setq-local eat-kill-buffer-on-exit nil)
      (add-hook 'kill-buffer-hook #'claude-dashboard--on-buffer-killed nil t)
      (add-hook 'eat-update-hook #'claude-dashboard--note-activity nil t))
    (run-at-time 2 nil #'claude-dashboard--enrich-instance inst)
    inst))

(defun claude-dashboard--on-buffer-killed ()
  (remhash (current-buffer) claude-dashboard--instances)
  (claude-dashboard--maybe-refresh))

(defun claude-dashboard--status-injected-args ()
  "Return the `--append-system-prompt' args that ask Claude to maintain STATUS.md.
Empty list when either the file or the prompt is disabled."
  (when (and claude-dashboard-status-file
             claude-dashboard-status-system-prompt)
    (list "--append-system-prompt"
          claude-dashboard-status-system-prompt)))

(defun claude-dashboard--launch (cwd extra-args)
  "Launch claude in CWD passing EXTRA-ARGS, register, refresh, and pop to buffer."
  (let* ((default-directory cwd)
         (name (claude-dashboard--unique-buffer-name cwd))
         (buf (get-buffer-create name))
         (args (append claude-dashboard-program-args
                       (claude-dashboard--status-injected-args)
                       extra-args)))
    (claude-dashboard--ensure-status-file cwd)
    (with-current-buffer buf
      (unless (derived-mode-p 'eat-mode)
        (eat-mode))
      (eat-exec buf name claude-dashboard-program nil args))
    (claude-dashboard--register buf cwd)
    (claude-dashboard--maybe-refresh)
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun claude-dashboard-new (cwd)
  "Launch a new Claude instance in CWD as an eat buffer."
  (interactive (list (claude-dashboard--read-project)))
  (claude-dashboard--launch cwd nil))

(defun claude-dashboard--worktree-target-dir (main-wt branch)
  "Return Claude's standard worktree path: <MAIN-WT>/.claude/worktrees/<BRANCH>."
  (file-name-as-directory
   (expand-file-name (format ".claude/worktrees/%s" branch)
                     main-wt)))

;;;###autoload
(defun claude-dashboard-new-worktree (source-cwd branch)
  "Create a new git worktree + branch under SOURCE-CWD's repo, launch Claude.
The worktree lands at `<main-worktree>/.claude/worktrees/<BRANCH>'
\(Claude Code's standard layout) and is checked out on a freshly
created `<BRANCH>'.  The agent is launched in that directory and
its TOPIC is pre-bound to BRANCH — the dashboard displays it
immediately and a `/name BRANCH' is sent to the live process on
first idle so the value sticks in Claude's transcript metadata
too.

Interactively, prompts for both arguments.  If point is on an
instance row, that row's cwd is offered as the SOURCE-CWD default."
  (interactive
   (let* ((default-cwd
           (or (and (eq major-mode 'claude-dashboard-mode)
                    (ignore-errors
                      (claude-dashboard-instance-cwd
                       (claude-dashboard--current-instance))))
               (claude-dashboard--read-project)))
          (branch (read-string "New branch / worktree name: ")))
     (list default-cwd branch)))
  (when (or (null branch) (string-empty-p (string-trim branch)))
    (user-error "Branch name is required"))
  (let* ((branch (string-trim branch))
         (main-wt (claude-dashboard--main-worktree source-cwd))
         (target (claude-dashboard--worktree-target-dir main-wt branch)))
    (when (file-exists-p (directory-file-name target))
      (user-error "Worktree path already exists: %s" target))
    (let ((parent (file-name-directory (directory-file-name target))))
      (unless (file-directory-p parent)
        (make-directory parent t)))
    (with-temp-buffer
      (let* ((default-directory main-wt)
             (rc (process-file "git" nil t nil
                               "worktree" "add"
                               "-b" branch
                               (directory-file-name target))))
        (unless (zerop rc)
          (error "git worktree add failed: %s" (buffer-string)))))
    (let ((buf (claude-dashboard--launch target nil)))
      (puthash buf branch claude-dashboard--worktree-names)
      ;; Register branch as the deploy-branch too, since the agent will
      ;; start on this exact branch — saves us the live git read.
      (puthash buf branch claude-dashboard--deploy-branches)
      buf)))

;;;###autoload
(defun claude-dashboard-continue (cwd)
  "Run `claude --continue' in CWD, resuming the most recent session there."
  (interactive (list (claude-dashboard--read-project)))
  (claude-dashboard--launch cwd '("--continue")))

;;;###autoload
(defun claude-dashboard-resume (&optional only-cwd)
  "Pick a past session via completing-read and resume it.
With prefix arg or when called from a row, restrict to that row's cwd."
  (interactive
   (list (when (and (eq major-mode 'claude-dashboard-mode)
                    (or current-prefix-arg
                        (ignore-errors
                          (claude-dashboard--current-instance))))
           (claude-dashboard-instance-cwd
            (claude-dashboard--current-instance)))))
  (let* ((sess (claude-dashboard--read-past-session only-cwd))
         (sid (claude-dashboard-past-session-session-id sess))
         (cwd (claude-dashboard-past-session-cwd sess))
         (buf (claude-dashboard--launch cwd (list "--resume" sid)))
         (inst (gethash buf claude-dashboard--instances)))
    (when inst
      (setf (claude-dashboard-instance-session-id inst) sid)
      (claude-dashboard--retag-buffer inst)
      (claude-dashboard--maybe-refresh))))

;;; Per-instance actions

(defun claude-dashboard--current-instance ()
  "Return the instance under point in the dashboard, or signal."
  (let* ((section (magit-current-section))
         (val (and section (oref section value))))
    (unless (claude-dashboard-instance-p val)
      (user-error "No Claude instance at point"))
    val))

(defun claude-dashboard-visit (inst)
  "Pop to INST's eat buffer."
  (interactive (list (claude-dashboard--current-instance)))
  (pop-to-buffer (claude-dashboard-instance-buffer inst)))

(defun claude-dashboard-display (inst)
  "Display INST's eat buffer in another window without selecting it."
  (interactive (list (claude-dashboard--current-instance)))
  (display-buffer (claude-dashboard-instance-buffer inst)))

(defun claude-dashboard-dired (inst)
  "Open INST's project root in dired."
  (interactive (list (claude-dashboard--current-instance)))
  (dired-other-window (claude-dashboard-instance-cwd inst)))

(defun claude-dashboard-magit (inst)
  "Open `magit-status' on INST's project root."
  (interactive (list (claude-dashboard--current-instance)))
  (if (fboundp 'magit-status-setup-buffer)
      (magit-status-setup-buffer (claude-dashboard-instance-cwd inst))
    (user-error "Magit is not loaded")))

(defun claude-dashboard--marked-instances ()
  "Return a list of currently marked, still-live instances."
  (let (result)
    (maphash (lambda (buf _)
               (let ((inst (gethash buf claude-dashboard--instances)))
                 (when (and inst (buffer-live-p buf))
                   (push inst result))))
             claude-dashboard--marks)
    (nreverse result)))

(defun claude-dashboard--instances-for-bulk ()
  "Return the marked instances, or a list of just the one at point."
  (or (claude-dashboard--marked-instances)
      (list (claude-dashboard--current-instance))))

(defun claude-dashboard-next-line (&optional n)
  "Move to the next instance row (skipping group headers)."
  (interactive "p")
  (let ((n (or n 1)))
    (dotimes (_ (abs n))
      (forward-line (if (>= n 0) 1 -1))
      ;; Skip non-instance lines (headers, blanks).
      (while (and (not (eobp)) (not (bobp))
                  (let* ((sec (magit-current-section))
                         (val (and sec (oref sec value))))
                    (not (claude-dashboard-instance-p val))))
        (forward-line (if (>= n 0) 1 -1))))))

(defun claude-dashboard-previous-line (&optional n)
  "Move to the previous instance row."
  (interactive "p")
  (claude-dashboard-next-line (- (or n 1))))

(defun claude-dashboard-mark (&optional n)
  "Mark the current instance row and advance N lines (default 1)."
  (interactive "p")
  (let ((inst (claude-dashboard--current-instance)))
    (puthash (claude-dashboard-instance-buffer inst) t
             claude-dashboard--marks)
    (claude-dashboard--maybe-refresh)
    (claude-dashboard-next-line (or n 1))))

(defun claude-dashboard-unmark (&optional n)
  "Unmark the current instance row and advance N lines."
  (interactive "p")
  (let ((inst (claude-dashboard--current-instance)))
    (remhash (claude-dashboard-instance-buffer inst)
             claude-dashboard--marks)
    (claude-dashboard--maybe-refresh)
    (claude-dashboard-next-line (or n 1))))

(defun claude-dashboard-toggle-marks ()
  "Toggle marks on every instance row."
  (interactive)
  (dolist (inst (claude-dashboard--instances-list))
    (let ((buf (claude-dashboard-instance-buffer inst)))
      (if (gethash buf claude-dashboard--marks)
          (remhash buf claude-dashboard--marks)
        (puthash buf t claude-dashboard--marks))))
  (claude-dashboard--maybe-refresh))

(defun claude-dashboard-unmark-all ()
  "Remove all marks."
  (interactive)
  (clrhash claude-dashboard--marks)
  (claude-dashboard--maybe-refresh))

(defun claude-dashboard-do-quit ()
  "Gracefully quit all marked instances (or the one at point)."
  (interactive)
  (let ((targets (claude-dashboard--instances-for-bulk)))
    (when (or (null (cdr targets))
              (yes-or-no-p (format "Quit %d marked instance(s)? "
                                   (length targets))))
      (dolist (inst targets) (claude-dashboard-quit-instance inst))
      (clrhash claude-dashboard--marks)
      (claude-dashboard--maybe-refresh))))

(defun claude-dashboard-do-kill ()
  "Kill the eat buffer of all marked instances (or the one at point)."
  (interactive)
  (let ((targets (claude-dashboard--instances-for-bulk)))
    (when (or (null (cdr targets))
              (yes-or-no-p (format "Kill %d marked buffer(s)? "
                                   (length targets))))
      (dolist (inst targets) (claude-dashboard-kill-buffer inst))
      (clrhash claude-dashboard--marks)
      (claude-dashboard--maybe-refresh))))

(defun claude-dashboard-visit-status (inst)
  "Open INST's STATUS.md in another window, creating it if missing."
  (interactive (list (claude-dashboard--current-instance)))
  (let ((path (claude-dashboard--ensure-status-file
               (claude-dashboard-instance-cwd inst))))
    (unless path (user-error "STATUS.md is disabled"))
    (find-file-other-window path)
    (auto-revert-mode 1)))

(defun claude-dashboard-quit-instance (inst)
  "Send a graceful quit to INST's claude process."
  (interactive (list (claude-dashboard--current-instance)))
  (let ((proc (claude-dashboard--instance-process inst)))
    (unless proc (user-error "No live process"))
    (interrupt-process proc)
    (run-at-time
     1 nil
     (lambda ()
       (when (process-live-p proc)
         (delete-process proc))
       (claude-dashboard--maybe-refresh)))))

(defun claude-dashboard-kill-buffer (inst)
  "Kill INST's eat buffer outright."
  (interactive (list (claude-dashboard--current-instance)))
  (let ((buf (claude-dashboard-instance-buffer inst)))
    (when (buffer-live-p buf)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))))
  (claude-dashboard--maybe-refresh))

(defun claude-dashboard-restart (inst)
  "Restart INST's claude in the same eat buffer."
  (interactive (list (claude-dashboard--current-instance)))
  (let ((buf (claude-dashboard-instance-buffer inst))
        (cwd (claude-dashboard-instance-cwd inst)))
    (unless (buffer-live-p buf) (user-error "Buffer is gone"))
    (when-let ((proc (get-buffer-process buf)))
      (set-process-query-on-exit-flag proc nil))
    (with-current-buffer buf
      (let ((default-directory cwd)
            (inhibit-read-only t))
        ;; eat-exec blasts any running process in BUF for us.
        (eat-exec buf (buffer-name buf)
                  claude-dashboard-program nil
                  claude-dashboard-program-args)))
    (let ((inst2 (gethash buf claude-dashboard--instances)))
      (when inst2
        (setf (claude-dashboard-instance-started-at inst2) (float-time))
        (setf (claude-dashboard-instance-last-output inst2) (float-time))
        (setf (claude-dashboard-instance-session-id inst2) nil)
        (setf (claude-dashboard-instance-model inst2) nil)
        (setf (claude-dashboard-instance-branch-cache inst2) nil)
        (setf (claude-dashboard-instance-last-prompt-cache inst2) nil))
      (run-at-time 2 nil #'claude-dashboard--enrich-instance inst2)))
  (claude-dashboard--maybe-refresh))

;;; Rendering

(defclass claude-dashboard-section (magit-section) ())
(defclass claude-dashboard-group-section (magit-section) ())
(defclass claude-dashboard-instance-section (magit-section) ())

(defcustom claude-dashboard-project-max-width 14
  "Hard cap on the PROJECT column width."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-branch-max-width 24
  "Hard cap on the BRANCH column width."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-topic-max-width 30
  "Hard cap on the TOPIC column width."
  :type 'integer :group 'claude-dashboard)

(defvar claude-dashboard--topic-cache (make-hash-table :test 'eq)
  "Map buffer → (topic-string . time).  Refreshed via the standard TTL.")

(defun claude-dashboard--status-md-topic (cwd)
  "Return the first non-template heading from STATUS.md in CWD, or nil.
Skips the auto-generated `Status — <name>' heading produced by
`claude-dashboard--ensure-status-file' so the topic only fires once
the agent has populated STATUS.md with real content."
  (when-let* ((path (claude-dashboard--status-path cwd))
              ((file-readable-p path)))
    (with-temp-buffer
      (insert-file-contents path nil 0 8192)
      (goto-char (point-min))
      (let (found)
        (while (and (not found)
                    (re-search-forward "^#+\\s-+\\(.+\\)$" nil t))
          (let ((title (string-trim (match-string 1))))
            (unless (string-prefix-p "Status" title)
              (setq found title))))
        found))))

(defun claude-dashboard--first-prompt-for-session (sid)
  "Return the first prompt logged for session SID in history.jsonl, or nil.
This only fires for prompts the user typed in this session — resumed
sessions whose first message lives in the per-session transcript are
covered separately by `claude-dashboard--first-prompt-from-transcript'."
  (when sid
    (let ((file (expand-file-name "history.jsonl"
                                  claude-dashboard-claude-dir)))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (catch 'found
            (while (not (eobp))
              (when (looking-at "{")
                (let ((parsed (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
                  (goto-char (line-beginning-position))
                  (when (and parsed
                             (equal sid (alist-get 'sessionId parsed)))
                    (throw 'found (alist-get 'display parsed)))))
              (forward-line 1))
            nil))))))

(defun claude-dashboard--session-name-from-transcript (cwd sid)
  "Return the latest custom title for SID, or nil when none has been set.
Reads `~/.claude/projects/<slug>/<SID>.jsonl' looking for the most
recent `{\"type\":\"custom-title\", \"customTitle\": \"…\"}' entry.
Claude Code's `/name <name>' slash command writes such a line, so
when the user has named the conversation we report that name as the
TOPIC."
  (when (and cwd sid)
    (let* ((proj-dir (expand-file-name
                      (format "projects/%s"
                              (claude-dashboard--encode-cwd cwd))
                      claude-dashboard-claude-dir))
           (file (expand-file-name (concat sid ".jsonl") proj-dir)))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-max))
          (catch 'found
            (while (not (bobp))
              (forward-line -1)
              (when (looking-at "{")
                (let ((parsed (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
                  (goto-char (line-beginning-position))
                  (when (and parsed
                             (equal "custom-title"
                                    (alist-get 'type parsed)))
                    (let ((ct (alist-get 'customTitle parsed)))
                      (when (and ct (not (string-empty-p ct)))
                        (throw 'found ct)))))))
            nil))))))

(defun claude-dashboard--session-slug-from-transcript (cwd sid)
  "Return Claude's auto-assigned slug for SID, or nil.
The CLI tags every session with a kebab-case `slug' (e.g.
`starry-mapping-cake') in transcript entries.  Less informative than
a custom title or the first prompt, but better than `—'."
  (when (and cwd sid)
    (let* ((proj-dir (expand-file-name
                      (format "projects/%s"
                              (claude-dashboard--encode-cwd cwd))
                      claude-dashboard-claude-dir))
           (file (expand-file-name (concat sid ".jsonl") proj-dir)))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file nil 0 65536)
          (goto-char (point-min))
          (catch 'found
            (while (not (eobp))
              (when (looking-at "{")
                (let ((parsed (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
                  (goto-char (line-beginning-position))
                  (when parsed
                    (let ((slug (alist-get 'slug parsed)))
                      (when (and slug (not (string-empty-p slug)))
                        (throw 'found slug))))))
              (forward-line 1))
            nil))))))

(defun claude-dashboard--first-prompt-from-transcript (cwd sid)
  "Return the first user prompt from the per-session transcript file.
Reads `~/.claude/projects/<slug>/<SID>.jsonl' and pulls the first
entry of type `user' whose content text is human-typed prose (not a
tool result, not an angle-bracket synthetic message).  This covers
agents resumed from earlier conversations whose original first
message never went through `history.jsonl'."
  (when (and cwd sid)
    (let* ((proj-dir (expand-file-name
                      (format "projects/%s"
                              (claude-dashboard--encode-cwd cwd))
                      claude-dashboard-claude-dir))
           (file (expand-file-name (concat sid ".jsonl") proj-dir)))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file nil 0 131072)
          (goto-char (point-min))
          (catch 'found
            (while (not (eobp))
              (when (looking-at "{")
                (let ((parsed (ignore-errors
                                (json-parse-buffer
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))))
                  (goto-char (line-beginning-position))
                  (when (and parsed
                             (equal "user" (alist-get 'type parsed)))
                    (let* ((msg (alist-get 'message parsed))
                           (content (and msg (alist-get 'content msg))))
                      (cond
                       ((and (stringp content)
                             (not (string-prefix-p "<" content)))
                        (throw 'found content))
                       ((listp content)
                        (dolist (c content)
                          (let ((ctype (alist-get 'type c))
                                (text (alist-get 'text c)))
                            (when (and (equal "text" ctype)
                                       (stringp text)
                                       (not (string-prefix-p "<" text)))
                              (throw 'found text))))))))))
              (forward-line 1))
            nil))))))

(defun claude-dashboard--live-session-id (inst)
  "Return the *current* session-id for INST via the running PID, or nil.
The struct's `session-id' is captured shortly after launch and can
go stale when the agent is resumed with a new id under the same
buffer, so a fresh PID-based lookup is more reliable when the cached
id has no on-disk transcript."
  (when-let* ((proc (claude-dashboard--instance-process inst))
              (pid (and proc (process-id proc)))
              (json (claude-dashboard--read-session-json pid)))
    (alist-get 'sessionId json)))

(defun claude-dashboard--latest-transcript-prompt (cwd)
  "First user message from the most recent transcript file under CWD's slug.
Last-resort fallback: covers cases where the in-memory session-id is
stale and even the live PID-based lookup fails (e.g. the agent is
mid-resume).  Picks whichever transcript was modified most recently
in the slug's project dir."
  (when cwd
    (let* ((proj-dir (expand-file-name
                      (format "projects/%s"
                              (claude-dashboard--encode-cwd cwd))
                      claude-dashboard-claude-dir)))
      (when-let ((latest (claude-dashboard--latest-jsonl proj-dir)))
        (let* ((sid (file-name-base latest)))
          (claude-dashboard--first-prompt-from-transcript cwd sid))))))

(defun claude-dashboard--instance-topic (inst)
  "Return INST's topic, briefest relevant summary available.
The session name set inside Claude with `/name <foo>' is the
absolute source of truth — it overrides every other candidate.
Below it, the chain falls through: worktree-launch pre-assigned
name → STATUS.md heading → first user prompt (transcript, then
history.jsonl) → most-recent transcript in the project dir →
auto-generated slug → \"—\"."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (cur (gethash buf claude-dashboard--topic-cache))
         (now (float-time)))
    (if (and cur (< (- now (cdr cur)) claude-dashboard-cache-ttl))
        (car cur)
      (let* ((cwd (claude-dashboard-instance-cwd inst))
             (live-sid (claude-dashboard--live-session-id inst))
             (cached-sid (claude-dashboard-instance-session-id inst))
             (val (or
                   ;; HIGHEST PRIORITY: a name set inside Claude via
                   ;; `/name <foo>' wins over every other candidate.
                   (claude-dashboard--session-name-from-transcript
                    cwd live-sid)
                   (claude-dashboard--session-name-from-transcript
                    cwd cached-sid)
                   ;; Worktree-launch pre-assigned name (used until the
                   ;; matching `/name' lands in the transcript above).
                   (gethash buf claude-dashboard--worktree-names)
                   (claude-dashboard--status-md-topic cwd)
                   (claude-dashboard--first-prompt-from-transcript
                    cwd live-sid)
                   (claude-dashboard--first-prompt-from-transcript
                    cwd cached-sid)
                   (claude-dashboard--first-prompt-for-session live-sid)
                   (claude-dashboard--first-prompt-for-session cached-sid)
                   (claude-dashboard--latest-transcript-prompt cwd)
                   ;; Last resort: Claude's auto-generated slug.
                   (claude-dashboard--session-slug-from-transcript
                    cwd live-sid)
                   (claude-dashboard--session-slug-from-transcript
                    cwd cached-sid)
                   "—")))
        ;; Promote the live session-id back into the struct so the next
        ;; render skips the stale cached id.
        (when (and live-sid (not (equal live-sid cached-sid)))
          (setf (claude-dashboard-instance-session-id inst) live-sid))
        (puthash buf (cons val now) claude-dashboard--topic-cache)
        val))))

(defun claude-dashboard--row-format (branch-w topic-w)
  "Return the row format with dynamic BRANCH-W and TOPIC-W widths."
  (format "%%s %%s %%-%ds %%-3s %%5s %%-%ds %%-8s %%5s  %%-%ds"
          claude-dashboard-project-max-width branch-w topic-w))

(defun claude-dashboard--instance-deploy-branch (inst)
  "Return the branch INST was deployed against, falling back to live."
  (or (gethash (claude-dashboard-instance-buffer inst)
               claude-dashboard--deploy-branches)
      (claude-dashboard--instance-branch inst)
      "—"))

(defun claude-dashboard--state-abbrev (status)
  (pcase status
    ('running    "RUN")
    ('awaiting   "ASK")
    ('monitoring "MON")
    ('idle       "IDL")
    ('exited     "EXT")
    (_           "?")))

(defun claude-dashboard--status-rank (status)
  "Sort priority for STATUS: lower wins (sorts higher in the list)."
  (pcase status
    ('awaiting   0)
    ('running    1)
    ('monitoring 2)
    ('idle       3)
    ('exited     4)
    (_           5)))

(defun claude-dashboard--instance-branch (inst)
  (or (claude-dashboard--cached
       :branch inst
       (lambda ()
         (claude-dashboard--git-branch
          (claude-dashboard-instance-cwd inst))))
      "—"))

(defun claude-dashboard--instance-worktree (inst)
  (or (claude-dashboard--cached
       :worktree inst
       (lambda ()
         (claude-dashboard--worktree-name
          (claude-dashboard-instance-cwd inst))))
      "—"))

(defun claude-dashboard--column-width (header values cap)
  "Width fitting HEADER plus the longest of VALUES, capped at CAP."
  (min cap
       (max (length header)
            (apply #'max 0 (mapcar #'length values)))))

(defun claude-dashboard--shorten-path (path max-width)
  "Abbreviate PATH to fit within MAX-WIDTH columns.
Keeps the leading `~' (when applicable) and the last directory
segment intact, elides intermediate components with `…/'."
  (let ((p (abbreviate-file-name (directory-file-name path))))
    (if (<= (string-width p) max-width)
        p
      (let* ((parts (split-string p "/" t))
             (has-tilde (string-prefix-p "~" p))
             (head (if has-tilde (pop parts) ""))
             (n (length parts))
             (best (concat (if has-tilde (concat head "/") "")
                           "…/"
                           (or (car (last parts)) ""))))
        (cl-loop for k from 2 to n
                 for kept = (last parts k)
                 for rendered = (concat (if has-tilde (concat head "/") "")
                                        "…/"
                                        (mapconcat #'identity kept "/"))
                 while (<= (string-width rendered) max-width)
                 do (setq best rendered))
        (if (<= (string-width best) max-width)
            best
          (truncate-string-to-width best max-width nil ?\s "…"))))))

(defvar claude-dashboard--group-color-palette
  '("#e06c75" "#98c379" "#e5c07b" "#61afef" "#c678dd"
    "#56b6c2" "#d19a66" "#b48ead" "#88c0d0" "#a3be8c")
  "Palette of explicit hex colors used to tag each group root.")

(defvar claude-dashboard--group-color-cache (make-hash-table :test 'equal)
  "Map from group-root path to its assigned color.")

(defun claude-dashboard--group-color (root)
  "Return a stable color string for ROOT, assigning one on first sight."
  (or (gethash root claude-dashboard--group-color-cache)
      (let* ((n (hash-table-count claude-dashboard--group-color-cache))
             (color (nth (mod n (length claude-dashboard--group-color-palette))
                         claude-dashboard--group-color-palette)))
        (puthash root color claude-dashboard--group-color-cache)
        color)))

(defun claude-dashboard--root-name (root)
  "Final directory component of ROOT, used as the group's display name."
  (file-name-nondirectory (directory-file-name root)))

(defun claude-dashboard--state-face (status)
  `(:foreground ,(claude-dashboard--state-color status) :weight bold))

(defun claude-dashboard--header-line (branch-w topic-w)
  "Return the column header line, faced as a section heading."
  (propertize
   (format (claude-dashboard--row-format branch-w topic-w)
           " " " " "PROJECT" "ST" "UP" "BRANCH"
           "SESSION" "STATUS" "TOPIC")
   'face 'magit-section-heading))

(defun claude-dashboard--format-instance-line (inst branch-w topic-w)
  "Return a formatted single-line summary for INST."
  (let* ((status (claude-dashboard--status inst))
         (glyph (claude-dashboard--status-glyph status))
         (cwd (claude-dashboard-instance-cwd inst))
         (proj (claude-dashboard--cached
                :project-name inst
                (lambda ()
                  (claude-dashboard--project-name cwd))))
         (root (claude-dashboard--cached
                :main-worktree inst
                (lambda ()
                  (claude-dashboard--main-worktree
                   (claude-dashboard-instance-cwd inst)))))
         (root-color (claude-dashboard--group-color root))
         (uptime (claude-dashboard--humanize-duration
                  (- (float-time)
                     (claude-dashboard-instance-started-at inst))))
         (branch (claude-dashboard--instance-deploy-branch inst))
         (topic (claude-dashboard--instance-topic inst))
         (sid (or (and (claude-dashboard-instance-session-id inst)
                       (substring
                        (claude-dashboard-instance-session-id inst) 0 8))
                  "—")))
    (format (claude-dashboard--row-format branch-w topic-w)
            (if (gethash (claude-dashboard-instance-buffer inst)
                         claude-dashboard--marks)
                (propertize "*" 'face 'warning)
              " ")
            glyph
            (propertize (truncate-string-to-width
                         proj claude-dashboard-project-max-width nil ?\s "…")
                        'face `(:foreground ,root-color :weight bold))
            (propertize (claude-dashboard--state-abbrev status)
                        'face (claude-dashboard--state-face status))
            uptime
            (truncate-string-to-width branch branch-w nil ?\s "…")
            sid
            (claude-dashboard--status-snippet cwd)
            (truncate-string-to-width topic topic-w nil ?\s "…"))))

(defun claude-dashboard--insert-instance-section (inst branch-w topic-w)
  (magit-insert-section (claude-dashboard-instance-section inst)
    (insert (claude-dashboard--format-instance-line
             inst branch-w topic-w))
    (insert "\n")))

(defun claude-dashboard--render ()
  "Replace the current buffer's contents with a fresh dashboard."
  (let ((inhibit-read-only t)
        (instances (claude-dashboard--instances-list)))
    (erase-buffer)
    (magit-insert-section (claude-dashboard-section)
      (magit-insert-heading
        (propertize (format "Claude instances (%d)" (length instances))
                    'face 'magit-section-heading))
      (let* ((branches (mapcar #'claude-dashboard--instance-deploy-branch
                                instances))
             ;; Fixed-width chunk before TOPIC:
             ;; M G PROJECT(20) ST(3) UP(5) BRANCH SESSION(8) STATUS(5)  TOPIC
             (branch-w (claude-dashboard--column-width
                        "BRANCH" branches
                        claude-dashboard-branch-max-width))
             (prefix-w (+ 1 1 1 1 claude-dashboard-project-max-width
                            1 3 1 5 1 branch-w 1 8 1 5 2))
             (win (get-buffer-window (current-buffer) 'visible))
             (frame-w (if win (window-text-width win) (frame-text-width)))
             (topic-w (max 16 (- frame-w prefix-w))))
        (insert (claude-dashboard--header-line branch-w topic-w) "\n")
        (if (null instances)
            (insert "  (no instances — press N to launch)\n")
          (let ((sorted
                 (sort (copy-sequence instances)
                       (lambda (a b)
                         (let* ((sa (claude-dashboard--status-rank
                                     (claude-dashboard--status a)))
                                (sb (claude-dashboard--status-rank
                                     (claude-dashboard--status b))))
                           (cond
                            ((< sa sb) t)
                            ((> sa sb) nil)
                            (t
                             (> (or (claude-dashboard-instance-last-output a)
                                    0)
                                (or (claude-dashboard-instance-last-output b)
                                    0)))))))))
            (dolist (inst sorted)
              (claude-dashboard--insert-instance-section
               inst branch-w topic-w))))))))

(defun claude-dashboard--maybe-refresh ()
  "Re-render the dashboard if its buffer is live."
  ;; Auto-naming runs ahead of render so a freshly-injected /name has a
  ;; chance to land in the transcript before the topic resolver reads it.
  (dolist (inst (claude-dashboard--instances-list))
    (ignore-errors (claude-dashboard--maybe-auto-name inst)))
  (let ((buf (get-buffer claude-dashboard-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((line (line-number-at-pos)))
          (claude-dashboard--render)
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun claude-dashboard-refresh ()
  "Re-render the dashboard."
  (interactive)
  (claude-dashboard--maybe-refresh))

;;; Transient menu

(transient-define-prefix claude-dashboard-menu ()
  "Claude dashboard actions."
  ["Visit"
   ("RET" "visit"           claude-dashboard-visit)
   ("o"   "visit"           claude-dashboard-visit)
   ("O"   "display other"   claude-dashboard-display)
   ("d"   "dired cwd"       claude-dashboard-dired)
   ("v"   "magit-status"    claude-dashboard-magit)
   ("s"   "STATUS.md"       claude-dashboard-visit-status)]
  ["Marks"
   ("m"   "mark"            claude-dashboard-mark)
   ("u"   "unmark"          claude-dashboard-unmark)
   ("t"   "toggle marks"    claude-dashboard-toggle-marks)
   ("U"   "unmark all"      claude-dashboard-unmark-all)]
  ["Lifecycle (marked or row)"
   ("k"   "quit (row)"      claude-dashboard-quit-instance)
   ("K"   "kill buf (row)"  claude-dashboard-kill-buffer)
   ("r"   "restart (row)"   claude-dashboard-restart)
   ("D"   "quit marked"     claude-dashboard-do-quit)
   ("x"   "kill marked"     claude-dashboard-do-kill)]
  ["Dashboard"
   ("N"   "new instance"        claude-dashboard-new)
   ("b"   "new worktree+branch" claude-dashboard-new-worktree)
   ("c"   "continue (cwd)"      claude-dashboard-continue)
   ("R"   "resume (picker)"     claude-dashboard-resume)
   ("g"   "refresh"             claude-dashboard-refresh)
   ("q"   "quit window"         quit-window)])

;;; Mode

(defvar claude-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    ;; Navigation (ibuffer-style)
    (define-key map "n"         #'claude-dashboard-next-line)
    (define-key map "p"         #'claude-dashboard-previous-line)
    (define-key map (kbd "SPC") #'claude-dashboard-next-line)
    ;; Visit
    (define-key map (kbd "RET") #'claude-dashboard-visit)
    (define-key map "o"         #'claude-dashboard-visit)
    (define-key map "O"         #'claude-dashboard-display)
    ;; Marks (ibuffer-style)
    (define-key map "m"         #'claude-dashboard-mark)
    (define-key map "u"         #'claude-dashboard-unmark)
    (define-key map "t"         #'claude-dashboard-toggle-marks)
    (define-key map "U"         #'claude-dashboard-unmark-all)
    ;; Bulk operations on marked rows (or current row if none marked)
    (define-key map "D"         #'claude-dashboard-do-quit)
    (define-key map (kbd "x")   #'claude-dashboard-do-kill)
    ;; Per-row jumps
    (define-key map "d"         #'claude-dashboard-dired)
    (define-key map "v"         #'claude-dashboard-magit)
    (define-key map "s"         #'claude-dashboard-visit-status)
    ;; Lifecycle on the row at point
    (define-key map "k"         #'claude-dashboard-quit-instance)
    (define-key map "K"         #'claude-dashboard-kill-buffer)
    (define-key map "r"         #'claude-dashboard-restart)
    ;; Dashboard-level
    (define-key map "N"         #'claude-dashboard-new)
    (define-key map "b"         #'claude-dashboard-new-worktree)
    (define-key map "c"         #'claude-dashboard-continue)
    (define-key map "R"         #'claude-dashboard-resume)
    (define-key map "g"         #'claude-dashboard-refresh)
    (define-key map "?"         #'claude-dashboard-menu)
    map))

;; These run on every load (the defvar above only fires once).
(define-key claude-dashboard-mode-map "w" #'claude-dashboard-copy-topic)
(define-key claude-dashboard-mode-map "T" #'claude-dashboard-name-instance)
(define-key claude-dashboard-mode-map "b" #'claude-dashboard-new-worktree)

(define-derived-mode claude-dashboard-mode magit-section-mode "ClaudeDash"
  "Major mode for the Claude Code instance dashboard."
  :group 'claude-dashboard
  (setq-local truncate-lines t)
  (setq buffer-read-only t)
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  (unless claude-dashboard--refresh-timer
    (setq claude-dashboard--refresh-timer
          (run-with-timer claude-dashboard-refresh-interval
                          claude-dashboard-refresh-interval
                          #'claude-dashboard--refresh-if-visible))))

(defun claude-dashboard--refresh-if-visible ()
  (let ((buf (get-buffer claude-dashboard-buffer-name)))
    (when (and (buffer-live-p buf)
               (get-buffer-window buf 'visible))
      (claude-dashboard--maybe-refresh))))

(defun claude-dashboard--goto-first-instance ()
  "Move point to the first instance row, or stay at top if none exist."
  (goto-char (point-min))
  ;; `claude-dashboard-next-line' walks forward and stops on the first
  ;; line whose section value is a `claude-dashboard-instance', skipping
  ;; the buffer/header/no-instances filler lines.  If no instance rows
  ;; are present it falls through and leaves point at end of buffer; in
  ;; that case bring it back to point-min so the buffer doesn't look
  ;; empty when there genuinely are no instances.
  (claude-dashboard-next-line 1)
  (let* ((sec (magit-current-section))
         (val (and sec (oref sec value))))
    (unless (claude-dashboard-instance-p val)
      (goto-char (point-min)))))

;;;###autoload
(defun claude-dashboard ()
  "Open the Claude Code dashboard."
  (interactive)
  (let ((buf (get-buffer-create claude-dashboard-buffer-name)))
    (with-current-buffer buf
      (claude-dashboard-mode)
      (claude-dashboard--render)
      (claude-dashboard--goto-first-instance))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (claude-dashboard--goto-first-instance))))

(provide 'claude-dashboard)
;;; claude-dashboard.el ends here
