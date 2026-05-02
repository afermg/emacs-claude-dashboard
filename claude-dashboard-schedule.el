;;; claude-dashboard-schedule.el --- Schedule timed sends to Claude instances -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1") (claude-dashboard "0.1"))

;;; Commentary:
;;
;; Adds a "schedule send" facility to claude-dashboard: queue a message
;; string + a target instance + a future time, and have Emacs deliver
;; the message via the instance's eat PTY at that time.  Useful for
;; composing follow-ups while the agent is busy and firing them later,
;; or for "send this at 3pm" reminders to yourself.
;;
;; Persists across emacs restart in the same dir as the package's
;; existing crash-recovery manifest
;; (~/.claude/dashboard-pending-sends.el by default).
;;
;; Entry points:
;;   M-x claude-dashboard-schedule-send         (S in dashboard)
;;   M-x claude-dashboard-list-pending-sends    (L in dashboard)
;;   M-x claude-dashboard-resume-pending-sends  (call after restart)

;;; Code:

(require 'cl-lib)
(require 'claude-dashboard)
(require 'tabulated-list)

(defcustom claude-dashboard-pending-sends-file
  (expand-file-name "dashboard-pending-sends.el" claude-dashboard-claude-dir)
  "Where queued scheduled sends are persisted.
Set to nil to disable persistence (in-memory only, lost on restart)."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'claude-dashboard)

(defcustom claude-dashboard-pending-send-defer-when-busy 5
  "Seconds to defer a fired send when the target instance is busy.
A scheduled send only fires the message when its instance has a live
process and is idle.  When busy, the send re-arms itself for this
many seconds later."
  :type 'number
  :group 'claude-dashboard)

(defcustom claude-dashboard-pending-send-no-target-retry 30
  "Seconds to defer when a fired send has no matching live instance.
Lets you `claude --resume <sid>' a dead session and have the queued
message land on the relaunched instance once it's running."
  :type 'number
  :group 'claude-dashboard)

(cl-defstruct claude-dashboard-pending-send
  id cwd sid message scheduled created timer)

(defvar claude-dashboard--pending-sends (make-hash-table :test 'equal)
  "id (string) → `claude-dashboard-pending-send'.")

(defvar claude-dashboard--pending-sends-restored nil
  "Non-nil once `claude-dashboard-resume-pending-sends' has run this session.")

;;; --- Time parsing ----------------------------------------------------------

(defun claude-dashboard--parse-time-spec (spec)
  "Parse SPEC into an encoded absolute time.
Accepts:
  +Ns / +Nm / +Nh / +Nd       — relative offset from now
  HH:MM                        — today; rolls to tomorrow if already past
  YYYY-MM-DD HH:MM[:SS]        — absolute, local timezone
  <YYYY-MM-DD HH:MM[:SS]>      — org-style timestamp; angle brackets stripped
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
      ;; DST=-1 lets encode-time pick the correct offset for the given date;
      ;; DST=nil would force "not in DST" and shift in-DST dates by an hour.
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

(defun claude-dashboard--write-pending-sends ()
  "Persist the pending-sends table to disk."
  (when claude-dashboard-pending-sends-file
    (let ((dir (file-name-directory claude-dashboard-pending-sends-file)))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)))
    (let ((entries
           (cl-loop for p being the hash-values
                    of claude-dashboard--pending-sends
                    collect (list :id (claude-dashboard-pending-send-id p)
                                  :cwd (claude-dashboard-pending-send-cwd p)
                                  :sid (claude-dashboard-pending-send-sid p)
                                  :message (claude-dashboard-pending-send-message p)
                                  :scheduled (claude-dashboard-pending-send-scheduled p)
                                  :created (claude-dashboard-pending-send-created p)))))
      (with-temp-file claude-dashboard-pending-sends-file
        (insert ";;; -*- lisp-data -*-\n")
        (let ((print-level nil) (print-length nil))
          (prin1 entries (current-buffer)))
        (insert "\n")))))

(defun claude-dashboard--read-pending-sends ()
  "Return the persisted entry list, or nil."
  (when (and claude-dashboard-pending-sends-file
             (file-readable-p claude-dashboard-pending-sends-file))
    (with-temp-buffer
      (insert-file-contents claude-dashboard-pending-sends-file)
      (goto-char (point-min))
      (ignore-errors (read (current-buffer))))))

;;; --- Target resolution -----------------------------------------------------

(defun claude-dashboard--find-instance-by-sid-or-cwd (sid cwd)
  "Return the live instance matching SID first, then CWD, or nil.
Buffer names are intentionally NOT used as match keys — the package
renames buffers on `/name', so they're unstable identifiers."
  (let ((cwd-canon (and cwd (expand-file-name cwd))))
    (cl-find-if
     (lambda (inst)
       (or (and sid
                (or (equal sid (claude-dashboard-instance-session-id inst))
                    (and (fboundp 'claude-dashboard--live-session-id)
                         (equal sid (claude-dashboard--live-session-id inst)))))
           (and cwd-canon
                (equal cwd-canon
                       (expand-file-name
                        (claude-dashboard-instance-cwd inst))))))
     (claude-dashboard--instances-list))))

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

;;; --- Delivery --------------------------------------------------------------

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
         ;; No matching live instance — agent isn't running yet.
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
         ;; Instance busy — defer briefly to avoid interleaving with
         ;; in-flight tool use or auto-/name injection.
         ((and status (not (eq status 'idle)))
          (setf (claude-dashboard-pending-send-timer p)
                (run-at-time
                 claude-dashboard-pending-send-defer-when-busy nil
                 #'claude-dashboard--deliver-pending id))
          (message "claude-dashboard: %s busy; deferring scheduled send %ds"
                   (buffer-name (claude-dashboard-instance-buffer inst))
                   claude-dashboard-pending-send-defer-when-busy))
         ;; Send it.
         (t
          (process-send-string
           proc
           (concat (claude-dashboard-pending-send-message p) "\n"))
          (remhash id claude-dashboard--pending-sends)
          (claude-dashboard--write-pending-sends)
          (message "claude-dashboard: delivered scheduled send to %s"
                   (buffer-name (claude-dashboard-instance-buffer inst)))))))))

;;; --- Public commands -------------------------------------------------------

(defun claude-dashboard--make-id ()
  "Return a fresh string id."
  (format "%s-%05d" (format-time-string "%s") (random 100000)))

;;;###autoload
(defun claude-dashboard-schedule-send (instance message when-spec)
  "Schedule MESSAGE to be sent to INSTANCE at WHEN-SPEC.
WHEN-SPEC is parsed by `claude-dashboard--parse-time-spec' — accepts
relative offsets like `+5m', clock times like `14:30', and absolute
timestamps like `2026-05-02 14:30'.

Interactively, prompt for each.  Default target is the dashboard
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
                      "When (e.g. +5m, 14:30, 2026-05-02 14:30): ")))
     (list inst msg when-spec)))
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
(defun claude-dashboard-cancel-pending-send (id)
  "Cancel the pending send with ID."
  (interactive
   (let ((cands (cl-loop
                 for p being the hash-values
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
(defun claude-dashboard-resume-pending-sends ()
  "Re-arm timers for any pending sends persisted to disk.
Idempotent within an Emacs session — subsequent calls are no-ops.
Past-due entries fire immediately on resume."
  (interactive)
  (cond
   (claude-dashboard--pending-sends-restored
    (message "claude-dashboard: pending sends already restored"))
   (t
    (setq claude-dashboard--pending-sends-restored t)
    (let ((entries (claude-dashboard--read-pending-sends))
          (now (current-time))
          (count 0))
      (dolist (e entries)
        (let* ((id (plist-get e :id))
               (target (plist-get e :scheduled))
               (p (make-claude-dashboard-pending-send
                   :id id
                   :cwd (plist-get e :cwd)
                   :sid (plist-get e :sid)
                   :message (plist-get e :message)
                   :scheduled target
                   :created (plist-get e :created))))
          (puthash id p claude-dashboard--pending-sends)
          (setf (claude-dashboard-pending-send-timer p)
                (run-at-time (if (time-less-p target now) 0 target)
                             nil
                             #'claude-dashboard--deliver-pending id))
          (cl-incf count)))
      (message "claude-dashboard: restored %d pending send(s)" count)))))

;;; --- List buffer -----------------------------------------------------------

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
  "Major mode listing scheduled claude-dashboard sends."
  (setq tabulated-list-format
        [("When"    18 t)
         ("Target"  30 t)
         ("Preview"  0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "When" nil))
  (tabulated-list-init-header))

(defun claude-dashboard-pending-sends-refresh ()
  "Repopulate the pending-sends list from the in-memory table."
  (interactive)
  (let ((entries
         (cl-loop
          for p being the hash-values of claude-dashboard--pending-sends
          for cwd = (or (claude-dashboard-pending-send-cwd p) "?")
          for inst = (claude-dashboard--find-instance-by-sid-or-cwd
                      (claude-dashboard-pending-send-sid p) cwd)
          for target = (cond
                        (inst (buffer-name
                               (claude-dashboard-instance-buffer inst)))
                        (t (concat (file-name-nondirectory
                                    (directory-file-name cwd))
                                   " (offline)")))
          for preview = (let ((m (claude-dashboard-pending-send-message p)))
                          (truncate-string-to-width
                           (replace-regexp-in-string "\n" " ⏎ " m)
                           200 nil nil "…"))
          collect (list (claude-dashboard-pending-send-id p)
                        (vector
                         (claude-dashboard--format-when
                          (claude-dashboard-pending-send-scheduled p))
                         target preview)))))
    (setq tabulated-list-entries entries)
    (tabulated-list-print t)))

;;;###autoload
(defun claude-dashboard-list-pending-sends ()
  "Open a tabulated-list buffer of all pending scheduled sends."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Pending Sends*")))
    (with-current-buffer buf
      (claude-dashboard-pending-sends-mode)
      (claude-dashboard-pending-sends-refresh))
    (pop-to-buffer buf)))

(defun claude-dashboard-pending-sends--id-at-point ()
  (or (tabulated-list-get-id)
      (user-error "No pending send on this line")))

(defun claude-dashboard-pending-sends-cancel-at-point ()
  "Cancel the pending send at point."
  (interactive)
  (let ((id (claude-dashboard-pending-sends--id-at-point)))
    (claude-dashboard-cancel-pending-send id)
    (claude-dashboard-pending-sends-refresh)))

(defun claude-dashboard-pending-sends-reschedule-at-point ()
  "Re-prompt for a new time for the pending send at point."
  (interactive)
  (let* ((id (claude-dashboard-pending-sends--id-at-point))
         (p (gethash id claude-dashboard--pending-sends)))
    (unless p (user-error "Send no longer exists"))
    (let* ((when-spec (read-string
                       (format "Reschedule (was %s): "
                               (claude-dashboard--format-when
                                (claude-dashboard-pending-send-scheduled p)))))
           (new-time (claude-dashboard--parse-time-spec when-spec)))
      (when (claude-dashboard-pending-send-timer p)
        (cancel-timer (claude-dashboard-pending-send-timer p)))
      (setf (claude-dashboard-pending-send-scheduled p) new-time
            (claude-dashboard-pending-send-timer p)
            (run-at-time new-time nil
                         #'claude-dashboard--deliver-pending id))
      (claude-dashboard--write-pending-sends)
      (claude-dashboard-pending-sends-refresh)
      (message "claude-dashboard: rescheduled to %s"
               (claude-dashboard--format-when new-time)))))

(defun claude-dashboard-pending-sends-view-at-point ()
  "Pop a buffer showing the full message of the pending send at point."
  (interactive)
  (let* ((id (claude-dashboard-pending-sends--id-at-point))
         (p (gethash id claude-dashboard--pending-sends)))
    (unless p (user-error "Send no longer exists"))
    (let ((buf (get-buffer-create
                (format "*Claude Pending Send %s*"
                        (substring id 0 (min 8 (length id)))))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "When:    %s\n"
                          (claude-dashboard--format-when
                           (claude-dashboard-pending-send-scheduled p))))
          (insert (format "Target:  %s (sid %s)\n"
                          (or (claude-dashboard-pending-send-cwd p) "?")
                          (or (claude-dashboard-pending-send-sid p) "—")))
          (insert (format "Created: %s\n"
                          (format-time-string
                           "%Y-%m-%d %H:%M:%S"
                           (claude-dashboard-pending-send-created p))))
          (insert "\n")
          (insert (claude-dashboard-pending-send-message p))
          (goto-char (point-min)))
        (special-mode))
      (display-buffer buf))))

;;; --- Dashboard integration -------------------------------------------------

(with-eval-after-load 'claude-dashboard
  (define-key claude-dashboard-mode-map "S" #'claude-dashboard-schedule-send)
  (define-key claude-dashboard-mode-map "L" #'claude-dashboard-list-pending-sends))

(provide 'claude-dashboard-schedule)
;;; claude-dashboard-schedule.el ends here
