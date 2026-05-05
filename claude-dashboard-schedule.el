;;; claude-dashboard-schedule.el --- Schedule timed sends and launches -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1") (claude-dashboard "0.1"))

;;; Commentary:
;;
;; Adds a "schedule" facility to claude-dashboard with two kinds of
;; pending action:
;;
;;   1. Scheduled SEND  — queue (instance, message, time).  At fire
;;      time, deliver MESSAGE to the live INSTANCE via its eat PTY.
;;
;;   2. Scheduled LAUNCH — queue (cwd, extra-args, optional initial
;;      message, time).  At fire time, run claude in CWD (cold launch,
;;      `--resume <sid>', or fresh worktree) and optionally seed it
;;      with an initial prompt once the new eat process is settled.
;;
;; Both kinds persist across emacs restarts.  Sends live in
;; `claude-dashboard-pending-sends-file', launches in
;; `claude-dashboard-pending-launches-file' (both default to ~/.claude/).
;;
;; Optional RENAME-NAME on either struct sends `/rename <name>' to the
;; target session before the message body — useful for stamping a
;; stable, searchable name onto a freshly-launched session before any
;; conversation starts (otherwise the package's auto-name would derive
;; a slug from the first prompt five turns in).  The rename injection
;; defends against Claude's slash-command picker / autocomplete by
;; sending ESC + C-u beforehand and using the split-write submit
;; pattern (body, sit-for, lone CR) — see the comment in
;; `claude-dashboard--inject-rename'.
;;
;; Target resolution (`claude-dashboard--find-instance-by-sid-or-cwd')
;; prefers SID, falling back to YOUNGEST live instance in the matching
;; CWD when SID is nil/unmatched.  The youngest-first rule fixes a bug
;; where launch followups (whose enqueue-time SID is nil because claude
;; hasn't written its transcript yet) would land on an older sibling
;; instance in the same cwd.  Buffer names are intentionally not match
;; keys: the package renames buffers on `/name' / `/rename', so a name
;; captured at enqueue may not match the same instance at fire time.
;;
;; Entry points:
;;   M-x claude-dashboard-schedule-send             (S in dashboard)
;;   M-x claude-dashboard-schedule-launch           (J in dashboard)
;;   M-x claude-dashboard-schedule-launch-worktree
;;   M-x claude-dashboard-schedule-resume
;;   M-x claude-dashboard-list-pending-sends        (L in dashboard)
;;   M-x claude-dashboard-resume-pending-sends      (call after restart)
;;   M-x claude-dashboard-schedule-self-test        (validate the pipeline)

;;; Code:

(require 'cl-lib)
(require 'claude-dashboard)
(require 'tabulated-list)

;;; --- Customs ---------------------------------------------------------------

(defcustom claude-dashboard-pending-sends-file
  (expand-file-name "dashboard-pending-sends.el" claude-dashboard-claude-dir)
  "Where queued scheduled sends are persisted.
Set to nil to disable persistence (in-memory only, lost on restart)."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'claude-dashboard)

(defcustom claude-dashboard-pending-launches-file
  (expand-file-name "dashboard-pending-launches.el" claude-dashboard-claude-dir)
  "Where queued scheduled launches are persisted."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'claude-dashboard)

(defcustom claude-dashboard-pending-send-defer-when-busy 5
  "Seconds to defer a fired send when the target instance is busy."
  :type 'number :group 'claude-dashboard)

(defcustom claude-dashboard-pending-send-no-target-retry 30
  "Seconds to defer when a fired send has no matching live instance."
  :type 'number :group 'claude-dashboard)

(defcustom claude-dashboard-pending-launch-followup-delay 8
  "Seconds after a scheduled launch to fire its initial-message follow-up.
The new eat process needs a moment to register and claude needs to come
up to its prompt.  Increase if your machine is slow or the model takes
a long time to greet.  Ignored when the launch has no initial message."
  :type 'number :group 'claude-dashboard)

;;; --- Data ------------------------------------------------------------------

(cl-defstruct claude-dashboard-pending-send
  ;; RENAME-NAME, when non-nil, is sent as `/rename <name>' BEFORE the
  ;; message body and submit.  Applied via the same split-write submit
  ;; pattern, with an extra ESC + C-u beforehand to dismiss any open
  ;; slash-command picker (autocomplete:dismiss is bound to ESC in
  ;; Claude Code's input layer).  After the rename, the package's
  ;; auto-name suppression flag is set on the buffer so a subsequent
  ;; auto-name can't overwrite the explicit name we just set.
  id cwd sid message scheduled created timer rename-name)

(cl-defstruct claude-dashboard-pending-launch
  ;; KIND is :plain (cold launch / --resume / arbitrary extra-args)
  ;; or :worktree (create a new git worktree first, then launch in it).
  ;; For :plain, CWD is where claude runs and EXTRA-ARGS is the arg list.
  ;; For :worktree, CWD is the source repo and BRANCH names the new
  ;; worktree; the actual launch dir is derived at fire time.
  ;; RENAME-NAME, when non-nil, is propagated onto the followup
  ;; pending-send (constructed at launch fire time) so the rename
  ;; lands together with the initial message.
  id kind cwd extra-args branch initial-message scheduled created timer
  rename-name)

(defvar claude-dashboard--pending-sends (make-hash-table :test 'equal)
  "id (string) → `claude-dashboard-pending-send'.")

(defvar claude-dashboard--pending-launches (make-hash-table :test 'equal)
  "id (string) → `claude-dashboard-pending-launch'.")

(defvar claude-dashboard--pending-restored nil
  "Non-nil once `claude-dashboard-resume-pending-sends' has run this session.")

;;; --- Time parsing ----------------------------------------------------------

(defun claude-dashboard--parse-time-spec (spec)
  "Parse SPEC into an encoded absolute time.
Accepts:
  +Ns / +Nm / +Nh / +Nd       — relative offset from now
  HH:MM                        — today; rolls to tomorrow if already past
  YYYY-MM-DD HH:MM[:SS]        — absolute, local timezone
  <YYYY-MM-DD HH:MM[:SS]>      — org-style timestamp; brackets stripped
Signal `user-error' on parse failure."
  (let ((s (string-trim spec)))
    (cond
     ((and (string-prefix-p "<" s) (string-suffix-p ">" s))
      (claude-dashboard--parse-time-spec (substring s 1 -1)))
     ((string-match "\\`\\+\\([0-9]+\\)\\([smhd]\\)\\'" s)
      (let* ((n (string-to-number (match-string 1 s)))
             (unit (match-string 2 s))
             (sec (* n (pcase unit
                         ("s" 1) ("m" 60) ("h" 3600) ("d" 86400)))))
        (time-add (current-time) (seconds-to-time sec))))
     ((string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
      (let* ((h (string-to-number (match-string 1 s)))
             (m (string-to-number (match-string 2 s)))
             (now (current-time))
             (decoded (decode-time now))
             ;; Numeric ZONE short-circuits DST handling — safe today.
             (target (encode-time
                      (list 0 m h
                            (decoded-time-day decoded)
                            (decoded-time-month decoded)
                            (decoded-time-year decoded)
                            nil nil
                            (decoded-time-zone decoded)))))
        (if (time-less-p target now)
            (time-add target (seconds-to-time 86400))
          target)))
     ((string-match
       "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)[ T]\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?\\'"
       s)
      ;; DST=-1 lets encode-time pick the correct offset for the date;
      ;; DST=nil would force "not in DST" and shift in-DST dates.
      (encode-time (list (string-to-number (or (match-string 6 s) "0"))
                         (string-to-number (match-string 5 s))
                         (string-to-number (match-string 4 s))
                         (string-to-number (match-string 3 s))
                         (string-to-number (match-string 2 s))
                         (string-to-number (match-string 1 s))
                         nil -1 nil)))
     (t (user-error
         "Cannot parse time spec: %S (try +5m, 14:30, or 2026-05-02 14:30)"
         spec)))))

(defun claude-dashboard--format-when (encoded-time)
  "Format ENCODED-TIME as `today HH:MM' or `YYYY-MM-DD HH:MM'."
  (let* ((now-day (time-to-days (current-time)))
         (then-day (time-to-days encoded-time)))
    (if (= now-day then-day)
        (format-time-string "today %H:%M" encoded-time)
      (format-time-string "%Y-%m-%d %H:%M" encoded-time))))

;;; --- Persistence ----------------------------------------------------------

(defun claude-dashboard--write-lisp-data (path entries)
  "Write ENTRIES (a list of plists) to PATH as a lisp-data file."
  (when path
    (let ((dir (file-name-directory path)))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)))
    (with-temp-file path
      (insert ";;; -*- lisp-data -*-\n")
      (let ((print-level nil) (print-length nil))
        (prin1 entries (current-buffer)))
      (insert "\n"))))

(defun claude-dashboard--read-lisp-data (path)
  "Return the list persisted at PATH, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (ignore-errors (read (current-buffer))))))

(defun claude-dashboard--write-pending-sends ()
  "Persist the pending-sends table."
  (claude-dashboard--write-lisp-data
   claude-dashboard-pending-sends-file
   (cl-loop for p being the hash-values of claude-dashboard--pending-sends
            collect (list :id (claude-dashboard-pending-send-id p)
                          :cwd (claude-dashboard-pending-send-cwd p)
                          :sid (claude-dashboard-pending-send-sid p)
                          :message (claude-dashboard-pending-send-message p)
                          :rename-name (claude-dashboard-pending-send-rename-name p)
                          :scheduled (claude-dashboard-pending-send-scheduled p)
                          :created (claude-dashboard-pending-send-created p)))))

(defun claude-dashboard--write-pending-launches ()
  "Persist the pending-launches table."
  (claude-dashboard--write-lisp-data
   claude-dashboard-pending-launches-file
   (cl-loop for p being the hash-values of claude-dashboard--pending-launches
            collect (list :id (claude-dashboard-pending-launch-id p)
                          :kind (claude-dashboard-pending-launch-kind p)
                          :cwd (claude-dashboard-pending-launch-cwd p)
                          :extra-args (claude-dashboard-pending-launch-extra-args p)
                          :branch (claude-dashboard-pending-launch-branch p)
                          :initial-message
                          (claude-dashboard-pending-launch-initial-message p)
                          :rename-name
                          (claude-dashboard-pending-launch-rename-name p)
                          :scheduled (claude-dashboard-pending-launch-scheduled p)
                          :created (claude-dashboard-pending-launch-created p)))))

;;; --- Target resolution -----------------------------------------------------

(defun claude-dashboard--find-instance-by-sid-or-cwd (sid cwd)
  "Return the live instance matching SID; fall back to youngest-in-CWD.

SID is the canonical identifier — when present and matched, that's
the answer.  `claude-dashboard--live-session-id' is preferred over
the cached struct field because the live PID-json is updated by
claude immediately on session write while the struct field is only
filled in on the next refresh.

When SID is nil or unmatched, fall back to the YOUNGEST live
instance whose cwd equals CWD (sorted by `started-at' descending).
The youngest-first rule is what makes launch followups land on the
just-launched session even when an older sibling shares the cwd —
e.g. you scheduled a fresh launch in `~/projects/foo' and an older
`~/projects/foo' instance is still hanging around.

Buffer names are intentionally not match keys: the package renames
buffers on `/name', so a name captured at enqueue may not match the
same instance at fire time."
  (let ((cwd-canon (and cwd (expand-file-name cwd))))
    (or
     ;; Definitive: sid match.
     (and sid
          (cl-find-if
           (lambda (inst)
             (or (equal sid (claude-dashboard-instance-session-id inst))
                 (and (fboundp 'claude-dashboard--live-session-id)
                      (equal sid (claude-dashboard--live-session-id inst)))))
           (claude-dashboard--instances-list)))
     ;; Fallback: youngest live instance whose cwd matches.
     (and cwd-canon
          (let ((candidates
                 (cl-remove-if-not
                  (lambda (inst)
                    (let ((c (claude-dashboard-instance-cwd inst)))
                      (and c (equal cwd-canon (expand-file-name c)))))
                  (claude-dashboard--instances-list))))
            (when candidates
              ;; Sort youngest-first by started-at; copy first because
              ;; sort is destructive on its argument.
              (car (sort (copy-sequence candidates)
                         (lambda (a b)
                           (time-less-p
                            (claude-dashboard-instance-started-at b)
                            (claude-dashboard-instance-started-at a)))))))))))

(defun claude-dashboard--instance-completion-table ()
  "Return a (display-string . instance) alist for completing-read."
  (cl-loop for inst in (claude-dashboard--instances-list)
           for topic = (or (ignore-errors
                             (claude-dashboard--instance-topic inst))
                           "—")
           for cwd = (claude-dashboard-instance-cwd inst)
           for label = (format "%-30s  %s"
                               (if (string= topic "—")
                                   (buffer-name
                                    (claude-dashboard-instance-buffer inst))
                                 topic)
                               (abbreviate-file-name (or cwd "")))
           collect (cons label inst)))

;;; --- Delivery: sends -------------------------------------------------------

(defun claude-dashboard--deliver-pending (id)
  "Deliver the pending send identified by ID, or re-arm if not yet possible."
  (let ((p (gethash id claude-dashboard--pending-sends)))
    (when p
      (let* ((inst (claude-dashboard--find-instance-by-sid-or-cwd
                    (claude-dashboard-pending-send-sid p)
                    (claude-dashboard-pending-send-cwd p)))
             (proc (and inst (claude-dashboard--instance-process inst)))
             (status (and inst
                          (ignore-errors (claude-dashboard--status inst)))))
        (cond
         ((or (null inst) (null proc) (not (process-live-p proc)))
          (setf (claude-dashboard-pending-send-timer p)
                (run-at-time
                 claude-dashboard-pending-send-no-target-retry nil
                 #'claude-dashboard--deliver-pending id))
          (message
           "claude-dashboard: pending send %s — no live target for %s; retry in %ds"
           (substring id 0 (min 8 (length id)))
           (or (claude-dashboard-pending-send-cwd p) "?")
           claude-dashboard-pending-send-no-target-retry))
         ((and status (not (eq status 'idle)))
          (setf (claude-dashboard-pending-send-timer p)
                (run-at-time
                 claude-dashboard-pending-send-defer-when-busy nil
                 #'claude-dashboard--deliver-pending id))
          (message "claude-dashboard: %s busy; deferring scheduled send %ds"
                   (buffer-name (claude-dashboard-instance-buffer inst))
                   claude-dashboard-pending-send-defer-when-busy))
         ;; Send it.  Claude Code's TUI batches a single PTY read into
         ;; one logical input event — "text\r" or "text\n" arrive as one
         ;; chunk and get treated as typed text with embedded CR/LF, NOT
         ;; as Enter.  To trigger submission we send the body first,
         ;; give Claude a moment to consume that read, then send a lone
         ;; CR in a separate PTY write.  Empirically ~50ms is enough.
         (t
          ;; If a rename was attached to the send, do that first so the
          ;; session's name is set before the user-visible message
          ;; lands.  Mark the buffer as `name-injected' afterwards so
          ;; the package's auto-name pass can't overwrite our explicit
          ;; choice 5 turns later.
          (when-let ((rn (claude-dashboard-pending-send-rename-name p)))
            (when (and (stringp rn) (not (string-empty-p (string-trim rn))))
              (claude-dashboard--inject-rename proc rn)
              (when (boundp 'claude-dashboard--name-injected)
                (puthash (claude-dashboard-instance-buffer inst)
                         t claude-dashboard--name-injected))))
          (process-send-string
           proc (claude-dashboard-pending-send-message p))
          (sit-for 0.05)
          (process-send-string proc "\r")
          (remhash id claude-dashboard--pending-sends)
          (claude-dashboard--write-pending-sends)
          (message "claude-dashboard: delivered scheduled send to %s"
                   (buffer-name (claude-dashboard-instance-buffer inst)))))))))

(defun claude-dashboard--inject-rename (proc rename-name)
  "Send `/rename RENAME-NAME' through PROC and submit.

Defends against Claude's slash-command picker / autocomplete:

  - ESC first (autocomplete:dismiss in Claude's input bindings) clears
    any picker that might be open from prior input.
  - `C-u' clears any leftover input on the line.
  - The slash command is then sent as a single complete token —
    Claude's slash parser matches `/rename' as a complete command
    rather than triggering the prefix picker that would fire on `/r'.
  - The submit `\\r' is a separate PTY write so Claude's input layer
    treats it as Enter (not as embedded CR in input — see split-write
    note in the deliver function).
  - A 0.5s wait at the end gives the rename time to land in the
    PID-json `name' field so subsequent reads of the live name see
    the new value."
  (when (and proc (process-live-p proc))
    (process-send-string proc "\e")          ; dismiss picker / autocomplete
    (sit-for 0.1)
    (process-send-string proc "\C-u")        ; clear input line
    (sit-for 0.05)
    (process-send-string proc (format "/rename %s" rename-name))
    (sit-for 0.05)
    (process-send-string proc "\r")          ; submit
    (sit-for 0.5)))                          ; let the rename land

;;; --- Delivery: launches ---------------------------------------------------

(defun claude-dashboard--deliver-pending-launch (id)
  "Deliver the pending launch identified by ID."
  (let ((p (gethash id claude-dashboard--pending-launches)))
    (when p
      (condition-case err
          (let ((cwd-of-launched
                 (pcase (claude-dashboard-pending-launch-kind p)
                   (:plain
                    (claude-dashboard--launch
                     (claude-dashboard-pending-launch-cwd p)
                     (claude-dashboard-pending-launch-extra-args p))
                    (claude-dashboard-pending-launch-cwd p))
                   (:worktree
                    ;; Delegate to the package's worktree command.  It does
                    ;; the git worktree add + launch + auto-/name plumbing.
                    (claude-dashboard-new-worktree
                     (claude-dashboard-pending-launch-cwd p)
                     (claude-dashboard-pending-launch-branch p))
                    ;; The launched instance lives at <main>/.claude/worktrees/<branch>.
                    (claude-dashboard--worktree-target-dir
                     (claude-dashboard--main-worktree
                      (claude-dashboard-pending-launch-cwd p))
                     (claude-dashboard-pending-launch-branch p)))
                   (k (error "Unknown launch kind: %S" k)))))
            ;; Optional follow-up: schedule the initial message to fire once
            ;; claude has had a moment to come up.  Reuses the send pipeline,
            ;; including its busy/idle defer logic.
            (when-let ((msg (claude-dashboard-pending-launch-initial-message p)))
              (when (and (stringp msg) (not (string-empty-p (string-trim msg))))
                (let* ((send-id (claude-dashboard--make-id))
                       (send (make-claude-dashboard-pending-send
                              :id send-id
                              :cwd (and cwd-of-launched
                                        (expand-file-name cwd-of-launched))
                              :sid nil ; not known yet
                              :message msg
                              :rename-name
                              (claude-dashboard-pending-launch-rename-name p)
                              :scheduled
                              (time-add (current-time)
                                        (seconds-to-time
                                         claude-dashboard-pending-launch-followup-delay))
                              :created (current-time))))
                  (setf (claude-dashboard-pending-send-timer send)
                        (run-at-time
                         claude-dashboard-pending-launch-followup-delay nil
                         #'claude-dashboard--deliver-pending send-id))
                  (puthash send-id send claude-dashboard--pending-sends)
                  (claude-dashboard--write-pending-sends))))
            (remhash id claude-dashboard--pending-launches)
            (claude-dashboard--write-pending-launches)
            (message "claude-dashboard: delivered scheduled launch (%s) for %s"
                     (claude-dashboard-pending-launch-kind p)
                     (or cwd-of-launched "?")))
        (error
         (message "claude-dashboard: scheduled launch %s failed: %S"
                  (substring id 0 (min 8 (length id)))
                  err))))))

;;; --- Public commands -------------------------------------------------------

(defun claude-dashboard--make-id ()
  "Return a fresh string id."
  (format "%s-%05d" (format-time-string "%s") (random 100000)))

(defun claude-dashboard--read-when-spec (&optional prompt)
  "Prompt for a time spec and return parsed encoded-time."
  (claude-dashboard--parse-time-spec
   (read-string (or prompt
                    "When (e.g. +5m, 14:30, 2026-05-02 14:30): "))))

;;;###autoload
(defun claude-dashboard-schedule-send (instance message when-spec
                                                &optional rename-name)
  "Schedule MESSAGE to be sent to INSTANCE at WHEN-SPEC.
WHEN-SPEC is parsed by `claude-dashboard--parse-time-spec'.

When RENAME-NAME is non-nil, the deliver function sends
`/rename RENAME-NAME' to the target session before the message body
and marks the buffer as name-injected so the package's auto-name
pass won't overwrite the choice later.

Interactively, prompts for instance, message, time, and an optional
rename (empty answer = no rename).  Default target is the dashboard
instance at point, when invoked from the dashboard buffer."
  (interactive
   (let* ((insts (claude-dashboard--instances-list))
          (_ (when (null insts) (user-error "No live claude instances")))
          (default-inst (and (derived-mode-p 'claude-dashboard-mode)
                             (ignore-errors
                               (claude-dashboard--current-instance))))
          (table (claude-dashboard--instance-completion-table))
          (default-label
           (and default-inst
                (car (cl-find default-inst table :key #'cdr))))
          (chosen (completing-read
                   "Send to instance: "
                   (mapcar #'car table)
                   nil t nil nil default-label))
          (inst (cdr (assoc chosen table)))
          (msg (read-string "Message: "))
          (when-spec (read-string
                      "When (e.g. +5m, 14:30, 2026-05-02 14:30): "))
          (rn-raw (read-string "Rename session to (empty = no rename): "))
          (rn (and (not (string-empty-p (string-trim rn-raw))) rn-raw)))
     (list inst msg when-spec rn)))
  (when (string-empty-p (string-trim message))
    (user-error "Empty message"))
  (let* ((target-time (claude-dashboard--parse-time-spec when-spec))
         (id (claude-dashboard--make-id))
         (p (make-claude-dashboard-pending-send
             :id id
             :cwd (and (claude-dashboard-instance-cwd instance)
                       (expand-file-name
                        (claude-dashboard-instance-cwd instance)))
             :sid (or (and (fboundp 'claude-dashboard--live-session-id)
                           (claude-dashboard--live-session-id instance))
                      (claude-dashboard-instance-session-id instance))
             :message message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (claude-dashboard-pending-send-timer p)
          (run-at-time target-time nil
                       #'claude-dashboard--deliver-pending id))
    (puthash id p claude-dashboard--pending-sends)
    (claude-dashboard--write-pending-sends)
    (message "claude-dashboard: scheduled send to %s at %s (id %s)"
             (buffer-name (claude-dashboard-instance-buffer instance))
             (claude-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun claude-dashboard-schedule-launch (cwd when-spec
                                             &optional initial-message
                                             extra-args rename-name)
  "Schedule a fresh `claude' launch in CWD at WHEN-SPEC.
Optional INITIAL-MESSAGE is sent to the new instance about
`claude-dashboard-pending-launch-followup-delay' seconds after the
launch fires (long enough for claude to reach its prompt).
Optional EXTRA-ARGS are passed through to `claude'.

When RENAME-NAME is non-nil, `/rename RENAME-NAME' is sent right
before the initial message lands.  Useful for giving the freshly-
launched session a stable, searchable name from the start instead
of letting the package's auto-name derive a slug from the prompt
five turns in.

Interactively, prompts for CWD, WHEN, optional message, and an
optional rename (empty answer = no rename)."
  (interactive
   (let* ((cwd (claude-dashboard--read-project))
          (when-spec
           (read-string "When (e.g. +5m, 14:30, 2026-05-02 14:30): "))
          (msg (read-string "Initial message (empty = none): "))
          (rn-raw (read-string "Rename session to (empty = no rename): "))
          (rn (and (not (string-empty-p (string-trim rn-raw))) rn-raw)))
     (list cwd when-spec
           (and (not (string-empty-p (string-trim msg))) msg)
           nil
           rn)))
  (let* ((target-time (claude-dashboard--parse-time-spec when-spec))
         (id (claude-dashboard--make-id))
         (p (make-claude-dashboard-pending-launch
             :id id :kind :plain
             :cwd (expand-file-name cwd)
             :extra-args extra-args
             :initial-message initial-message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (claude-dashboard-pending-launch-timer p)
          (run-at-time target-time nil
                       #'claude-dashboard--deliver-pending-launch id))
    (puthash id p claude-dashboard--pending-launches)
    (claude-dashboard--write-pending-launches)
    (message "claude-dashboard: scheduled launch in %s at %s (id %s)"
             (abbreviate-file-name cwd)
             (claude-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun claude-dashboard-schedule-resume (cwd sid when-spec
                                             &optional initial-message
                                             rename-name)
  "Schedule `claude --resume SID' in CWD at WHEN-SPEC.
Equivalent to `claude-dashboard-schedule-launch' with
EXTRA-ARGS = (\"--resume\" SID).  INITIAL-MESSAGE and RENAME-NAME
are forwarded to the launch."
  (interactive
   (list (claude-dashboard--read-project)
         (read-string "Session id (sid) to resume: ")
         (read-string "When: ")
         (let ((m (read-string "Initial message (empty = none): ")))
           (and (not (string-empty-p (string-trim m))) m))
         (let ((rn (read-string "Rename session to (empty = no rename): ")))
           (and (not (string-empty-p (string-trim rn))) rn))))
  (claude-dashboard-schedule-launch
   cwd when-spec initial-message (list "--resume" sid) rename-name))

;;;###autoload
(defun claude-dashboard-schedule-launch-worktree (source-cwd branch when-spec
                                                             &optional initial-message
                                                             rename-name)
  "Schedule a new git worktree on BRANCH under SOURCE-CWD's repo + claude launch.
At WHEN-SPEC we run the equivalent of `claude-dashboard-new-worktree
SOURCE-CWD BRANCH', which creates the worktree and starts claude in it.
INITIAL-MESSAGE, if non-empty, is delivered after the launch settles.
RENAME-NAME, if non-nil, is sent as `/rename RENAME-NAME' before the
initial message — useful since auto-named worktree slugs default to
the branch name; pass an explicit rename to override."
  (interactive
   (list (claude-dashboard--read-project)
         (read-string "Branch / worktree name: ")
         (read-string "When: ")
         (let ((m (read-string "Initial message (empty = none): ")))
           (and (not (string-empty-p (string-trim m))) m))
         (let ((rn (read-string "Rename session to (empty = no rename): ")))
           (and (not (string-empty-p (string-trim rn))) rn))))
  (when (or (null branch) (string-empty-p (string-trim branch)))
    (user-error "Branch name is required"))
  (let* ((target-time (claude-dashboard--parse-time-spec when-spec))
         (id (claude-dashboard--make-id))
         (p (make-claude-dashboard-pending-launch
             :id id :kind :worktree
             :cwd (expand-file-name source-cwd)
             :branch (string-trim branch)
             :initial-message initial-message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (claude-dashboard-pending-launch-timer p)
          (run-at-time target-time nil
                       #'claude-dashboard--deliver-pending-launch id))
    (puthash id p claude-dashboard--pending-launches)
    (claude-dashboard--write-pending-launches)
    (message "claude-dashboard: scheduled worktree launch %s @ %s at %s (id %s)"
             (claude-dashboard-pending-launch-branch p)
             (abbreviate-file-name source-cwd)
             (claude-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun claude-dashboard-cancel-pending-send (id)
  "Cancel the pending send with ID."
  (interactive
   (let ((cands (cl-loop for p being the hash-values
                         of claude-dashboard--pending-sends
                         collect (cons (format "%s  %s  %.40s"
                                               (claude-dashboard--format-when
                                                (claude-dashboard-pending-send-scheduled p))
                                               (or (claude-dashboard-pending-send-cwd p) "?")
                                               (claude-dashboard-pending-send-message p))
                                       (claude-dashboard-pending-send-id p)))))
     (when (null cands) (user-error "No pending sends"))
     (list (cdr (assoc (completing-read "Cancel: " (mapcar #'car cands) nil t)
                       cands)))))
  (let ((p (gethash id claude-dashboard--pending-sends)))
    (when (and p (claude-dashboard-pending-send-timer p))
      (cancel-timer (claude-dashboard-pending-send-timer p)))
    (remhash id claude-dashboard--pending-sends)
    (claude-dashboard--write-pending-sends)
    (message "claude-dashboard: cancelled %s"
             (substring id 0 (min 8 (length id))))))

;;;###autoload
(defun claude-dashboard-cancel-pending-launch (id)
  "Cancel the pending launch with ID."
  (interactive
   (let ((cands (cl-loop for p being the hash-values
                         of claude-dashboard--pending-launches
                         collect (cons (format "%s  %s  %s"
                                               (claude-dashboard--format-when
                                                (claude-dashboard-pending-launch-scheduled p))
                                               (claude-dashboard-pending-launch-kind p)
                                               (or (claude-dashboard-pending-launch-cwd p)
                                                   "?"))
                                       (claude-dashboard-pending-launch-id p)))))
     (when (null cands) (user-error "No pending launches"))
     (list (cdr (assoc (completing-read "Cancel: " (mapcar #'car cands) nil t)
                       cands)))))
  (let ((p (gethash id claude-dashboard--pending-launches)))
    (when (and p (claude-dashboard-pending-launch-timer p))
      (cancel-timer (claude-dashboard-pending-launch-timer p)))
    (remhash id claude-dashboard--pending-launches)
    (claude-dashboard--write-pending-launches)
    (message "claude-dashboard: cancelled launch %s"
             (substring id 0 (min 8 (length id))))))

;;;###autoload
(defun claude-dashboard-resume-pending-sends ()
  "Re-arm timers for all pending sends and launches persisted to disk.
Idempotent within an Emacs session.  Past-due entries fire immediately."
  (interactive)
  (cond
   (claude-dashboard--pending-restored
    (message "claude-dashboard: pending actions already restored"))
   (t
    (setq claude-dashboard--pending-restored t)
    (let ((now (current-time))
          (sends 0) (launches 0))
      ;; Sends
      (dolist (e (claude-dashboard--read-lisp-data
                  claude-dashboard-pending-sends-file))
        (let* ((id (plist-get e :id))
               (target (plist-get e :scheduled))
               (p (make-claude-dashboard-pending-send
                   :id id
                   :cwd (plist-get e :cwd)
                   :sid (plist-get e :sid)
                   :message (plist-get e :message)
                   :rename-name (plist-get e :rename-name)
                   :scheduled target
                   :created (plist-get e :created))))
          (puthash id p claude-dashboard--pending-sends)
          (setf (claude-dashboard-pending-send-timer p)
                (run-at-time (if (time-less-p target now) 0 target) nil
                             #'claude-dashboard--deliver-pending id))
          (cl-incf sends)))
      ;; Launches
      (dolist (e (claude-dashboard--read-lisp-data
                  claude-dashboard-pending-launches-file))
        (let* ((id (plist-get e :id))
               (target (plist-get e :scheduled))
               (p (make-claude-dashboard-pending-launch
                   :id id
                   :kind (plist-get e :kind)
                   :cwd (plist-get e :cwd)
                   :extra-args (plist-get e :extra-args)
                   :branch (plist-get e :branch)
                   :initial-message (plist-get e :initial-message)
                   :rename-name (plist-get e :rename-name)
                   :scheduled target
                   :created (plist-get e :created))))
          (puthash id p claude-dashboard--pending-launches)
          (setf (claude-dashboard-pending-launch-timer p)
                (run-at-time (if (time-less-p target now) 0 target) nil
                             #'claude-dashboard--deliver-pending-launch id))
          (cl-incf launches)))
      (message "claude-dashboard: restored %d pending send(s) and %d pending launch(es)"
               sends launches)))))

;;; --- List buffer (unified: sends + launches) -------------------------------

(defvar claude-dashboard-pending-sends-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "d" #'claude-dashboard-pending-sends-cancel-at-point)
    (define-key map "e" #'claude-dashboard-pending-sends-reschedule-at-point)
    (define-key map "v" #'claude-dashboard-pending-sends-view-at-point)
    (define-key map (kbd "RET") #'claude-dashboard-pending-sends-view-at-point)
    (define-key map "g" #'claude-dashboard-pending-sends-refresh)
    map)
  "Keymap for `claude-dashboard-pending-sends-mode'.")

(define-derived-mode claude-dashboard-pending-sends-mode tabulated-list-mode
  "ClaudePending"
  "Major mode listing scheduled claude-dashboard sends and launches."
  (setq tabulated-list-format
        [("When"    18 t)
         ("Type"     8 t)
         ("Target"  28 t)
         ("Detail"   0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "When" nil))
  (tabulated-list-init-header))

(defun claude-dashboard--row-for-send (p)
  "Build a tabulated-list row for pending-send P."
  (let* ((cwd (or (claude-dashboard-pending-send-cwd p) "?"))
         (inst (claude-dashboard--find-instance-by-sid-or-cwd
                (claude-dashboard-pending-send-sid p) cwd))
         (target (cond
                  (inst (buffer-name
                         (claude-dashboard-instance-buffer inst)))
                  (t (concat (file-name-nondirectory
                              (directory-file-name cwd))
                             " (offline)"))))
         (preview (let ((m (claude-dashboard-pending-send-message p)))
                    (truncate-string-to-width
                     (replace-regexp-in-string "\n" " ⏎ " m)
                     200 nil nil "…"))))
    (list (claude-dashboard-pending-send-id p)
          (vector (claude-dashboard--format-when
                   (claude-dashboard-pending-send-scheduled p))
                  "send" target preview))))

(defun claude-dashboard--row-for-launch (p)
  "Build a tabulated-list row for pending-launch P."
  (let* ((kind (claude-dashboard-pending-launch-kind p))
         (cwd (or (claude-dashboard-pending-launch-cwd p) "?"))
         (target (abbreviate-file-name cwd))
         (detail
          (pcase kind
            (:plain
             (let* ((args (claude-dashboard-pending-launch-extra-args p))
                    (msg (claude-dashboard-pending-launch-initial-message p))
                    (head (cond ((and args (member "--resume" args))
                                 (format "resume %s"
                                         (or (cadr (member "--resume" args)) "?")))
                                (args (format "args=%S" args))
                                (t "cold"))))
               (if msg (format "%s — %.60s" head msg) head)))
            (:worktree
             (format "worktree %s%s"
                     (claude-dashboard-pending-launch-branch p)
                     (if-let ((m (claude-dashboard-pending-launch-initial-message p)))
                         (format " — %.60s" m) "")))
            (_ (format "kind=%S" kind)))))
    (list (claude-dashboard-pending-launch-id p)
          (vector (claude-dashboard--format-when
                   (claude-dashboard-pending-launch-scheduled p))
                  (pcase kind (:plain "launch") (:worktree "wt-launch") (_ "?"))
                  target detail))))

(defun claude-dashboard-pending-sends-refresh ()
  "Repopulate the pending list from both in-memory tables."
  (interactive)
  (let ((entries
         (append
          (cl-loop for p being the hash-values of claude-dashboard--pending-sends
                   collect (claude-dashboard--row-for-send p))
          (cl-loop for p being the hash-values of claude-dashboard--pending-launches
                   collect (claude-dashboard--row-for-launch p)))))
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;###autoload
(defun claude-dashboard-list-pending-sends ()
  "Open a tabulated-list buffer of all pending scheduled sends and launches."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Pending Sends*")))
    (with-current-buffer buf
      (claude-dashboard-pending-sends-mode)
      (claude-dashboard-pending-sends-refresh))
    (pop-to-buffer buf)))

(defun claude-dashboard-pending-sends--id-at-point ()
  (or (tabulated-list-get-id)
      (user-error "No pending action on this line")))

(defun claude-dashboard--lookup-pending (id)
  "Return (KIND . STRUCT) for ID, where KIND is `send' or `launch'."
  (cond
   ((gethash id claude-dashboard--pending-sends)
    (cons 'send (gethash id claude-dashboard--pending-sends)))
   ((gethash id claude-dashboard--pending-launches)
    (cons 'launch (gethash id claude-dashboard--pending-launches)))
   (t nil)))

(defun claude-dashboard-pending-sends-cancel-at-point ()
  "Cancel the pending send or launch at point."
  (interactive)
  (let* ((id (claude-dashboard-pending-sends--id-at-point))
         (entry (claude-dashboard--lookup-pending id)))
    (unless entry (user-error "Entry no longer exists"))
    (pcase (car entry)
      ('send   (claude-dashboard-cancel-pending-send id))
      ('launch (claude-dashboard-cancel-pending-launch id)))
    (claude-dashboard-pending-sends-refresh)))

(defun claude-dashboard-pending-sends-reschedule-at-point ()
  "Re-prompt for a new time for the entry at point."
  (interactive)
  (let* ((id (claude-dashboard-pending-sends--id-at-point))
         (entry (claude-dashboard--lookup-pending id)))
    (unless entry (user-error "Entry no longer exists"))
    (pcase-let ((`(,kind . ,p) entry))
      (let* ((old-time (pcase kind
                         ('send   (claude-dashboard-pending-send-scheduled p))
                         ('launch (claude-dashboard-pending-launch-scheduled p))))
             (when-spec (read-string
                         (format "Reschedule (was %s): "
                                 (claude-dashboard--format-when old-time))))
             (new-time (claude-dashboard--parse-time-spec when-spec)))
        (pcase kind
          ('send
           (when (claude-dashboard-pending-send-timer p)
             (cancel-timer (claude-dashboard-pending-send-timer p)))
           (setf (claude-dashboard-pending-send-scheduled p) new-time
                 (claude-dashboard-pending-send-timer p)
                 (run-at-time new-time nil
                              #'claude-dashboard--deliver-pending id))
           (claude-dashboard--write-pending-sends))
          ('launch
           (when (claude-dashboard-pending-launch-timer p)
             (cancel-timer (claude-dashboard-pending-launch-timer p)))
           (setf (claude-dashboard-pending-launch-scheduled p) new-time
                 (claude-dashboard-pending-launch-timer p)
                 (run-at-time new-time nil
                              #'claude-dashboard--deliver-pending-launch id))
           (claude-dashboard--write-pending-launches)))
        (claude-dashboard-pending-sends-refresh)
        (message "claude-dashboard: rescheduled to %s"
                 (claude-dashboard--format-when new-time))))))

(defun claude-dashboard-pending-sends-view-at-point ()
  "Pop a buffer showing the full detail of the entry at point."
  (interactive)
  (let* ((id (claude-dashboard-pending-sends--id-at-point))
         (entry (claude-dashboard--lookup-pending id)))
    (unless entry (user-error "Entry no longer exists"))
    (let ((buf (get-buffer-create
                (format "*Claude Pending %s*"
                        (substring id 0 (min 8 (length id)))))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (pcase-let ((`(,kind . ,p) entry))
            (pcase kind
              ('send
               (insert (format "Kind:    send\n"))
               (insert (format "When:    %s\n"
                               (claude-dashboard--format-when
                                (claude-dashboard-pending-send-scheduled p))))
               (insert (format "Target:  %s (sid %s)\n"
                               (or (claude-dashboard-pending-send-cwd p) "?")
                               (or (claude-dashboard-pending-send-sid p) "—")))
               (insert (format "Created: %s\n\n"
                               (format-time-string
                                "%Y-%m-%d %H:%M:%S"
                                (claude-dashboard-pending-send-created p))))
               (insert (claude-dashboard-pending-send-message p)))
              ('launch
               (insert (format "Kind:        launch (%s)\n"
                               (claude-dashboard-pending-launch-kind p)))
               (insert (format "When:        %s\n"
                               (claude-dashboard--format-when
                                (claude-dashboard-pending-launch-scheduled p))))
               (insert (format "Cwd/source:  %s\n"
                               (or (claude-dashboard-pending-launch-cwd p) "?")))
               (when (eq (claude-dashboard-pending-launch-kind p) :worktree)
                 (insert (format "Branch:      %s\n"
                                 (claude-dashboard-pending-launch-branch p))))
               (when (claude-dashboard-pending-launch-extra-args p)
                 (insert (format "Extra args:  %S\n"
                                 (claude-dashboard-pending-launch-extra-args p))))
               (insert (format "Created:     %s\n\n"
                               (format-time-string
                                "%Y-%m-%d %H:%M:%S"
                                (claude-dashboard-pending-launch-created p))))
               (insert "Initial message:\n")
               (insert (or (claude-dashboard-pending-launch-initial-message p)
                           "  (none)\n"))))
            (goto-char (point-min))))
        (special-mode))
      (display-buffer buf))))

;;; --- Self-test (smoke test the full schedule + send pipeline) -------------

(defcustom claude-dashboard-schedule-self-test-cwd "/tmp/claude-schedule-selftest"
  "Disposable directory used by `claude-dashboard-schedule-self-test'.
Created if missing.  The directory is left in place after the test so
the spawned instance has a stable cwd; remove it manually if you don't
want it lingering."
  :type 'directory
  :group 'claude-dashboard)

(defcustom claude-dashboard-schedule-self-test-prompt
  "say hello world and nothing else"
  "Prompt sent to the disposable instance during the self-test.
Should be something that produces a deterministic, easy-to-verify
response — anything containing the literal `hello world' satisfies the
default success matcher."
  :type 'string
  :group 'claude-dashboard)

(defcustom claude-dashboard-schedule-self-test-success-regexp "hello world"
  "Regex matched against the disposable instance's buffer tail.
Match → the schedule + launch + initial-message + submit pipeline is
working end-to-end.  Customize alongside
`claude-dashboard-schedule-self-test-prompt' if you change one."
  :type 'regexp
  :group 'claude-dashboard)

;;;###autoload
(defun claude-dashboard-schedule-self-test (&optional keep)
  "End-to-end smoke test of the schedule pipeline.

Schedules a launch in `claude-dashboard-schedule-self-test-cwd' to
fire in 3 seconds, with
`claude-dashboard-schedule-self-test-prompt' as the initial message.
Waits for the launch + the followup-delay + a few seconds for the
agent's response, then matches
`claude-dashboard-schedule-self-test-success-regexp' against the
disposable instance's buffer tail.  Reports pass/fail in the echo
area and pops a results buffer for inspection.

The most common failure mode this catches is the split-write submit
regression — a single PTY write of \"<msg>\\n\" or \"<msg>\\r\"
fills the input box but doesn't submit, so the response never
arrives and the regex fails.  See the comment in
`claude-dashboard--deliver-pending' for the fix.

With prefix arg KEEP, leave the disposable instance running after
the test so you can inspect it manually.  Without KEEP, the
instance is killed and the cwd's `.claude/' subdir (if any) is left
in place."
  (interactive "P")
  (unless (file-directory-p claude-dashboard-schedule-self-test-cwd)
    (make-directory claude-dashboard-schedule-self-test-cwd t))
  (let* ((cwd claude-dashboard-schedule-self-test-cwd)
         ;; Total expected wall time:
         ;;   3s     — launch fire delay
         ;; + 8s     — claude-dashboard-pending-launch-followup-delay
         ;; + ~3s    — claude startup + a short response
         ;; + 2s     — slack
         (total-wait (+ 3 claude-dashboard-pending-launch-followup-delay 5))
         (launch-id (claude-dashboard-schedule-launch
                     cwd "+3s"
                     claude-dashboard-schedule-self-test-prompt
                     nil)))
    (message "claude-dashboard self-test: waiting %ds for full pipeline..."
             total-wait)
    (let ((deadline (time-add (current-time) (seconds-to-time total-wait)))
          (inst nil)
          (matched nil)
          (tail nil))
      ;; Poll for the instance to register (launch fires at +3s).
      (while (and (time-less-p (current-time) deadline)
                  (not (and inst matched)))
        (sit-for 1.0)
        (setq inst (cl-find-if
                    (lambda (i)
                      (equal (expand-file-name cwd)
                             (expand-file-name
                              (or (claude-dashboard-instance-cwd i) ""))))
                    (claude-dashboard--instances-list)))
        (when inst
          (with-current-buffer (claude-dashboard-instance-buffer inst)
            (setq tail (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 4000))
                        (point-max)))
            (setq matched
                  (and (string-match-p
                        claude-dashboard-schedule-self-test-success-regexp
                        tail)
                       ;; Also verify the prompt itself was submitted —
                       ;; "❯ <prompt>" appears in the conversation
                       ;; history (NOT just sitting in the input box).
                       (string-match-p
                        (regexp-quote claude-dashboard-schedule-self-test-prompt)
                        tail))))))
      ;; Build results.
      (let ((report
             (with-temp-buffer
               (insert (format "claude-dashboard-schedule self-test\n"))
               (insert (format "===================================\n\n"))
               (insert (format "Result:        %s\n" (if matched "PASS" "FAIL")))
               (insert (format "Launch id:     %s\n" launch-id))
               (insert (format "Cwd:           %s\n" cwd))
               (insert (format "Prompt:        %S\n"
                               claude-dashboard-schedule-self-test-prompt))
               (insert (format "Success regex: %S\n"
                               claude-dashboard-schedule-self-test-success-regexp))
               (insert (format "Instance:      %s\n"
                               (if inst
                                   (buffer-name
                                    (claude-dashboard-instance-buffer inst))
                                 "(never registered)")))
               (insert (format "Wall time:     %ds\n\n" total-wait))
               (insert "Buffer tail:\n\n")
               (insert (or tail "(no buffer tail captured)\n"))
               (buffer-string))))
        (with-current-buffer (get-buffer-create
                              "*claude-dashboard schedule self-test*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert report)
            (goto-char (point-min)))
          (special-mode)
          (display-buffer (current-buffer))))
      ;; Cleanup unless KEEP.
      (when (and inst (not keep))
        (let ((b (claude-dashboard-instance-buffer inst))
              (kill-buffer-query-functions nil))
          (when (buffer-live-p b) (kill-buffer b))))
      ;; Echo summary.
      (if matched
          (message "claude-dashboard self-test: PASS — pipeline working")
        (message "claude-dashboard self-test: FAIL — see *…self-test* buffer"))
      matched)))

;;; --- Dashboard integration -------------------------------------------------

(with-eval-after-load 'claude-dashboard
  (define-key claude-dashboard-mode-map "S" #'claude-dashboard-schedule-send)
  (define-key claude-dashboard-mode-map "J" #'claude-dashboard-schedule-launch)
  (define-key claude-dashboard-mode-map "L" #'claude-dashboard-list-pending-sends))

(provide 'claude-dashboard-schedule)
;;; claude-dashboard-schedule.el ends here
