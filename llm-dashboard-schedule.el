;;; llm-dashboard-schedule.el --- Schedule timed sends and launches -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1") (llm-dashboard "0.2"))

;;; Commentary:
;;
;; Adds a "schedule" facility to llm-dashboard with two kinds of
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
;; `llm-dashboard-pending-sends-file', launches in
;; `llm-dashboard-pending-launches-file' (both default to ~/.claude/).
;;
;; Optional RENAME-NAME on either struct sends `/rename <name>' to the
;; target session before the message body — useful for stamping a
;; stable, searchable name onto a freshly-launched session before any
;; conversation starts (otherwise the package's auto-name would derive
;; a slug from the first prompt five turns in).  The rename injection
;; defends against Claude's slash-command picker / autocomplete by
;; sending ESC + C-u beforehand and using the split-write submit
;; pattern (body, sit-for, lone CR) — see the comment in
;; `llm-dashboard--inject-rename'.
;;
;; Target resolution (`llm-dashboard--find-instance-by-sid-or-cwd')
;; prefers SID, falling back to YOUNGEST live instance in the matching
;; CWD when SID is nil/unmatched.  The youngest-first rule fixes a bug
;; where launch followups (whose enqueue-time SID is nil because claude
;; hasn't written its transcript yet) would land on an older sibling
;; instance in the same cwd.  Buffer names are intentionally not match
;; keys: the package renames buffers on `/name' / `/rename', so a name
;; captured at enqueue may not match the same instance at fire time.
;;
;; Entry points:
;;   M-x llm-dashboard-schedule-send             (S in dashboard)
;;   M-x llm-dashboard-schedule-launch           (J in dashboard)
;;   M-x llm-dashboard-schedule-launch-worktree
;;   M-x llm-dashboard-schedule-resume
;;   M-x llm-dashboard-list-pending-sends        (L in dashboard)
;;   M-x llm-dashboard-resume-pending-sends      (call after restart)
;;   M-x llm-dashboard-schedule-self-test        (validate the pipeline)

;;; Code:

(require 'cl-lib)
(require 'llm-dashboard)
(require 'tabulated-list)

;;; --- Customs ---------------------------------------------------------------

(defcustom llm-dashboard-pending-sends-file
  (expand-file-name "dashboard-pending-sends.el" llm-dashboard-claude-dir)
  "Where queued scheduled sends are persisted.
Set to nil to disable persistence (in-memory only, lost on restart)."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'llm-dashboard)

(defcustom llm-dashboard-pending-launches-file
  (expand-file-name "dashboard-pending-launches.el" llm-dashboard-claude-dir)
  "Where queued scheduled launches are persisted."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'llm-dashboard)

(defcustom llm-dashboard-pending-send-defer-when-busy 5
  "Seconds to defer a fired send when the target instance is busy."
  :type 'number :group 'llm-dashboard)

(defcustom llm-dashboard-pending-send-no-target-retry 30
  "Seconds to defer when a fired send has no matching live instance."
  :type 'number :group 'llm-dashboard)

(defcustom llm-dashboard-pending-launch-followup-delay 8
  "Seconds after a scheduled launch to fire its initial-message follow-up.
The new eat process needs a moment to register and claude needs to come
up to its prompt.  Increase if your machine is slow or the model takes
a long time to greet.  Ignored when the launch has no initial message."
  :type 'number :group 'llm-dashboard)

;;; --- Data ------------------------------------------------------------------

(cl-defstruct llm-dashboard-pending-send
  ;; RENAME-NAME, when non-nil, is sent as `/rename <name>' BEFORE the
  ;; message body and submit.  Applied via the same split-write submit
  ;; pattern, with an extra ESC + C-u beforehand to dismiss any open
  ;; slash-command picker (autocomplete:dismiss is bound to ESC in
  ;; Claude Code's input layer).  After the rename, the package's
  ;; auto-name suppression flag is set on the buffer so a subsequent
  ;; auto-name can't overwrite the explicit name we just set.
  id cwd sid message scheduled created timer rename-name)

(cl-defstruct llm-dashboard-pending-launch
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

(defvar llm-dashboard--pending-sends (make-hash-table :test 'equal)
  "id (string) → `llm-dashboard-pending-send'.")

(defvar llm-dashboard--pending-launches (make-hash-table :test 'equal)
  "id (string) → `llm-dashboard-pending-launch'.")

(defvar llm-dashboard--pending-restored nil
  "Non-nil once `llm-dashboard-resume-pending-sends' has run this session.")

;;; --- Time parsing ----------------------------------------------------------

(defun llm-dashboard--parse-time-spec (spec)
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
      (llm-dashboard--parse-time-spec (substring s 1 -1)))
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

(defun llm-dashboard--format-when (encoded-time)
  "Format ENCODED-TIME as `today HH:MM' or `YYYY-MM-DD HH:MM'."
  (let* ((now-day (time-to-days (current-time)))
         (then-day (time-to-days encoded-time)))
    (if (= now-day then-day)
        (format-time-string "today %H:%M" encoded-time)
      (format-time-string "%Y-%m-%d %H:%M" encoded-time))))

;;; --- Persistence ----------------------------------------------------------

(defun llm-dashboard--write-lisp-data (path entries)
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

(defun llm-dashboard--read-lisp-data (path)
  "Return the list persisted at PATH, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (ignore-errors (read (current-buffer))))))

(defun llm-dashboard--write-pending-sends ()
  "Persist the pending-sends table."
  (llm-dashboard--write-lisp-data
   llm-dashboard-pending-sends-file
   (cl-loop for p being the hash-values of llm-dashboard--pending-sends
            collect (list :id (llm-dashboard-pending-send-id p)
                          :cwd (llm-dashboard-pending-send-cwd p)
                          :sid (llm-dashboard-pending-send-sid p)
                          :message (llm-dashboard-pending-send-message p)
                          :rename-name (llm-dashboard-pending-send-rename-name p)
                          :scheduled (llm-dashboard-pending-send-scheduled p)
                          :created (llm-dashboard-pending-send-created p)))))

(defun llm-dashboard--write-pending-launches ()
  "Persist the pending-launches table."
  (llm-dashboard--write-lisp-data
   llm-dashboard-pending-launches-file
   (cl-loop for p being the hash-values of llm-dashboard--pending-launches
            collect (list :id (llm-dashboard-pending-launch-id p)
                          :kind (llm-dashboard-pending-launch-kind p)
                          :cwd (llm-dashboard-pending-launch-cwd p)
                          :extra-args (llm-dashboard-pending-launch-extra-args p)
                          :branch (llm-dashboard-pending-launch-branch p)
                          :initial-message
                          (llm-dashboard-pending-launch-initial-message p)
                          :rename-name
                          (llm-dashboard-pending-launch-rename-name p)
                          :scheduled (llm-dashboard-pending-launch-scheduled p)
                          :created (llm-dashboard-pending-launch-created p)))))

;;; --- Target resolution -----------------------------------------------------

(defun llm-dashboard--find-instance-by-sid-or-cwd (sid cwd)
  "Return the live instance matching SID; fall back to youngest-in-CWD.

SID is the canonical identifier — when present and matched, that's
the answer.  `llm-dashboard--live-session-id' is preferred over
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
             (or (equal sid (llm-dashboard-instance-session-id inst))
                 (and (fboundp 'llm-dashboard--live-session-id)
                      (equal sid (llm-dashboard--live-session-id inst)))))
           (llm-dashboard--instances-list)))
     ;; Fallback: youngest live instance whose cwd matches.
     (and cwd-canon
          (let ((candidates
                 (cl-remove-if-not
                  (lambda (inst)
                    (let ((c (llm-dashboard-instance-cwd inst)))
                      (and c (equal cwd-canon (expand-file-name c)))))
                  (llm-dashboard--instances-list))))
            (when candidates
              ;; Sort youngest-first by started-at; copy first because
              ;; sort is destructive on its argument.
              (car (sort (copy-sequence candidates)
                         (lambda (a b)
                           (time-less-p
                            (llm-dashboard-instance-started-at b)
                            (llm-dashboard-instance-started-at a)))))))))))

(defun llm-dashboard--instance-completion-table ()
  "Return a (display-string . instance) alist for completing-read."
  (cl-loop for inst in (llm-dashboard--instances-list)
           for topic = (or (ignore-errors
                             (llm-dashboard--instance-topic inst))
                           "—")
           for cwd = (llm-dashboard-instance-cwd inst)
           for label = (format "%-30s  %s"
                               (if (string= topic "—")
                                   (buffer-name
                                    (llm-dashboard-instance-buffer inst))
                                 topic)
                               (abbreviate-file-name (or cwd "")))
           collect (cons label inst)))

;;; --- Delivery: sends -------------------------------------------------------

(defun llm-dashboard--deliver-pending (id)
  "Deliver the pending send identified by ID, or re-arm if not yet possible."
  (let ((p (gethash id llm-dashboard--pending-sends)))
    (when p
      (let* ((inst (llm-dashboard--find-instance-by-sid-or-cwd
                    (llm-dashboard-pending-send-sid p)
                    (llm-dashboard-pending-send-cwd p)))
             (proc (and inst (llm-dashboard--instance-process inst)))
             (status (and inst
                          (ignore-errors (llm-dashboard--status inst)))))
        (cond
         ((or (null inst) (null proc) (not (process-live-p proc)))
          (setf (llm-dashboard-pending-send-timer p)
                (run-at-time
                 llm-dashboard-pending-send-no-target-retry nil
                 #'llm-dashboard--deliver-pending id))
          (message
           "llm-dashboard: pending send %s — no live target for %s; retry in %ds"
           (substring id 0 (min 8 (length id)))
           (or (llm-dashboard-pending-send-cwd p) "?")
           llm-dashboard-pending-send-no-target-retry))
         ((and status (not (eq status 'idle)))
          (setf (llm-dashboard-pending-send-timer p)
                (run-at-time
                 llm-dashboard-pending-send-defer-when-busy nil
                 #'llm-dashboard--deliver-pending id))
          (message "llm-dashboard: %s busy; deferring scheduled send %ds"
                   (buffer-name (llm-dashboard-instance-buffer inst))
                   llm-dashboard-pending-send-defer-when-busy))
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
          (when-let ((rn (llm-dashboard-pending-send-rename-name p)))
            (when (and (stringp rn) (not (string-empty-p (string-trim rn))))
              (llm-dashboard--inject-rename proc rn)
              (when (boundp 'llm-dashboard--name-injected)
                (puthash (llm-dashboard-instance-buffer inst)
                         t llm-dashboard--name-injected))))
          (process-send-string
           proc (llm-dashboard-pending-send-message p))
          (sit-for 0.05)
          (process-send-string proc "\r")
          (remhash id llm-dashboard--pending-sends)
          (llm-dashboard--write-pending-sends)
          (message "llm-dashboard: delivered scheduled send to %s"
                   (buffer-name (llm-dashboard-instance-buffer inst)))))))))

(defun llm-dashboard--inject-rename (proc rename-name)
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

(defun llm-dashboard--deliver-pending-launch (id)
  "Deliver the pending launch identified by ID."
  (let ((p (gethash id llm-dashboard--pending-launches)))
    (when p
      (condition-case err
          (let ((cwd-of-launched
                 (pcase (llm-dashboard-pending-launch-kind p)
                   (:plain
                    (llm-dashboard--launch
                     (llm-dashboard-pending-launch-cwd p)
                     (llm-dashboard-pending-launch-extra-args p))
                    (llm-dashboard-pending-launch-cwd p))
                   (:worktree
                    ;; Delegate to the package's worktree command.  It does
                    ;; the git worktree add + launch + auto-/name plumbing.
                    (llm-dashboard-new-worktree
                     (llm-dashboard-pending-launch-cwd p)
                     (llm-dashboard-pending-launch-branch p))
                    ;; The launched instance lives at <main>/.claude/worktrees/<branch>.
                    (llm-dashboard--worktree-target-dir
                     (llm-dashboard--main-worktree
                      (llm-dashboard-pending-launch-cwd p))
                     (llm-dashboard-pending-launch-branch p)))
                   (k (error "Unknown launch kind: %S" k)))))
            ;; Optional follow-up: schedule the initial message to fire once
            ;; claude has had a moment to come up.  Reuses the send pipeline,
            ;; including its busy/idle defer logic.
            (when-let ((msg (llm-dashboard-pending-launch-initial-message p)))
              (when (and (stringp msg) (not (string-empty-p (string-trim msg))))
                (let* ((send-id (llm-dashboard--make-id))
                       (send (make-llm-dashboard-pending-send
                              :id send-id
                              :cwd (and cwd-of-launched
                                        (expand-file-name cwd-of-launched))
                              :sid nil ; not known yet
                              :message msg
                              :rename-name
                              (llm-dashboard-pending-launch-rename-name p)
                              :scheduled
                              (time-add (current-time)
                                        (seconds-to-time
                                         llm-dashboard-pending-launch-followup-delay))
                              :created (current-time))))
                  (setf (llm-dashboard-pending-send-timer send)
                        (run-at-time
                         llm-dashboard-pending-launch-followup-delay nil
                         #'llm-dashboard--deliver-pending send-id))
                  (puthash send-id send llm-dashboard--pending-sends)
                  (llm-dashboard--write-pending-sends))))
            (remhash id llm-dashboard--pending-launches)
            (llm-dashboard--write-pending-launches)
            (message "llm-dashboard: delivered scheduled launch (%s) for %s"
                     (llm-dashboard-pending-launch-kind p)
                     (or cwd-of-launched "?")))
        (error
         (message "llm-dashboard: scheduled launch %s failed: %S"
                  (substring id 0 (min 8 (length id)))
                  err))))))

;;; --- Public commands -------------------------------------------------------

(defun llm-dashboard--make-id ()
  "Return a fresh string id."
  (format "%s-%05d" (format-time-string "%s") (random 100000)))

(defun llm-dashboard--read-when-spec (&optional prompt)
  "Prompt for a time spec and return parsed encoded-time."
  (llm-dashboard--parse-time-spec
   (read-string (or prompt
                    "When (e.g. +5m, 14:30, 2026-05-02 14:30): "))))

;;;###autoload
(defun llm-dashboard-schedule-send (instance message when-spec
                                                &optional rename-name)
  "Schedule MESSAGE to be sent to INSTANCE at WHEN-SPEC.
WHEN-SPEC is parsed by `llm-dashboard--parse-time-spec'.

When RENAME-NAME is non-nil, the deliver function sends
`/rename RENAME-NAME' to the target session before the message body
and marks the buffer as name-injected so the package's auto-name
pass won't overwrite the choice later.

Interactively, prompts for instance, message, time, and an optional
rename (empty answer = no rename).  Default target is the dashboard
instance at point, when invoked from the dashboard buffer."
  (interactive
   (let* ((insts (llm-dashboard--instances-list))
          (_ (when (null insts) (user-error "No live claude instances")))
          (default-inst (and (derived-mode-p 'llm-dashboard-mode)
                             (ignore-errors
                               (llm-dashboard--current-instance))))
          (table (llm-dashboard--instance-completion-table))
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
  (let* ((target-time (llm-dashboard--parse-time-spec when-spec))
         (id (llm-dashboard--make-id))
         (p (make-llm-dashboard-pending-send
             :id id
             :cwd (and (llm-dashboard-instance-cwd instance)
                       (expand-file-name
                        (llm-dashboard-instance-cwd instance)))
             :sid (or (and (fboundp 'llm-dashboard--live-session-id)
                           (llm-dashboard--live-session-id instance))
                      (llm-dashboard-instance-session-id instance))
             :message message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (llm-dashboard-pending-send-timer p)
          (run-at-time target-time nil
                       #'llm-dashboard--deliver-pending id))
    (puthash id p llm-dashboard--pending-sends)
    (llm-dashboard--write-pending-sends)
    (message "llm-dashboard: scheduled send to %s at %s (id %s)"
             (buffer-name (llm-dashboard-instance-buffer instance))
             (llm-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun llm-dashboard-schedule-launch (cwd when-spec
                                             &optional initial-message
                                             extra-args rename-name)
  "Schedule a fresh `claude' launch in CWD at WHEN-SPEC.
Optional INITIAL-MESSAGE is sent to the new instance about
`llm-dashboard-pending-launch-followup-delay' seconds after the
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
   (let* ((cwd (llm-dashboard--read-project))
          (when-spec
           (read-string "When (e.g. +5m, 14:30, 2026-05-02 14:30): "))
          (msg (read-string "Initial message (empty = none): "))
          (rn-raw (read-string "Rename session to (empty = no rename): "))
          (rn (and (not (string-empty-p (string-trim rn-raw))) rn-raw)))
     (list cwd when-spec
           (and (not (string-empty-p (string-trim msg))) msg)
           nil
           rn)))
  (let* ((target-time (llm-dashboard--parse-time-spec when-spec))
         (id (llm-dashboard--make-id))
         (p (make-llm-dashboard-pending-launch
             :id id :kind :plain
             :cwd (expand-file-name cwd)
             :extra-args extra-args
             :initial-message initial-message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (llm-dashboard-pending-launch-timer p)
          (run-at-time target-time nil
                       #'llm-dashboard--deliver-pending-launch id))
    (puthash id p llm-dashboard--pending-launches)
    (llm-dashboard--write-pending-launches)
    (message "llm-dashboard: scheduled launch in %s at %s (id %s)"
             (abbreviate-file-name cwd)
             (llm-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun llm-dashboard-schedule-resume (cwd sid when-spec
                                             &optional initial-message
                                             rename-name)
  "Schedule `claude --resume SID' in CWD at WHEN-SPEC.
Equivalent to `llm-dashboard-schedule-launch' with
EXTRA-ARGS = (\"--resume\" SID).  INITIAL-MESSAGE and RENAME-NAME
are forwarded to the launch."
  (interactive
   (list (llm-dashboard--read-project)
         (read-string "Session id (sid) to resume: ")
         (read-string "When: ")
         (let ((m (read-string "Initial message (empty = none): ")))
           (and (not (string-empty-p (string-trim m))) m))
         (let ((rn (read-string "Rename session to (empty = no rename): ")))
           (and (not (string-empty-p (string-trim rn))) rn))))
  (llm-dashboard-schedule-launch
   cwd when-spec initial-message (list "--resume" sid) rename-name))

;;;###autoload
(defun llm-dashboard-schedule-launch-worktree (source-cwd branch when-spec
                                                             &optional initial-message
                                                             rename-name)
  "Schedule a new git worktree on BRANCH under SOURCE-CWD's repo + claude launch.
At WHEN-SPEC we run the equivalent of `llm-dashboard-new-worktree
SOURCE-CWD BRANCH', which creates the worktree and starts claude in it.
INITIAL-MESSAGE, if non-empty, is delivered after the launch settles.
RENAME-NAME, if non-nil, is sent as `/rename RENAME-NAME' before the
initial message — useful since auto-named worktree slugs default to
the branch name; pass an explicit rename to override."
  (interactive
   (list (llm-dashboard--read-project)
         (read-string "Branch / worktree name: ")
         (read-string "When: ")
         (let ((m (read-string "Initial message (empty = none): ")))
           (and (not (string-empty-p (string-trim m))) m))
         (let ((rn (read-string "Rename session to (empty = no rename): ")))
           (and (not (string-empty-p (string-trim rn))) rn))))
  (when (or (null branch) (string-empty-p (string-trim branch)))
    (user-error "Branch name is required"))
  (let* ((target-time (llm-dashboard--parse-time-spec when-spec))
         (id (llm-dashboard--make-id))
         (p (make-llm-dashboard-pending-launch
             :id id :kind :worktree
             :cwd (expand-file-name source-cwd)
             :branch (string-trim branch)
             :initial-message initial-message
             :rename-name rename-name
             :scheduled target-time
             :created (current-time))))
    (setf (llm-dashboard-pending-launch-timer p)
          (run-at-time target-time nil
                       #'llm-dashboard--deliver-pending-launch id))
    (puthash id p llm-dashboard--pending-launches)
    (llm-dashboard--write-pending-launches)
    (message "llm-dashboard: scheduled worktree launch %s @ %s at %s (id %s)"
             (llm-dashboard-pending-launch-branch p)
             (abbreviate-file-name source-cwd)
             (llm-dashboard--format-when target-time)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun llm-dashboard-cancel-pending-send (id)
  "Cancel the pending send with ID."
  (interactive
   (let ((cands (cl-loop for p being the hash-values
                         of llm-dashboard--pending-sends
                         collect (cons (format "%s  %s  %.40s"
                                               (llm-dashboard--format-when
                                                (llm-dashboard-pending-send-scheduled p))
                                               (or (llm-dashboard-pending-send-cwd p) "?")
                                               (llm-dashboard-pending-send-message p))
                                       (llm-dashboard-pending-send-id p)))))
     (when (null cands) (user-error "No pending sends"))
     (list (cdr (assoc (completing-read "Cancel: " (mapcar #'car cands) nil t)
                       cands)))))
  (let ((p (gethash id llm-dashboard--pending-sends)))
    (when (and p (llm-dashboard-pending-send-timer p))
      (cancel-timer (llm-dashboard-pending-send-timer p)))
    (remhash id llm-dashboard--pending-sends)
    (llm-dashboard--write-pending-sends)
    (message "llm-dashboard: cancelled %s"
             (substring id 0 (min 8 (length id))))))

;;;###autoload
(defun llm-dashboard-cancel-pending-launch (id)
  "Cancel the pending launch with ID."
  (interactive
   (let ((cands (cl-loop for p being the hash-values
                         of llm-dashboard--pending-launches
                         collect (cons (format "%s  %s  %s"
                                               (llm-dashboard--format-when
                                                (llm-dashboard-pending-launch-scheduled p))
                                               (llm-dashboard-pending-launch-kind p)
                                               (or (llm-dashboard-pending-launch-cwd p)
                                                   "?"))
                                       (llm-dashboard-pending-launch-id p)))))
     (when (null cands) (user-error "No pending launches"))
     (list (cdr (assoc (completing-read "Cancel: " (mapcar #'car cands) nil t)
                       cands)))))
  (let ((p (gethash id llm-dashboard--pending-launches)))
    (when (and p (llm-dashboard-pending-launch-timer p))
      (cancel-timer (llm-dashboard-pending-launch-timer p)))
    (remhash id llm-dashboard--pending-launches)
    (llm-dashboard--write-pending-launches)
    (message "llm-dashboard: cancelled launch %s"
             (substring id 0 (min 8 (length id))))))

;;;###autoload
(defun llm-dashboard-resume-pending-sends ()
  "Re-arm timers for all pending sends and launches persisted to disk.
Idempotent within an Emacs session.  Past-due entries fire immediately."
  (interactive)
  (cond
   (llm-dashboard--pending-restored
    (message "llm-dashboard: pending actions already restored"))
   (t
    (setq llm-dashboard--pending-restored t)
    (let ((now (current-time))
          (sends 0) (launches 0))
      ;; Sends
      (dolist (e (llm-dashboard--read-lisp-data
                  llm-dashboard-pending-sends-file))
        (let* ((id (plist-get e :id))
               (target (plist-get e :scheduled))
               (p (make-llm-dashboard-pending-send
                   :id id
                   :cwd (plist-get e :cwd)
                   :sid (plist-get e :sid)
                   :message (plist-get e :message)
                   :rename-name (plist-get e :rename-name)
                   :scheduled target
                   :created (plist-get e :created))))
          (puthash id p llm-dashboard--pending-sends)
          (setf (llm-dashboard-pending-send-timer p)
                (run-at-time (if (time-less-p target now) 0 target) nil
                             #'llm-dashboard--deliver-pending id))
          (cl-incf sends)))
      ;; Launches
      (dolist (e (llm-dashboard--read-lisp-data
                  llm-dashboard-pending-launches-file))
        (let* ((id (plist-get e :id))
               (target (plist-get e :scheduled))
               (p (make-llm-dashboard-pending-launch
                   :id id
                   :kind (plist-get e :kind)
                   :cwd (plist-get e :cwd)
                   :extra-args (plist-get e :extra-args)
                   :branch (plist-get e :branch)
                   :initial-message (plist-get e :initial-message)
                   :rename-name (plist-get e :rename-name)
                   :scheduled target
                   :created (plist-get e :created))))
          (puthash id p llm-dashboard--pending-launches)
          (setf (llm-dashboard-pending-launch-timer p)
                (run-at-time (if (time-less-p target now) 0 target) nil
                             #'llm-dashboard--deliver-pending-launch id))
          (cl-incf launches)))
      (message "llm-dashboard: restored %d pending send(s) and %d pending launch(es)"
               sends launches)))))

;;; --- List buffer (unified: sends + launches) -------------------------------

(defvar llm-dashboard-pending-sends-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "d" #'llm-dashboard-pending-sends-cancel-at-point)
    (define-key map "e" #'llm-dashboard-pending-sends-reschedule-at-point)
    (define-key map "v" #'llm-dashboard-pending-sends-view-at-point)
    (define-key map (kbd "RET") #'llm-dashboard-pending-sends-view-at-point)
    (define-key map "g" #'llm-dashboard-pending-sends-refresh)
    map)
  "Keymap for `llm-dashboard-pending-sends-mode'.")

(define-derived-mode llm-dashboard-pending-sends-mode tabulated-list-mode
  "ClaudePending"
  "Major mode listing scheduled llm-dashboard sends and launches."
  (setq tabulated-list-format
        [("When"    18 t)
         ("Type"     8 t)
         ("Target"  28 t)
         ("Detail"   0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "When" nil))
  (tabulated-list-init-header))

(defun llm-dashboard--row-for-send (p)
  "Build a tabulated-list row for pending-send P."
  (let* ((cwd (or (llm-dashboard-pending-send-cwd p) "?"))
         (inst (llm-dashboard--find-instance-by-sid-or-cwd
                (llm-dashboard-pending-send-sid p) cwd))
         (target (cond
                  (inst (buffer-name
                         (llm-dashboard-instance-buffer inst)))
                  (t (concat (file-name-nondirectory
                              (directory-file-name cwd))
                             " (offline)"))))
         (preview (let ((m (llm-dashboard-pending-send-message p)))
                    (truncate-string-to-width
                     (replace-regexp-in-string "\n" " ⏎ " m)
                     200 nil nil "…"))))
    (list (llm-dashboard-pending-send-id p)
          (vector (llm-dashboard--format-when
                   (llm-dashboard-pending-send-scheduled p))
                  "send" target preview))))

(defun llm-dashboard--row-for-launch (p)
  "Build a tabulated-list row for pending-launch P."
  (let* ((kind (llm-dashboard-pending-launch-kind p))
         (cwd (or (llm-dashboard-pending-launch-cwd p) "?"))
         (target (abbreviate-file-name cwd))
         (detail
          (pcase kind
            (:plain
             (let* ((args (llm-dashboard-pending-launch-extra-args p))
                    (msg (llm-dashboard-pending-launch-initial-message p))
                    (head (cond ((and args (member "--resume" args))
                                 (format "resume %s"
                                         (or (cadr (member "--resume" args)) "?")))
                                (args (format "args=%S" args))
                                (t "cold"))))
               (if msg (format "%s — %.60s" head msg) head)))
            (:worktree
             (format "worktree %s%s"
                     (llm-dashboard-pending-launch-branch p)
                     (if-let ((m (llm-dashboard-pending-launch-initial-message p)))
                         (format " — %.60s" m) "")))
            (_ (format "kind=%S" kind)))))
    (list (llm-dashboard-pending-launch-id p)
          (vector (llm-dashboard--format-when
                   (llm-dashboard-pending-launch-scheduled p))
                  (pcase kind (:plain "launch") (:worktree "wt-launch") (_ "?"))
                  target detail))))

(defun llm-dashboard-pending-sends-refresh ()
  "Repopulate the pending list from both in-memory tables."
  (interactive)
  (let ((entries
         (append
          (cl-loop for p being the hash-values of llm-dashboard--pending-sends
                   collect (llm-dashboard--row-for-send p))
          (cl-loop for p being the hash-values of llm-dashboard--pending-launches
                   collect (llm-dashboard--row-for-launch p)))))
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;###autoload
(defun llm-dashboard-list-pending-sends ()
  "Open a tabulated-list buffer of all pending scheduled sends and launches."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Pending Sends*")))
    (with-current-buffer buf
      (llm-dashboard-pending-sends-mode)
      (llm-dashboard-pending-sends-refresh))
    (pop-to-buffer buf)))

(defun llm-dashboard-pending-sends--id-at-point ()
  (or (tabulated-list-get-id)
      (user-error "No pending action on this line")))

(defun llm-dashboard--lookup-pending (id)
  "Return (KIND . STRUCT) for ID, where KIND is `send' or `launch'."
  (cond
   ((gethash id llm-dashboard--pending-sends)
    (cons 'send (gethash id llm-dashboard--pending-sends)))
   ((gethash id llm-dashboard--pending-launches)
    (cons 'launch (gethash id llm-dashboard--pending-launches)))
   (t nil)))

(defun llm-dashboard-pending-sends-cancel-at-point ()
  "Cancel the pending send or launch at point."
  (interactive)
  (let* ((id (llm-dashboard-pending-sends--id-at-point))
         (entry (llm-dashboard--lookup-pending id)))
    (unless entry (user-error "Entry no longer exists"))
    (pcase (car entry)
      ('send   (llm-dashboard-cancel-pending-send id))
      ('launch (llm-dashboard-cancel-pending-launch id)))
    (llm-dashboard-pending-sends-refresh)))

(defun llm-dashboard-pending-sends-reschedule-at-point ()
  "Re-prompt for a new time for the entry at point."
  (interactive)
  (let* ((id (llm-dashboard-pending-sends--id-at-point))
         (entry (llm-dashboard--lookup-pending id)))
    (unless entry (user-error "Entry no longer exists"))
    (pcase-let ((`(,kind . ,p) entry))
      (let* ((old-time (pcase kind
                         ('send   (llm-dashboard-pending-send-scheduled p))
                         ('launch (llm-dashboard-pending-launch-scheduled p))))
             (when-spec (read-string
                         (format "Reschedule (was %s): "
                                 (llm-dashboard--format-when old-time))))
             (new-time (llm-dashboard--parse-time-spec when-spec)))
        (pcase kind
          ('send
           (when (llm-dashboard-pending-send-timer p)
             (cancel-timer (llm-dashboard-pending-send-timer p)))
           (setf (llm-dashboard-pending-send-scheduled p) new-time
                 (llm-dashboard-pending-send-timer p)
                 (run-at-time new-time nil
                              #'llm-dashboard--deliver-pending id))
           (llm-dashboard--write-pending-sends))
          ('launch
           (when (llm-dashboard-pending-launch-timer p)
             (cancel-timer (llm-dashboard-pending-launch-timer p)))
           (setf (llm-dashboard-pending-launch-scheduled p) new-time
                 (llm-dashboard-pending-launch-timer p)
                 (run-at-time new-time nil
                              #'llm-dashboard--deliver-pending-launch id))
           (llm-dashboard--write-pending-launches)))
        (llm-dashboard-pending-sends-refresh)
        (message "llm-dashboard: rescheduled to %s"
                 (llm-dashboard--format-when new-time))))))

(defun llm-dashboard-pending-sends-view-at-point ()
  "Pop a buffer showing the full detail of the entry at point."
  (interactive)
  (let* ((id (llm-dashboard-pending-sends--id-at-point))
         (entry (llm-dashboard--lookup-pending id)))
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
                               (llm-dashboard--format-when
                                (llm-dashboard-pending-send-scheduled p))))
               (insert (format "Target:  %s (sid %s)\n"
                               (or (llm-dashboard-pending-send-cwd p) "?")
                               (or (llm-dashboard-pending-send-sid p) "—")))
               (insert (format "Created: %s\n\n"
                               (format-time-string
                                "%Y-%m-%d %H:%M:%S"
                                (llm-dashboard-pending-send-created p))))
               (insert (llm-dashboard-pending-send-message p)))
              ('launch
               (insert (format "Kind:        launch (%s)\n"
                               (llm-dashboard-pending-launch-kind p)))
               (insert (format "When:        %s\n"
                               (llm-dashboard--format-when
                                (llm-dashboard-pending-launch-scheduled p))))
               (insert (format "Cwd/source:  %s\n"
                               (or (llm-dashboard-pending-launch-cwd p) "?")))
               (when (eq (llm-dashboard-pending-launch-kind p) :worktree)
                 (insert (format "Branch:      %s\n"
                                 (llm-dashboard-pending-launch-branch p))))
               (when (llm-dashboard-pending-launch-extra-args p)
                 (insert (format "Extra args:  %S\n"
                                 (llm-dashboard-pending-launch-extra-args p))))
               (insert (format "Created:     %s\n\n"
                               (format-time-string
                                "%Y-%m-%d %H:%M:%S"
                                (llm-dashboard-pending-launch-created p))))
               (insert "Initial message:\n")
               (insert (or (llm-dashboard-pending-launch-initial-message p)
                           "  (none)\n"))))
            (goto-char (point-min))))
        (special-mode))
      (display-buffer buf))))

;;; --- Self-test (smoke test the full schedule + send pipeline) -------------

(defcustom llm-dashboard-schedule-self-test-cwd "/tmp/claude-schedule-selftest"
  "Disposable directory used by `llm-dashboard-schedule-self-test'.
Created if missing.  The directory is left in place after the test so
the spawned instance has a stable cwd; remove it manually if you don't
want it lingering."
  :type 'directory
  :group 'llm-dashboard)

(defcustom llm-dashboard-schedule-self-test-prompt
  "say hello world and nothing else"
  "Prompt sent to the disposable instance during the self-test.
Should be something that produces a deterministic, easy-to-verify
response — anything containing the literal `hello world' satisfies the
default success matcher."
  :type 'string
  :group 'llm-dashboard)

(defcustom llm-dashboard-schedule-self-test-success-regexp "hello world"
  "Regex matched against the disposable instance's buffer tail.
Match → the schedule + launch + initial-message + submit pipeline is
working end-to-end.  Customize alongside
`llm-dashboard-schedule-self-test-prompt' if you change one."
  :type 'regexp
  :group 'llm-dashboard)

;;;###autoload
(defun llm-dashboard-schedule-self-test (&optional keep)
  "End-to-end smoke test of the schedule pipeline.

Schedules a launch in `llm-dashboard-schedule-self-test-cwd' to
fire in 3 seconds, with
`llm-dashboard-schedule-self-test-prompt' as the initial message.
Waits for the launch + the followup-delay + a few seconds for the
agent's response, then matches
`llm-dashboard-schedule-self-test-success-regexp' against the
disposable instance's buffer tail.  Reports pass/fail in the echo
area and pops a results buffer for inspection.

The most common failure mode this catches is the split-write submit
regression — a single PTY write of \"<msg>\\n\" or \"<msg>\\r\"
fills the input box but doesn't submit, so the response never
arrives and the regex fails.  See the comment in
`llm-dashboard--deliver-pending' for the fix.

With prefix arg KEEP, leave the disposable instance running after
the test so you can inspect it manually.  Without KEEP, the
instance is killed and the cwd's `.claude/' subdir (if any) is left
in place."
  (interactive "P")
  (unless (file-directory-p llm-dashboard-schedule-self-test-cwd)
    (make-directory llm-dashboard-schedule-self-test-cwd t))
  (let* ((cwd llm-dashboard-schedule-self-test-cwd)
         ;; Total expected wall time:
         ;;   3s     — launch fire delay
         ;; + 8s     — llm-dashboard-pending-launch-followup-delay
         ;; + ~3s    — claude startup + a short response
         ;; + 2s     — slack
         (total-wait (+ 3 llm-dashboard-pending-launch-followup-delay 5))
         (launch-id (llm-dashboard-schedule-launch
                     cwd "+3s"
                     llm-dashboard-schedule-self-test-prompt
                     nil)))
    (message "llm-dashboard self-test: waiting %ds for full pipeline..."
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
                              (or (llm-dashboard-instance-cwd i) ""))))
                    (llm-dashboard--instances-list)))
        (when inst
          (with-current-buffer (llm-dashboard-instance-buffer inst)
            (setq tail (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 4000))
                        (point-max)))
            (setq matched
                  (and (string-match-p
                        llm-dashboard-schedule-self-test-success-regexp
                        tail)
                       ;; Also verify the prompt itself was submitted —
                       ;; "❯ <prompt>" appears in the conversation
                       ;; history (NOT just sitting in the input box).
                       (string-match-p
                        (regexp-quote llm-dashboard-schedule-self-test-prompt)
                        tail))))))
      ;; Build results.
      (let ((report
             (with-temp-buffer
               (insert (format "llm-dashboard-schedule self-test\n"))
               (insert (format "===================================\n\n"))
               (insert (format "Result:        %s\n" (if matched "PASS" "FAIL")))
               (insert (format "Launch id:     %s\n" launch-id))
               (insert (format "Cwd:           %s\n" cwd))
               (insert (format "Prompt:        %S\n"
                               llm-dashboard-schedule-self-test-prompt))
               (insert (format "Success regex: %S\n"
                               llm-dashboard-schedule-self-test-success-regexp))
               (insert (format "Instance:      %s\n"
                               (if inst
                                   (buffer-name
                                    (llm-dashboard-instance-buffer inst))
                                 "(never registered)")))
               (insert (format "Wall time:     %ds\n\n" total-wait))
               (insert "Buffer tail:\n\n")
               (insert (or tail "(no buffer tail captured)\n"))
               (buffer-string))))
        (with-current-buffer (get-buffer-create
                              "*llm-dashboard schedule self-test*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert report)
            (goto-char (point-min)))
          (special-mode)
          (display-buffer (current-buffer))))
      ;; Cleanup unless KEEP.
      (when (and inst (not keep))
        (let ((b (llm-dashboard-instance-buffer inst))
              (kill-buffer-query-functions nil))
          (when (buffer-live-p b) (kill-buffer b))))
      ;; Echo summary.
      (if matched
          (message "llm-dashboard self-test: PASS — pipeline working")
        (message "llm-dashboard self-test: FAIL — see *…self-test* buffer"))
      matched)))

;;; --- Dashboard integration -------------------------------------------------

(with-eval-after-load 'claude-dashboard
  (define-key llm-dashboard-mode-map "S" #'llm-dashboard-schedule-send)
  (define-key llm-dashboard-mode-map "J" #'llm-dashboard-schedule-launch)
  (define-key llm-dashboard-mode-map "L" #'llm-dashboard-list-pending-sends))

(provide 'llm-dashboard-schedule)
(provide 'claude-dashboard-schedule)
;;; llm-dashboard-schedule.el ends here
