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

;;; Data model

(cl-defstruct claude-dashboard-instance
  buffer cwd started-at last-output
  session-id model
  branch-cache worktree-cache last-prompt-cache)

(defvar claude-dashboard--instances (make-hash-table :test 'eq)
  "Map from eat buffer to `claude-dashboard-instance' struct.")

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

(defun claude-dashboard--status (inst)
  "Return a symbol summarizing INST's current state.
One of `running', `idle', or `exited'."
  (let ((proc (claude-dashboard--instance-process inst)))
    (cond
     ((not (and proc (process-live-p proc))) 'exited)
     ((let ((last (claude-dashboard-instance-last-output inst)))
        (and last (> (- (float-time) last)
                     claude-dashboard-idle-threshold)))
      'idle)
     (t 'running))))

(defun claude-dashboard--status-glyph (status)
  (pcase status
    ('running (propertize "●" 'face 'success))
    ('idle    (propertize "◐" 'face 'warning))
    ('exited  (propertize "○" 'face 'shadow))))

(defun claude-dashboard--humanize-duration (secs)
  "Format SECS as a short human-readable string (e.g. 12s, 3m, 2h)."
  (let ((s (truncate secs)))
    (cond ((< s 60)    (format "%ds" s))
          ((< s 3600)  (format "%dm" (/ s 60)))
          ((< s 86400) (format "%dh" (/ s 3600)))
          (t           (format "%dd" (/ s 86400))))))

(defun claude-dashboard--project-name (cwd)
  "Best-effort project name for CWD."
  (let ((p (project-current nil cwd)))
    (if p (project-name p)
      (file-name-nondirectory (directory-file-name cwd)))))

;;; Branch + last-prompt caching

(defun claude-dashboard--git-branch (cwd)
  "Return current git branch of CWD, or nil if not a git checkout."
  (when (file-directory-p cwd)
    (with-temp-buffer
      (let ((default-directory cwd))
        (when (zerop (process-file "git" nil t nil
                                   "symbolic-ref" "--short" "-q" "HEAD"))
          (string-trim (buffer-string)))))))

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
                (:prompt (claude-dashboard-instance-last-prompt-cache inst))))
         (now (float-time)))
    (if (and cur (< (- now (cdr cur)) claude-dashboard-cache-ttl))
        (car cur)
      (let* ((value (funcall fetcher))
             (entry (cons value now)))
        (pcase slot
          (:branch (setf (claude-dashboard-instance-branch-cache inst) entry))
          (:worktree (setf (claude-dashboard-instance-worktree-cache inst) entry))
          (:prompt (setf (claude-dashboard-instance-last-prompt-cache inst) entry)))
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
  "Encode CWD the way Claude names per-project session dirs."
  (concat "-" (replace-regexp-in-string "/" "-"
                                        (string-trim-left cwd "/"))))

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

(defun claude-dashboard--register (buffer cwd)
  "Insert BUFFER as an instance rooted at CWD into the registry."
  (let ((inst (make-claude-dashboard-instance
               :buffer buffer
               :cwd cwd
               :started-at (float-time)
               :last-output (float-time))))
    (puthash buffer inst claude-dashboard--instances)
    (with-current-buffer buffer
      (setq-local eat-kill-buffer-on-exit nil)
      (add-hook 'kill-buffer-hook #'claude-dashboard--on-buffer-killed nil t)
      (add-hook 'eat-update-hook #'claude-dashboard--note-activity nil t))
    (run-at-time 2 nil #'claude-dashboard--enrich-instance inst)
    inst))

(defun claude-dashboard--on-buffer-killed ()
  (remhash (current-buffer) claude-dashboard--instances)
  (claude-dashboard--maybe-refresh))

(defun claude-dashboard--launch (cwd extra-args)
  "Launch claude in CWD passing EXTRA-ARGS, register, refresh, and pop to buffer."
  (let* ((default-directory cwd)
         (name (claude-dashboard--unique-buffer-name cwd))
         (buf (get-buffer-create name))
         (args (append claude-dashboard-program-args extra-args)))
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

(defconst claude-dashboard--row-format
  "  %s %-20s %-7s %5s %5s  %-14s %-14s %-20s %-8s %5s  %s"
  "Format string used for both the column header and each instance row.
Columns: glyph, project, state, uptime, idle, branch, worktree, model,
session, status-age, last-prompt.")

(defun claude-dashboard--header-line ()
  "Return the column header line, faced as a section heading."
  (propertize
   (format claude-dashboard--row-format
           " " "PROJECT" "STATE" "UP" "IDLE" "BRANCH" "WORKTREE" "MODEL"
           "SESSION" "STATUS" "LAST PROMPT")
   'face 'magit-section-heading))

(defun claude-dashboard--format-instance-line (inst)
  "Return a formatted single-line summary for INST."
  (let* ((status (claude-dashboard--status inst))
         (glyph (claude-dashboard--status-glyph status))
         (proj (claude-dashboard--project-name
                (claude-dashboard-instance-cwd inst)))
         (uptime (claude-dashboard--humanize-duration
                  (- (float-time)
                     (claude-dashboard-instance-started-at inst))))
         (last-out (claude-dashboard-instance-last-output inst))
         (idle (and last-out
                    (claude-dashboard--humanize-duration
                     (- (float-time) last-out))))
         (branch (or (claude-dashboard--cached
                      :branch inst
                      (lambda ()
                        (claude-dashboard--git-branch
                         (claude-dashboard-instance-cwd inst))))
                     "—"))
         (worktree (or (claude-dashboard--cached
                        :worktree inst
                        (lambda ()
                          (claude-dashboard--worktree-name
                           (claude-dashboard-instance-cwd inst))))
                       "—"))
         (model (or (claude-dashboard-instance-model inst) "—"))
         (sid (or (and (claude-dashboard-instance-session-id inst)
                       (substring
                        (claude-dashboard-instance-session-id inst) 0 8))
                  "—"))
         (prompt (or (claude-dashboard--cached
                      :prompt inst
                      (lambda ()
                        (claude-dashboard--last-prompt-for
                         (claude-dashboard-instance-cwd inst))))
                     ""))
         (prompt-trunc (if (> (length prompt) 60)
                           (concat (substring prompt 0 57) "...")
                         prompt)))
    (format claude-dashboard--row-format
            glyph
            (truncate-string-to-width proj 20 nil ?\s "…")
            (symbol-name status)
            uptime
            (or idle "—")
            (truncate-string-to-width branch 14 nil ?\s "…")
            (truncate-string-to-width worktree 14 nil ?\s "…")
            (truncate-string-to-width model 20 nil ?\s "…")
            sid
            (claude-dashboard--status-snippet
             (claude-dashboard-instance-cwd inst))
            (propertize prompt-trunc 'face 'font-lock-comment-face))))

(defun claude-dashboard--insert-instance-section (inst)
  (magit-insert-section (claude-dashboard-instance-section inst)
    (insert (claude-dashboard--format-instance-line inst))
    (insert "\n")))

(defun claude-dashboard--insert-group (cwd insts)
  (magit-insert-section (claude-dashboard-group-section cwd)
    (magit-insert-heading
      (propertize (format "%s  (%d)"
                          (abbreviate-file-name cwd)
                          (length insts))
                  'face 'magit-section-heading))
    (insert (claude-dashboard--header-line) "\n")
    (dolist (inst insts)
      (claude-dashboard--insert-instance-section inst))))

(defun claude-dashboard--render ()
  "Replace the current buffer's contents with a fresh dashboard."
  (let ((inhibit-read-only t)
        (instances (claude-dashboard--instances-list)))
    (erase-buffer)
    (magit-insert-section (claude-dashboard-section)
      (magit-insert-heading
        (propertize (format "Claude instances (%d)" (length instances))
                    'face 'magit-section-heading))
      (if (null instances)
          (insert "  (no instances — press n to launch)\n")
        (let ((groups (make-hash-table :test 'equal)))
          (dolist (inst instances)
            (let ((cwd (claude-dashboard-instance-cwd inst)))
              (puthash cwd
                       (cons inst (gethash cwd groups))
                       groups)))
          (let (group-list)
            (maphash (lambda (cwd insts)
                       (push (cons cwd (nreverse insts)) group-list))
                     groups)
            (setq group-list
                  (sort group-list (lambda (a b) (string< (car a) (car b)))))
            (dolist (g group-list)
              (claude-dashboard--insert-group (car g) (cdr g)))))))))

(defun claude-dashboard--maybe-refresh ()
  "Re-render the dashboard if its buffer is live."
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
  ["Instance"
   ("RET" "visit"           claude-dashboard-visit)
   ("o"   "visit"           claude-dashboard-visit)
   ("O"   "display other"   claude-dashboard-display)
   ("d"   "dired cwd"       claude-dashboard-dired)
   ("m"   "magit-status"    claude-dashboard-magit)
   ("s"   "STATUS.md"       claude-dashboard-visit-status)]
  ["Lifecycle"
   ("k"   "quit (graceful)" claude-dashboard-quit-instance)
   ("K"   "kill buffer"     claude-dashboard-kill-buffer)
   ("r"   "restart"         claude-dashboard-restart)]
  ["Dashboard"
   ("n"   "new instance"    claude-dashboard-new)
   ("c"   "continue (cwd)"  claude-dashboard-continue)
   ("R"   "resume (picker)" claude-dashboard-resume)
   ("g"   "refresh"         claude-dashboard-refresh)
   ("q"   "quit window"     quit-window)])

;;; Mode

(defvar claude-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "RET") #'claude-dashboard-visit)
    (define-key map "o"         #'claude-dashboard-visit)
    (define-key map "O"         #'claude-dashboard-display)
    (define-key map "d"         #'claude-dashboard-dired)
    (define-key map "m"         #'claude-dashboard-magit)
    (define-key map "s"         #'claude-dashboard-visit-status)
    (define-key map "k"         #'claude-dashboard-quit-instance)
    (define-key map "K"         #'claude-dashboard-kill-buffer)
    (define-key map "r"         #'claude-dashboard-restart)
    (define-key map "n"         #'claude-dashboard-new)
    (define-key map "c"         #'claude-dashboard-continue)
    (define-key map "R"         #'claude-dashboard-resume)
    (define-key map "g"         #'claude-dashboard-refresh)
    (define-key map "?"         #'claude-dashboard-menu)
    map))

(define-derived-mode claude-dashboard-mode magit-section-mode "ClaudeDash"
  "Major mode for the Claude Code instance dashboard."
  :group 'claude-dashboard
  (setq-local truncate-lines t)
  (setq buffer-read-only t)
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

;;;###autoload
(defun claude-dashboard ()
  "Open the Claude Code dashboard."
  (interactive)
  (let ((buf (get-buffer-create claude-dashboard-buffer-name)))
    (with-current-buffer buf
      (claude-dashboard-mode)
      (claude-dashboard--render))
    (pop-to-buffer buf)))

(provide 'claude-dashboard)
;;; claude-dashboard.el ends here
