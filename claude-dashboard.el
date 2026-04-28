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
;; to exit it gracefully, `g' to refresh, `?' for the transient menu.

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

;;; --- Phase classification (stub) ----------------------------------------
;; Real definitions live below `claude-dashboard-name-instance' so they sit
;; alongside the other classifier customs.  This top-of-file stub block was
;; replaced wholesale; see the "Phases" section further down.

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
  "Map buffer → pre-assigned worktree/branch name (for worktree launches).")

(defun claude-dashboard--map-jsonl-entries (file fn &optional reverse max-bytes)
  "Walk JSONL FILE, parse each `{...}' line, invoke FN with the parsed alist.
Iteration is top-down by default, bottom-up when REVERSE is non-nil.
When MAX-BYTES is non-nil, only that many leading bytes are loaded
\(top-down only).  The first non-nil return value of FN ends the walk
and is returned; otherwise the walk completes and nil is returned."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (if max-bytes
          (insert-file-contents file nil 0 max-bytes)
        (insert-file-contents file))
      (catch 'claude-dashboard--map-stop
        (if reverse
            (progn
              (goto-char (point-max))
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
                      (let ((r (funcall fn parsed)))
                        (when r
                          (throw 'claude-dashboard--map-stop r))))))))
          (goto-char (point-min))
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
                  (let ((r (funcall fn parsed)))
                    (when r
                      (throw 'claude-dashboard--map-stop r))))))
            (forward-line 1)))
        nil))))

(defun claude-dashboard--count-user-turns (cwd sid)
  "Return the number of `type:user' entries in SID's transcript, or 0."
  (let ((n 0))
    (claude-dashboard--map-jsonl-entries
     (claude-dashboard--transcript-file-for-sid sid cwd)
     (lambda (entry)
       (when (equal "user" (alist-get 'type entry))
         (setq n (1+ n)))
       nil))
    n))

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
  "Send `/name <slug>' to INST when it is `idle' and ready for one.
Worktree-launched instances use their registered branch name on first
idle; otherwise we wait `claude-dashboard-auto-name-after-turns' user
turns and derive a slug from the first prompt.  Fires once per buffer."
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

;;; --- Phase classification ------------------------------------------------
;;
;; A Claude Code instance moves through five phases at runtime:
;;
;;   `exited'     OS process is gone.
;;   `running'    Spinner visible in the buffer tail — Claude is
;;                actively producing output or running a tool call.
;;   `monitoring' Variant of `running': the live tool call is a
;;                polling / sleep / watch command, OR Claude
;;                announced a deliberate wait such as
;;                `● Sleeping while nb03 exports.'.
;;   `awaiting'   No spinner; bordered prompt box visible at bottom;
;;                either a menu option is attached to the cursor, or
;;                the last sentence Claude wrote ended with `?'.
;;   `idle'       Default fallback — process alive, no spinner, no
;;                pending question.
;;
;; All five are decided by a single classifier `claude-dashboard--classify'
;; which reads the last `claude-dashboard-tail-chars' of the eat buffer
;; once per call.  The entry point `claude-dashboard--status' is a thin
;; wrapper preserved so existing callers (auto-name, header rendering,
;; status-rank) keep working unchanged.

(defcustom claude-dashboard-tail-chars 2000
  "Trailing eat-buffer chars used by `claude-dashboard--classify'.
Wide enough to span a multi-option menu plus its framing borders, the
gap between a spinner and its triggering Bash tool call, and the two
or three short sentences a question typically sits in."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-spinner-regexp "esc to interrupt"
  "Regexp marking Claude Code's live progress spinner.
Match anywhere in the tail means the agent is actively working
(generating tokens or running a tool).  Absence — combined with no
explicit waiting intent — drops the row out of the `running' family
into `awaiting' or `idle' depending on the prompt cursor."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-monitoring-cmd-regexp
  (concat "\\(?:"
          "pgrep\\|pidof\\|\\bps\\b\\|tail -[fnFN]"
          "\\|screen -ls\\|tmux ls\\|watch \\b"
          "\\|journalctl\\|systemctl status"
          "\\|nvidia-smi\\|rocm-smi\\|htop\\|top -b"
          "\\|kubectl get\\|kubectl logs\\|docker ps\\|docker logs"
          "\\|\\bsleep [0-9]\\|ping \\b"
          "\\)")
  "Regexp of shell verbs that indicate a polling / monitoring tool call.
Matched against the body of the most recent `Bash(...)' tool call when
deciding whether a `running' instance is really `monitoring'."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-monitoring-intent-regexp
  "^●[[:space:]]+\\(?:Sleeping\\|Waiting\\|Polling\\|Monitoring\\|Watching\\)\\b"
  "Regexp marking an assistant message that declares a deliberate wait.
Triggers `monitoring' even when no spinner is currently visible — the
agent has effectively paused itself between polls."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-cursor-regexp
  "^❯[[:space:]]*\\(.*?\\)[[:space:]]*$"
  "Regexp for the prompt cursor line at the bottom of the eat buffer.
Group 1 captures the text immediately following the cursor — empty for
a free-text prompt, or a menu option label like `Yes', `1.', or
`Continue' when Claude is presenting choices."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-menu-option-regexp
  "\\`\\(?:[0-9]+[. )]?\\|Yes\\|No\\|[A-Z][a-z]+\\)\\'"
  "Regexp matched against the cursor's captured trailing text.
A non-empty match means the cursor sits on a menu option, not on a
free-text input line."
  :type 'regexp :group 'claude-dashboard)

(defun claude-dashboard--tail-beg ()
  "Return the position `claude-dashboard-tail-chars' chars before point-max."
  (max (point-min) (- (point-max) claude-dashboard-tail-chars)))

(defun claude-dashboard--cursor-trailing (tail-beg)
  "Return the menu-option text on the most recent prompt cursor line.
Searches backward from point-max to TAIL-BEG.  Returns nil when no
cursor is visible, or a (possibly empty) string when one is found."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward claude-dashboard-cursor-regexp tail-beg t)
      (match-string-no-properties 1))))

(defun claude-dashboard--last-bash-cmd (tail-beg)
  "Return the body of the most recent `Bash(...)' tool call in the tail.
Search begins at point-max and stops at TAIL-BEG.  The body extends to
the matching `)' (capped at 800 chars) so commands wrapped across
continuation lines still classify."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "●[[:space:]]+Bash(" tail-beg t)
      (let* ((cmd-start (match-end 0))
             (cap (min (point-max) (+ cmd-start 800)))
             (cmd-end (save-excursion
                        (goto-char cmd-start)
                        (if (re-search-forward ")" cap t)
                            (match-beginning 0)
                          cap))))
        (buffer-substring-no-properties cmd-start cmd-end)))))

(defun claude-dashboard--last-question-mark-p (tail-beg)
  "Return non-nil when the closest sentence-final punct above point is `?'.
\"Sentence-final\" means `.', `!', or `?' followed only by whitespace at
end of line.  Used to distinguish a free-text question from an idle
prompt: if the last thing Claude wrote ended in `.' or `!' it was a
statement, not a question."
  (save-excursion
    (when (re-search-backward "[.!?][[:space:]]*$" tail-beg t)
      (eq (char-after (1- (match-end 0))) ??))))

(defun claude-dashboard--classify (inst)
  "Classify INST into one of the five phase symbols.
See the `;;; --- Phase classification' commentary above for the full
state machine.  Reads the eat buffer tail exactly once per call."
  (let ((proc (claude-dashboard--instance-process inst)))
    (cond
     ((not (and proc (process-live-p proc))) 'exited)
     (t
      (with-current-buffer (claude-dashboard-instance-buffer inst)
        (let* ((tail-beg (claude-dashboard--tail-beg))
               (spinner-p (save-excursion
                            (goto-char (point-max))
                            (re-search-backward
                             claude-dashboard-spinner-regexp tail-beg t)))
               (intent-p (save-excursion
                           (goto-char (point-max))
                           (re-search-backward
                            claude-dashboard-monitoring-intent-regexp
                            tail-beg t))))
          (cond
           ;; Active spinner OR explicit waiting intent → running family.
           ((or spinner-p intent-p)
            (let ((cmd (claude-dashboard--last-bash-cmd tail-beg)))
              (if (or intent-p
                      (and cmd
                           (string-match-p
                            claude-dashboard-monitoring-cmd-regexp cmd)))
                  'monitoring
                'running)))
           ;; No spinner: examine the prompt cursor.
           (t
            (let ((trailing (claude-dashboard--cursor-trailing tail-beg)))
              (cond
               ;; No cursor visible — fall back to idle.
               ((null trailing) 'idle)
               ;; Cursor with a menu option attached.
               ((and (> (length trailing) 0)
                     (string-match-p
                      claude-dashboard-menu-option-regexp trailing))
                'awaiting)
               ;; Bare cursor: question vs statement.
               ((save-excursion
                  (goto-char (point-max))
                  (re-search-backward claude-dashboard-cursor-regexp
                                      tail-beg t)
                  (claude-dashboard--last-question-mark-p tail-beg))
                'awaiting)
               (t 'idle)))))))))))

(defun claude-dashboard--status (inst)
  "Return INST's current phase symbol.
Thin wrapper around `claude-dashboard--classify'; preserved as the
public entry point for callers like the renderer and `--maybe-auto-name'."
  (claude-dashboard--classify inst))

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

(defconst claude-dashboard--cache-slots
  `((:branch        . ,(cons #'claude-dashboard-instance-branch-cache
                             (lambda (i v) (setf (claude-dashboard-instance-branch-cache i) v))))
    (:worktree      . ,(cons #'claude-dashboard-instance-worktree-cache
                             (lambda (i v) (setf (claude-dashboard-instance-worktree-cache i) v))))
    (:main-worktree . ,(cons #'claude-dashboard-instance-main-worktree-cache
                             (lambda (i v) (setf (claude-dashboard-instance-main-worktree-cache i) v))))
    (:prompt        . ,(cons #'claude-dashboard-instance-last-prompt-cache
                             (lambda (i v) (setf (claude-dashboard-instance-last-prompt-cache i) v))))
    (:project-name  . ,(cons #'claude-dashboard-instance-project-name-cache
                             (lambda (i v) (setf (claude-dashboard-instance-project-name-cache i) v)))))
  "Map cache slot keyword → (GETTER . SETTER) for `claude-dashboard--cached'.")

(defun claude-dashboard--cached (slot inst fetcher)
  "Read INST's cache SLOT (a (text . time) cons) or refresh via FETCHER."
  (let* ((accessors (cdr (assq slot claude-dashboard--cache-slots)))
         (cur (funcall (car accessors) inst))
         (now (float-time)))
    (if (and cur (< (- now (cdr cur)) claude-dashboard-cache-ttl))
        (car cur)
      (let ((value (funcall fetcher)))
        (funcall (cdr accessors) inst (cons value now))
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

;;; Tool-use extraction (drives the ACTIVITY column + last-exchange body)

(defun claude-dashboard--latest-tool-use (cwd sid)
  "Return the most recent `tool_use' from SID's transcript, or nil.
Result is a plist (:name STR :input ALIST)."
  (claude-dashboard--map-jsonl-entries
   (claude-dashboard--transcript-file-for-sid sid cwd)
   (lambda (entry)
     (when (equal "assistant" (alist-get 'type entry))
       (let* ((msg (alist-get 'message entry))
              (content (and msg (alist-get 'content msg))))
         (when (listp content)
           (cl-some
            (lambda (c)
              (when (equal "tool_use" (alist-get 'type c))
                (list :name (alist-get 'name c)
                      :input (alist-get 'input c))))
            ;; Within one assistant turn, the last tool_use is the
            ;; most recent.
            (reverse content))))))
   t))

(defun claude-dashboard--tool-hint (name input)
  "Short identifying string for a tool call (NAME, INPUT alist), or nil."
  (pcase name
    ("Bash"
     (when-let ((cmd (alist-get 'command input)))
       ;; Skip a leading `cd …; ' / `cd … && ' prefix, then take the
       ;; first whitespace-separated token (the actual command name).
       (let ((clean (replace-regexp-in-string
                     "\\`\\(?:cd [^&;|]*\\(?:&&\\|;\\) *\\)?" "" cmd)))
         (car (split-string clean "[ \t\n]+" t)))))
    ((or "Edit" "Write" "MultiEdit" "NotebookEdit" "Read")
     (when-let ((p (alist-get 'file_path input)))
       (file-name-nondirectory p)))
    ((or "Grep" "Glob")
     (alist-get 'pattern input))
    ("WebFetch"
     (when-let ((url (alist-get 'url input)))
       (when (string-match "//\\([^/]+\\)" url)
         (match-string 1 url))))
    ("WebSearch"
     (alist-get 'query input))
    ("Agent"
     (or (alist-get 'subagent_type input)
         (alist-get 'description input)))
    ("Task"
     (alist-get 'description input))
    (_ nil)))

(defun claude-dashboard--first-sentence (text)
  "Return the first sentence of TEXT, with markdown markers stripped."
  (when (and text (stringp text))
    (let* ((trimmed (string-trim text))
           ;; Take everything up to the first sentence boundary
           ;; (period/!/? followed by space or end-of-line) or hard newline.
           (first-line (car (split-string trimmed "\n" t)))
           (first-sent (if (string-match
                            "\\`\\(.*?[.!?]\\)\\(?:\\s-\\|\\'\\)"
                            first-line)
                           (match-string 1 first-line)
                         first-line))
           ;; Strip leading markdown markers (#, *, -, >, backticks).
           (clean (replace-regexp-in-string
                   "\\`[ \t#*>`-]+" "" first-sent)))
      (and (> (length clean) 0) clean))))

(defun claude-dashboard--activity-cell (cwd sid)
  "Return a short summary of the agent's most recent activity.
Walks SID's transcript bottom-up and returns the first sentence of
the latest assistant text content, OR a `<Tool> <hint>' summary
when the very last assistant content item is a tool_use rather
than prose.  Falls back to `—' when no assistant turn exists yet."
  (or (claude-dashboard--map-jsonl-entries
       (claude-dashboard--transcript-file-for-sid sid cwd)
       (lambda (entry)
         (when (equal "assistant" (alist-get 'type entry))
           (let ((content (and (alist-get 'message entry)
                               (alist-get 'content
                                          (alist-get 'message entry)))))
             (when (listp content)
               (cl-some
                (lambda (c)
                  (let ((ctype (alist-get 'type c)))
                    (cond
                     ((equal "text" ctype)
                      (claude-dashboard--first-sentence
                       (alist-get 'text c)))
                     ((equal "tool_use" ctype)
                      (let* ((name (alist-get 'name c))
                             (hint (claude-dashboard--tool-hint
                                    name (alist-get 'input c))))
                        (if (and hint (stringp hint)
                                 (> (length hint) 0))
                            (format "%s %s" name hint)
                          name))))))
                (reverse content))))))
       t)
      "—"))

(defun claude-dashboard--all-exchanges (cwd sid)
  "Return every (:user STR :asst STR :id STR) exchange in SID's transcript.
Walked top-down so the result is chronological.  An exchange is
opened on each non-meta `user' message whose content has visible
text; subsequent assistant text content is appended to that
exchange's :asst (multiple assistant turns between two user turns
are concatenated with a blank line)."
  (let (exchanges current)
    (claude-dashboard--map-jsonl-entries
     (claude-dashboard--transcript-file-for-sid sid cwd)
     (lambda (entry)
       (let ((type (alist-get 'type entry))
             (msg (alist-get 'message entry))
             (is-meta (alist-get 'isMeta entry))
             (pid (alist-get 'promptId entry)))
         (cond
          ((and (equal "user" type) (not is-meta))
           (let* ((content (and msg (alist-get 'content msg)))
                  (txt (cond
                        ((stringp content) content)
                        ((listp content)
                         (when-let ((it (cl-find-if
                                         (lambda (c)
                                           (equal "text"
                                                  (alist-get 'type c)))
                                         content)))
                           (alist-get 'text it))))))
             (when (and txt (stringp txt)
                        (not (string-prefix-p "<" txt))
                        (> (length (string-trim txt)) 0))
               (when current (push current exchanges))
               (setq current
                     (list :user (string-trim txt)
                           :asst nil
                           :id (or pid (md5 txt)))))))
          ((and (equal "assistant" type) current)
           (let ((content (and msg (alist-get 'content msg))))
             (when (listp content)
               (dolist (c content)
                 (when (equal "text" (alist-get 'type c))
                   (let ((txt (alist-get 'text c)))
                     (when (and txt (> (length (string-trim txt)) 0))
                       (let ((prior (plist-get current :asst))
                             (new (string-trim txt)))
                         (setq current
                               (plist-put current :asst
                                          (if prior
                                              (concat prior "\n\n" new)
                                            new)))))))))))))
       nil))
    (when current (push current exchanges))
    (nreverse exchanges)))

(defun claude-dashboard--last-exchange (cwd sid)
  "Return (:user STR :asst STR) — the latest user query and assistant text.
Walks SID's transcript bottom-up and stops as soon as it has both
the most recent user message and the most recent assistant text
content.  Either field may be nil."
  (let (last-user last-asst)
    (claude-dashboard--map-jsonl-entries
     (claude-dashboard--transcript-file-for-sid sid cwd)
     (lambda (entry)
       (let ((type (alist-get 'type entry))
             (msg (alist-get 'message entry))
             (is-meta (alist-get 'isMeta entry)))
         (cond
          ((and (equal "user" type) (not is-meta) (not last-user))
           (let* ((content (and msg (alist-get 'content msg)))
                  (txt (cond
                        ((stringp content) content)
                        ((listp content)
                         (when-let ((it (cl-find-if
                                         (lambda (c)
                                           (equal "text"
                                                  (alist-get 'type c)))
                                         content)))
                           (alist-get 'text it))))))
             (when (and txt (stringp txt)
                        (not (string-prefix-p "<" txt))
                        (> (length (string-trim txt)) 0))
               (setq last-user (string-trim txt)))))
          ((and (equal "assistant" type) (not last-asst))
           (let ((content (and msg (alist-get 'content msg))))
             (when (listp content)
               (when-let* ((it (cl-find-if
                                (lambda (c)
                                  (and (equal "text" (alist-get 'type c))
                                       (let ((s (alist-get 'text c)))
                                         (and s
                                              (> (length (string-trim s))
                                                 0)))))
                                content))
                           (txt (alist-get 'text it)))
                 (setq last-asst (string-trim txt))))))))
       (when (and last-user last-asst) t))
     t)
    (list :user last-user :asst last-asst)))

;;; Activity tracking via eat-update-hook

(defvar-local claude-dashboard--last-eat-pmax nil
  "Buffer-local: last `point-max' we observed when noting activity.
Compared in `claude-dashboard--note-activity' so cosmetic eat
redraws (cursor blinks, focus changes, status-line repaints) do
not get counted as new output — they don't grow the buffer.")

(defun claude-dashboard--note-activity ()
  "Bump last-output only when the eat buffer actually grew.
`eat-update-hook' fires on every redraw, including ones triggered
by switching focus into the eat buffer.  Real output from the
agent appends to the buffer (point-max grows); cosmetic redraws
don't.  Gating on size growth keeps focus from flipping a row's
status to RUN."
  (let* ((inst (gethash (current-buffer) claude-dashboard--instances))
         (pmax (point-max)))
    (when inst
      (when (or (null claude-dashboard--last-eat-pmax)
                (> pmax claude-dashboard--last-eat-pmax))
        (setf (claude-dashboard-instance-last-output inst) (float-time)))
      (setq claude-dashboard--last-eat-pmax pmax))))

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
         (labels (mapcar #'car table))
         ;; Wrap in a metadata-providing completion table so vertico /
         ;; ivy / ido / default emacs all preserve our newest-first
         ;; mtime order instead of re-sorting alphabetically.
         (collection
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action labels string pred))))
         (choice (completing-read "Resume session: " collection nil t)))
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
  (let ((session (gethash (current-buffer)
                          claude-dashboard--screen-sessions)))
    (claude-dashboard--kill-screen-session session)
    (remhash (current-buffer) claude-dashboard--screen-sessions))
  (remhash (current-buffer) claude-dashboard--instances)
  (claude-dashboard--write-manifest)
  (claude-dashboard--maybe-refresh))

;;; Multiplexer (GNU screen) integration

(defcustom claude-dashboard-multiplexer nil
  "Optional terminal multiplexer wrapping each claude process.
nil      — direct eat subprocess (default; processes die when emacs exits).
`screen' — each instance runs inside a detached GNU screen session;
           eat attaches via `screen -x'.  The session survives emacs
           exit, so `claude-dashboard-restore' on a fresh emacs can
           re-attach to all surviving claudes.  Requires the `screen'
           binary to be in PATH."
  :type '(choice (const :tag "Direct (no multiplexer)" nil)
                 (const :tag "GNU screen" screen))
  :group 'claude-dashboard)

(defcustom claude-dashboard-manifest-file
  (expand-file-name "dashboard-manifest.el" claude-dashboard-claude-dir)
  "File where dashboard records each multiplexed instance's metadata.
Read by `claude-dashboard-restore' on a fresh emacs to re-attach to
screen sessions that survived the previous session."
  :type 'file :group 'claude-dashboard)

(defvar claude-dashboard--screen-sessions (make-hash-table :test 'eq)
  "Map buffer → screen-session-name (string) for multiplexed instances.")

(defun claude-dashboard--screen-session-name (cwd)
  "Generate a unique screen session name keyed off CWD's project name."
  (format "claude-dashboard.%s.%d"
          (file-name-nondirectory (directory-file-name cwd))
          (random 1000000)))

(defun claude-dashboard--screen-session-exists-p (name)
  "Return non-nil when a screen session NAME is currently running."
  (and name
       (zerop (call-process "screen" nil nil nil
                            "-S" name "-Q" "select" "."))))

(defun claude-dashboard--kill-screen-session (name)
  "Terminate screen session NAME, if any."
  (when (claude-dashboard--screen-session-exists-p name)
    (call-process "screen" nil nil nil "-S" name "-X" "quit")))

(defcustom claude-dashboard-screen-term "xterm-256color"
  "TERM value to use when attaching to a screen session via eat.
Eat's default `eat-256color' has a `clear' terminfo entry GNU
screen rejects (\"Clear screen capability required\"), so the
screen-attach path must override TERM.  `xterm-256color' is the
safest universally-installed value."
  :type 'string :group 'claude-dashboard)

(defun claude-dashboard--exec-eat (buf name program args &optional term)
  "Run PROGRAM ARGS inside eat in BUF, with the dashboard's tweaks.
When TERM is non-nil, override `eat-term-name' buffer-locally
before eat-exec runs — required for `screen -x' since screen
rejects eat's default TERM (\"Clear screen capability required\")."
  (with-current-buffer buf
    ;; Eat's shell-prompt annotation reserves a one-column left margin.
    ;; Claude Code is a TUI app, not a shell — the column shifts the
    ;; whole frame right and clips the right edge of the boxed prompt,
    ;; producing an apparent extra wrap line.  Disable it before
    ;; `eat-mode' runs so the margin isn't installed in this buffer.
    (setq-local eat-enable-shell-prompt-annotation nil)
    (unless (derived-mode-p 'eat-mode) (eat-mode))
    ;; Must be set AFTER `eat-mode' — its initialiser resets
    ;; `eat-term-name' to its defcustom default.
    (when (and term (boundp 'eat-term-name))
      (setq-local eat-term-name term))
    (eat-exec buf name program nil args)))

(defun claude-dashboard--write-manifest ()
  "Persist running multiplexed instances to `claude-dashboard-manifest-file'.
Each entry is a plist (:cwd :session :buffer-name :recorded).  Direct
\(non-multiplexed) instances are NOT recorded — they cannot be
restored after emacs exits anyway."
  (when (and (eq claude-dashboard-multiplexer 'screen)
             claude-dashboard-manifest-file)
    (let ((entries
           (cl-loop for inst in (claude-dashboard--instances-list)
                    for buf = (claude-dashboard-instance-buffer inst)
                    for session = (gethash buf
                                            claude-dashboard--screen-sessions)
                    when session
                    collect (list :cwd (claude-dashboard-instance-cwd inst)
                                  :session session
                                  :buffer-name (buffer-name buf)
                                  :recorded (current-time)))))
      (let ((dir (file-name-directory claude-dashboard-manifest-file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (with-temp-file claude-dashboard-manifest-file
        (insert ";;; -*- lisp-data -*-\n")
        (let ((print-level nil) (print-length nil))
          (prin1 entries (current-buffer)))
        (insert "\n")))))

(defun claude-dashboard--read-manifest ()
  "Read `claude-dashboard-manifest-file' and return the entry list, or nil."
  (when (and claude-dashboard-manifest-file
             (file-readable-p claude-dashboard-manifest-file))
    (with-temp-buffer
      (insert-file-contents claude-dashboard-manifest-file)
      (goto-char (point-min))
      (ignore-errors (read (current-buffer))))))

(defun claude-dashboard--launch (cwd extra-args)
  "Launch claude in CWD passing EXTRA-ARGS, register, refresh, and pop to buffer.
When `claude-dashboard-multiplexer' is `screen', wraps the process
in a detached GNU screen session that survives emacs exit; the
session's name is recorded in `claude-dashboard--screen-sessions'
\(keyed by buffer) and persisted to the manifest file."
  (let* ((default-directory cwd)
         (name (claude-dashboard--unique-buffer-name cwd))
         (buf (get-buffer-create name))
         (args (append claude-dashboard-program-args extra-args)))
    (cond
     ((eq claude-dashboard-multiplexer 'screen)
      (let ((session (claude-dashboard--screen-session-name cwd)))
        ;; 1. Spawn a detached screen session running claude.
        (apply #'call-process "screen" nil nil nil
               "-dmS" session
               claude-dashboard-program args)
        ;; 2. Attach via eat — screen owns the PTY; eat is one client.
        ;; TERM override required: see `claude-dashboard-screen-term'.
        (claude-dashboard--exec-eat buf name "screen"
                                    (list "-x" session)
                                    claude-dashboard-screen-term)
        ;; 3. Remember the session for cleanup + manifest.
        (puthash buf session claude-dashboard--screen-sessions)))
     (t
      (claude-dashboard--exec-eat buf name claude-dashboard-program args)))
    (claude-dashboard--register buf cwd)
    (claude-dashboard--write-manifest)
    (claude-dashboard--maybe-refresh)
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun claude-dashboard-restore ()
  "Re-attach surviving screen sessions recorded in the manifest.
Reads `claude-dashboard-manifest-file' and, for each entry whose
screen session is still running, creates a fresh eat buffer that
attaches to it via `screen -x'.  Stale entries (sessions that have
since exited) are silently skipped.  Requires
`claude-dashboard-multiplexer' to be `screen'."
  (interactive)
  (unless (eq claude-dashboard-multiplexer 'screen)
    (user-error "Set `claude-dashboard-multiplexer' to `screen' first"))
  (let ((entries (claude-dashboard--read-manifest))
        (restored 0)
        (stale 0))
    (dolist (e entries)
      (let* ((cwd (plist-get e :cwd))
             (session (plist-get e :session))
             (buffer-name (plist-get e :buffer-name)))
        (cond
         ((not (claude-dashboard--screen-session-exists-p session))
          (cl-incf stale))
         ((cl-some (lambda (i)
                     (equal (gethash (claude-dashboard-instance-buffer i)
                                     claude-dashboard--screen-sessions)
                            session))
                   (claude-dashboard--instances-list))
          ;; Already attached by a prior `claude-dashboard-restore' call.
          nil)
         (t
          (let* ((default-directory cwd)
                 (buf (get-buffer-create
                       (or (and (not (get-buffer buffer-name)) buffer-name)
                           (claude-dashboard--unique-buffer-name cwd)))))
            (claude-dashboard--exec-eat buf (buffer-name buf) "screen"
                                        (list "-x" session)
                                        claude-dashboard-screen-term)
            (puthash buf session claude-dashboard--screen-sessions)
            (claude-dashboard--register buf cwd)
            (cl-incf restored))))))
    (claude-dashboard--write-manifest)
    (claude-dashboard--maybe-refresh)
    (message "claude-dashboard: restored %d session(s); %d stale skipped"
             restored stale)))

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
  "Create a new git worktree + BRANCH under SOURCE-CWD's repo, then launch Claude.
Worktree lands at `<main-worktree>/.claude/worktrees/<BRANCH>'.  TOPIC
is pre-bound to BRANCH and `/name BRANCH' is injected on first idle."
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

(defun claude-dashboard-quit-instance (inst)
  "Send a graceful quit to INST's claude process and kill its eat buffer."
  (interactive (list (claude-dashboard--current-instance)))
  (let ((proc (claude-dashboard--instance-process inst))
        (buf (claude-dashboard-instance-buffer inst)))
    (unless proc (user-error "No live process"))
    (interrupt-process proc)
    (run-at-time
     1 nil
     (lambda ()
       (when (process-live-p proc)
         (delete-process proc))
       (when (buffer-live-p buf)
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buf)))
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
(defclass claude-dashboard-instance-section (magit-section) ())
(defclass claude-dashboard-query-section (magit-section) ())

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

(defun claude-dashboard--first-prompt-for-session (sid)
  "Return the first prompt logged for session SID in history.jsonl, or nil."
  (when sid
    (claude-dashboard--map-jsonl-entries
     (expand-file-name "history.jsonl" claude-dashboard-claude-dir)
     (lambda (entry)
       (and (equal sid (alist-get 'sessionId entry))
            (alist-get 'display entry))))))

(defun claude-dashboard--transcript-file-for-sid (sid &optional _cwd)
  "Locate the most-recently-modified jsonl transcript for SID.
Scans every project subdir and picks the freshest file (mtime is
authoritative since the same sid can appear under multiple cwds).
The CWD argument is accepted for caller convenience but ignored."
  (when sid
    (let* ((target (concat sid ".jsonl"))
           (projects-dir (expand-file-name "projects"
                                           claude-dashboard-claude-dir))
           candidates)
      (when (file-directory-p projects-dir)
        (dolist (sub (directory-files projects-dir t "^[^.]"))
          (let ((c (expand-file-name target sub)))
            (when (file-readable-p c)
              (push c candidates))))
        (when candidates
          (car (sort candidates
                     (lambda (a b)
                       (time-less-p
                        (file-attribute-modification-time
                         (file-attributes b))
                        (file-attribute-modification-time
                         (file-attributes a)))))))))))

(defun claude-dashboard--session-name-from-transcript (cwd sid)
  "Return the latest `customTitle' for SID, or nil when none has been set.
Walks the transcript bottom-up so the *last* `/name' wins."
  (claude-dashboard--map-jsonl-entries
   (claude-dashboard--transcript-file-for-sid sid cwd)
   (lambda (entry)
     (when (equal "custom-title" (alist-get 'type entry))
       (let ((ct (alist-get 'customTitle entry)))
         (and ct (not (string-empty-p ct)) ct))))
   t))

(defun claude-dashboard--first-prompt-from-transcript (cwd sid)
  "Return the first human-typed user prompt from SID's transcript, or nil.
Skips synthetic `<…>' messages and tool results."
  (claude-dashboard--map-jsonl-entries
   (claude-dashboard--transcript-file-for-sid sid cwd)
   (lambda (entry)
     (when (equal "user" (alist-get 'type entry))
       (let* ((msg (alist-get 'message entry))
              (content (and msg (alist-get 'content msg))))
         (cond
          ((and (stringp content)
                (not (string-prefix-p "<" content)))
           content)
          ((listp content)
           (cl-some (lambda (c)
                      (let ((ctype (alist-get 'type c))
                            (text (alist-get 'text c)))
                        (and (equal "text" ctype)
                             (stringp text)
                             (not (string-prefix-p "<" text))
                             text)))
                    content))))))
   nil 131072))

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

(defun claude-dashboard--live-session-name (inst)
  "Return the *current* conversation name for INST, or nil.
Reads `~/.claude/sessions/<PID>.json' and returns its `name' field.
This file is updated in real-time by the Claude CLI on `/rename'
\(and `/name'), so it is the authoritative current value even when
the per-session transcript jsonl files have older customTitle
entries from earlier renames."
  (when-let* ((proc (claude-dashboard--instance-process inst))
              (pid (and proc (process-id proc)))
              (json (claude-dashboard--read-session-json pid))
              (name (alist-get 'name json)))
    (and (stringp name) (not (string-empty-p name)) name)))

(defun claude-dashboard--instance-topic (inst)
  "Return INST's session name, or `—' when none has been set.
Reads the live PID-json `name' field first (updated by Claude on
every `/name' / `/rename'), then falls back to the most recent
`custom-title' entry in the per-session transcript.  The worktree-
launch pre-assigned name is used as a temporary placeholder until
Claude has actually written the matching `/name' to its metadata."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (cur (gethash buf claude-dashboard--topic-cache))
         (now (float-time)))
    (if (and cur (< (- now (cdr cur)) claude-dashboard-cache-ttl))
        (car cur)
      (let* ((cwd (claude-dashboard-instance-cwd inst))
             (live-sid (claude-dashboard--live-session-id inst))
             (cached-sid (claude-dashboard-instance-session-id inst))
             (val (or (claude-dashboard--live-session-name inst)
                      (claude-dashboard--session-name-from-transcript
                       cwd live-sid)
                      (claude-dashboard--session-name-from-transcript
                       cwd cached-sid)
                      (gethash buf claude-dashboard--worktree-names)
                      "—")))
        (when (and live-sid (not (equal live-sid cached-sid)))
          (setf (claude-dashboard-instance-session-id inst) live-sid))
        (puthash buf (cons val now) claude-dashboard--topic-cache)
        val))))

(defun claude-dashboard--row-format (branch-w _topic-w)
  "Return the row format with dynamic BRANCH-W width.
TOPIC is the trailing column and is rendered with `%s' so short
topics don't pad with trailing spaces — that padding could push
the visible row past the window's right edge and wrap to a
second line on narrower windows."
  (format "%%s %%s %%-%ds %%-3s %%5s %%-%ds %%-8s %%-24s  %%s"
          claude-dashboard-project-max-width branch-w))

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

(defun claude-dashboard--state-face (status)
  `(:foreground ,(claude-dashboard--state-color status) :weight bold))

(defun claude-dashboard--header-line (branch-w topic-w)
  "Return the column header line, faced as a section heading."
  (propertize
   (format (claude-dashboard--row-format branch-w topic-w)
           " " " " "PROJECT" "ST" "UP" "BRANCH"
           "SESSION" "ACTIVITY" "TOPIC")
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
         ;; Collapse any internal newlines / runs of whitespace so the
         ;; row never spans multiple lines even if the source string
         ;; (e.g. a multi-line first prompt) had a newline.
         (topic (replace-regexp-in-string
                 "[\t\n\r ]+" " "
                 (or (claude-dashboard--instance-topic inst) "")))
         (sid-full (or (claude-dashboard--live-session-id inst)
                       (claude-dashboard-instance-session-id inst)))
         (sid (or (and sid-full (substring sid-full 0 8)) "—"))
         (activity-cell
          (truncate-string-to-width
           (claude-dashboard--activity-cell cwd sid-full) 24 nil ?\s "…")))
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
            activity-cell
            ;; No padding char — keep the row's printed length equal
            ;; to its actual content so it never overflows the window.
            (truncate-string-to-width topic topic-w nil nil "…"))))

(defcustom claude-dashboard-exchange-text-width 110
  "Hard cap on the rendered width of a single line in the body."
  :type 'integer :group 'claude-dashboard)

(defun claude-dashboard--render-body-line (prefix text-face text)
  "Insert one body line: PREFIX literally, then TEXT in TEXT-FACE."
  (let* ((flat (replace-regexp-in-string
                "[\t\n\r ]+" " " (string-trim text)))
         (line (truncate-string-to-width
                flat claude-dashboard-exchange-text-width nil nil "…")))
    (insert prefix (propertize line 'face text-face) "\n")))

(defun claude-dashboard--insert-query-section (xch)
  "Insert a magit subsection for one exchange XCH (`:user :asst :id').
The user prompt is the section heading (`❯ …'); the formatted
assistant response is the section body, dimmed in `shadow' face.
Sections start collapsed; press TAB on the heading or `3' globally
to reveal responses."
  (let* ((user-text (or (plist-get xch :user) ""))
         (asst-text (or (plist-get xch :asst) ""))
         (heading
          (concat "    "
                  (propertize "❯" 'face 'font-lock-keyword-face)
                  " "
                  (propertize
                   (truncate-string-to-width
                    (replace-regexp-in-string "[\t\n\r ]+" " " user-text)
                    claude-dashboard-exchange-text-width nil nil "…")
                   'face 'default)))
         (section
          (magit-insert-section (claude-dashboard-query-section
                                 (plist-get xch :id) t)
            (magit-insert-heading heading)
            (when (> (length (string-trim asst-text)) 0)
              (insert (propertize
                       (replace-regexp-in-string
                        "^" "      "
                        (string-trim-right asst-text))
                       'face 'shadow)
                      "\n")))))
    (when (and section (oref section hidden))
      (magit-section-hide section))))

(defun claude-dashboard--insert-instance-overview (inst)
  "Insert the per-instance overview body (visible when row unfolds).
Each user query becomes its own foldable subsection whose body is
the formatted assistant response.  Combined with magit-section's
`magit-section-show-level-N-all' bindings on `1'..`4', this gives
three progressive views: rows-only (1), rows + queries (2), rows
+ queries + responses (3)."
  (let* ((cwd (claude-dashboard-instance-cwd inst))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst)))
         (exchanges (claude-dashboard--all-exchanges cwd sid)))
    (if exchanges
        (dolist (xch exchanges)
          (claude-dashboard--insert-query-section xch))
      (insert "    "
              (propertize "(no exchange yet)" 'face 'shadow)
              "\n"))))

(defun claude-dashboard--insert-instance-section (inst branch-w topic-w)
  ;; Each instance row is the heading of a magit section whose body
  ;; is the per-instance overview.  TAB (inherited from
  ;; `magit-section-mode-map' as `magit-section-toggle') expands or
  ;; collapses individual rows; `magit-section-cache-visibility' set
  ;; in the mode init preserves state across the 5-second refresh.
  (let ((section
         (magit-insert-section (claude-dashboard-instance-section inst t)
           (magit-insert-heading
             (claude-dashboard--format-instance-line inst branch-w topic-w))
           (claude-dashboard--insert-instance-overview inst))))
    ;; The HIDE arg sets the slot but doesn't apply the invisibility
    ;; overlay; do that explicitly so the body actually starts folded.
    (when (and section (oref section hidden))
      (magit-section-hide section))))

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
             (branch-w (claude-dashboard--column-width
                        "BRANCH" branches
                        claude-dashboard-branch-max-width))
             ;; M G PROJECT(P) ST(3) UP(5) BRANCH(B) SESSION(8) ACT(24)  TOPIC
             (prefix-w (+ 1 1 1 1 claude-dashboard-project-max-width
                            1 3 1 5 1 branch-w 1 8 1 24 2))
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
   ("v"   "magit-status"    claude-dashboard-magit)]
  ["Marks"
   ("m"   "mark"            claude-dashboard-mark)
   ("u"   "unmark"          claude-dashboard-unmark)
   ("t"   "toggle marks"    claude-dashboard-toggle-marks)
   ("U"   "unmark all"      claude-dashboard-unmark-all)]
  ["Lifecycle (marked or row)"
   ("k"   "quit (row)"      claude-dashboard-quit-instance)
   ("K"   "kill buf (row)"  claude-dashboard-kill-buffer)
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
    ;; Lifecycle on the row at point
    (define-key map "k"         #'claude-dashboard-quit-instance)
    (define-key map "K"         #'claude-dashboard-kill-buffer)
    ;; `claude-dashboard-restart' deliberately has no keybinding —
    ;; restart spawns a fresh claude (no --resume), throwing away the
    ;; conversation context, which is rarely what you want when your
    ;; finger slips.  Reachable via `M-x' for the deliberate case.
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
;; Explicitly unbind `r' (was `claude-dashboard-restart') — restart
;; spawns a fresh claude with no `--resume', dropping the conversation,
;; which is too easy to do by accident with a single-letter binding.
;; Reachable via `M-x claude-dashboard-restart' for the deliberate case.
(define-key claude-dashboard-mode-map "r" nil)

(define-derived-mode claude-dashboard-mode magit-section-mode "ClaudeDash"
  "Major mode for the Claude Code instance dashboard."
  :group 'claude-dashboard
  (setq-local truncate-lines t)
  (setq buffer-read-only t)
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  ;; Each instance row is the heading of a magit section whose body
  ;; is the per-instance overview (latest TodoWrite snapshot).
  ;; Default-hide the bodies; TAB (inherited from `magit-section-mode-map'
  ;; as `magit-section-toggle') expands them.
  (setq-local magit-section-initial-visibility-alist
              '((claude-dashboard-instance-section . hide)
                (claude-dashboard-query-section    . hide)))
  ;; Cache fold state across the 5-second auto-refresh so expanded
  ;; rows don't snap shut on every render.  magit-section keys cached
  ;; visibility on the section's value (the instance struct is stable
  ;; across renders).
  (setq-local magit-section-cache-visibility t)
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
