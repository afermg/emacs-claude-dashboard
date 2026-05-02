;;; claude-dashboard-recurring.el --- Recurring schedules for claude-dashboard -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1") (claude-dashboard "0.1") (claude-dashboard-schedule "0.1"))

;;; Commentary:
;;
;; Adds *recurring* schedules on top of `claude-dashboard-schedule.el's
;; one-shot pending sends/launches.  A recurring entry says "do X every
;; weekday at 9am" or "do Y every 30 minutes"; at each fire time, the
;; recurring entry produces a normal pending-{send,launch} struct,
;; delivers it through the existing pipeline, and re-arms itself for
;; the next occurrence.
;;
;; Recurrence DSL — small but covers ~95% of real use:
;;
;;   daily 9:00            — every day at 09:00
;;   weekdays 9:00         — Mon-Fri at 09:00
;;   weekends 10:30        — Sat+Sun at 10:30
;;   mon 14:00             — every Monday at 14:00
;;   mon,wed,fri 14:00     — three days a week at 14:00
;;   every 30m             — every 30 minutes
;;   every 2h              — every 2 hours
;;   every 1d              — every 24 hours
;;
;; Days of week are sun mon tue wed thu fri sat (case-insensitive).
;; Time is HH:MM, 24-hour, local timezone.
;;
;; Entry points:
;;   M-x claude-dashboard-schedule-recurring-send
;;   M-x claude-dashboard-schedule-recurring-launch
;;   M-x claude-dashboard-schedule-recurring-launch-worktree
;;   M-x claude-dashboard-list-recurring          (r in dashboard)
;;   M-x claude-dashboard-cancel-recurring
;;   M-x claude-dashboard-toggle-recurring        (pause / resume)

;;; Code:

(require 'cl-lib)
(require 'claude-dashboard)
(require 'claude-dashboard-schedule)
(require 'tabulated-list)

;;; --- Customs ---------------------------------------------------------------

(defcustom claude-dashboard-recurring-file
  (expand-file-name "dashboard-recurring.el" claude-dashboard-claude-dir)
  "Where recurring schedules are persisted across emacs restarts."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'claude-dashboard)

;;; --- Data ------------------------------------------------------------------

(cl-defstruct claude-dashboard-recurring
  ;; Stable identity, present in the persistence file.
  id
  ;; Action to fire on each occurrence: :send, :launch, :launch-worktree,
  ;; or :launch-resume (which is :launch with EXTRA-ARGS = ("--resume" SID)).
  action-type
  ;; Original DSL string (e.g. "weekdays 9:00") — preserved for display
  ;; and to allow re-parsing if we ever change the parser.
  spec-string
  ;; Parsed spec data form (see `claude-dashboard--parse-recur-spec').
  spec
  ;; Action-specific keys, plist:
  ;;   :send      → (:cwd :sid :message)
  ;;   :launch    → (:cwd :extra-args :initial-message)
  ;;   :launch-worktree → (:cwd :branch :initial-message)
  ;;   :launch-resume   → (:cwd :sid :initial-message)
  payload
  last-fired       ; encoded-time, or nil if never
  next-fire        ; encoded-time, recomputed each cycle
  enabled          ; t | nil — paused entries skip without removal
  created
  timer)           ; live `run-at-time' object — NOT persisted

(defvar claude-dashboard--recurring (make-hash-table :test 'equal)
  "id (string) → `claude-dashboard-recurring'.")

(defvar claude-dashboard--recurring-restored nil
  "Non-nil once recurring entries have been restored this session.")

;;; --- Recurrence parser -----------------------------------------------------

(defconst claude-dashboard--day-map
  '(("sun" . 0) ("mon" . 1) ("tue" . 2) ("wed" . 3)
    ("thu" . 4) ("fri" . 5) ("sat" . 6))
  "Three-letter day abbreviation → cl-time weekday number.")

(defun claude-dashboard--parse-recur-spec (s)
  "Parse a recurrence DSL string S into a spec data plist.

Returns one of:
  (:type :every  :seconds N)
  (:type :daily  :hour H :minute M)
  (:type :weekly :days (DOW...) :hour H :minute M)   ; 0=Sun..6=Sat

Signal `user-error' on parse failure."
  (let ((s (string-trim s)))
    (cond
     ((string-match "\\`every \\([0-9]+\\)\\([smhd]\\)\\'" s)
      (let* ((n (string-to-number (match-string 1 s)))
             (unit (match-string 2 s))
             (sec (* n (pcase unit
                         ("s" 1) ("m" 60) ("h" 3600) ("d" 86400)))))
        (when (< sec 30)
          (user-error "Refusing recurrence < 30s (would hammer the agent)"))
        (list :type :every :seconds sec)))
     ((string-match "\\`daily \\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
      (list :type :daily
            :hour (string-to-number (match-string 1 s))
            :minute (string-to-number (match-string 2 s))))
     ((string-match "\\`weekdays \\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
      (list :type :weekly :days '(1 2 3 4 5)
            :hour (string-to-number (match-string 1 s))
            :minute (string-to-number (match-string 2 s))))
     ((string-match "\\`weekends \\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
      (list :type :weekly :days '(0 6)
            :hour (string-to-number (match-string 1 s))
            :minute (string-to-number (match-string 2 s))))
     ((string-match
       "\\`\\([a-zA-Z][a-zA-Z,]*\\) \\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
      (let* ((days-str (match-string 1 s))
             (h (string-to-number (match-string 2 s)))
             (m (string-to-number (match-string 3 s)))
             (days (mapcar
                    (lambda (d)
                      (or (cdr (assoc (downcase d)
                                      claude-dashboard--day-map))
                          (user-error "Unknown day name: %s (expected %s)"
                                      d (mapconcat #'car
                                                   claude-dashboard--day-map
                                                   "/"))))
                    (split-string days-str ","))))
        (list :type :weekly
              :days (sort (cl-remove-duplicates days) #'<)
              :hour h :minute m)))
     (t (user-error
         "Cannot parse recurrence: %S
Examples: 'daily 9:00', 'weekdays 9:00', 'mon,wed,fri 14:00', 'every 30m'"
         s)))))

(defun claude-dashboard--format-recur-spec (spec-or-string)
  "Return a short user-readable form of SPEC-OR-STRING.
If passed the original DSL string, return it unchanged."
  (cond
   ((stringp spec-or-string) spec-or-string)
   ((null spec-or-string) "?")
   (t (let ((type (plist-get spec-or-string :type)))
        (pcase type
          (:every (format "every %ds" (plist-get spec-or-string :seconds)))
          (:daily (format "daily %02d:%02d"
                          (plist-get spec-or-string :hour)
                          (plist-get spec-or-string :minute)))
          (:weekly (let* ((days (plist-get spec-or-string :days))
                          (rev (mapcar (lambda (n)
                                         (car (rassoc n claude-dashboard--day-map)))
                                       days)))
                     (format "%s %02d:%02d"
                             (mapconcat #'identity rev ",")
                             (plist-get spec-or-string :hour)
                             (plist-get spec-or-string :minute))))
          (_ (format "%S" spec-or-string)))))))

;;; --- Next-fire computation -------------------------------------------------

(defun claude-dashboard--next-time-of-day (after hour minute &optional allowed-days)
  "Return the next encoded-time strictly after AFTER at HOUR:MINUTE.
If ALLOWED-DAYS (list of 0=Sun..6=Sat) is non-nil, restrict to those.
Returns nil if no slot found within 14 days (shouldn't happen with
sane inputs)."
  (let* ((decoded (decode-time after))
         (try (encode-time
               (list 0 minute hour
                     (decoded-time-day decoded)
                     (decoded-time-month decoded)
                     (decoded-time-year decoded)
                     nil nil
                     (decoded-time-zone decoded)))))
    (catch 'found
      (dotimes (_ 14)
        (let ((dow (decoded-time-weekday (decode-time try))))
          (when (and (time-less-p after try)
                     (or (null allowed-days) (memq dow allowed-days)))
            (throw 'found try))
          (setq try (time-add try (seconds-to-time 86400)))))
      nil)))

(defun claude-dashboard--recur-next-fire (spec &optional after)
  "Return next encoded-time strictly after AFTER (or now) matching SPEC."
  (let ((after (or after (current-time))))
    (pcase (plist-get spec :type)
      (:every
       (time-add after (seconds-to-time (plist-get spec :seconds))))
      (:daily
       (claude-dashboard--next-time-of-day
        after (plist-get spec :hour) (plist-get spec :minute) nil))
      (:weekly
       (claude-dashboard--next-time-of-day
        after (plist-get spec :hour) (plist-get spec :minute)
        (plist-get spec :days)))
      (k (user-error "Unknown recurrence type: %S" k)))))

;;; --- Persistence ----------------------------------------------------------

(defun claude-dashboard--write-recurring ()
  "Persist the recurring table to disk."
  (claude-dashboard--write-lisp-data
   claude-dashboard-recurring-file
   (cl-loop for r being the hash-values of claude-dashboard--recurring
            collect (list :id          (claude-dashboard-recurring-id r)
                          :action-type (claude-dashboard-recurring-action-type r)
                          :spec-string (claude-dashboard-recurring-spec-string r)
                          :spec        (claude-dashboard-recurring-spec r)
                          :payload     (claude-dashboard-recurring-payload r)
                          :last-fired  (claude-dashboard-recurring-last-fired r)
                          :enabled     (claude-dashboard-recurring-enabled r)
                          :created     (claude-dashboard-recurring-created r)))))

;;; --- Delivery -------------------------------------------------------------

(defun claude-dashboard--fire-recurring-send (payload)
  "Reuse the pending-send delivery path for a recurring :send."
  (let* ((id (claude-dashboard--make-id))
         (p (make-claude-dashboard-pending-send
             :id id
             :cwd (plist-get payload :cwd)
             :sid (plist-get payload :sid)
             :message (plist-get payload :message)
             :scheduled (current-time)
             :created (current-time))))
    (puthash id p claude-dashboard--pending-sends)
    (claude-dashboard--write-pending-sends)
    (claude-dashboard--deliver-pending id)))

(defun claude-dashboard--fire-recurring-launch (action-type payload)
  "Reuse the pending-launch delivery path for a recurring launch.
ACTION-TYPE is :launch, :launch-worktree, or :launch-resume."
  (let* ((id (claude-dashboard--make-id))
         (kind (pcase action-type
                 (:launch-worktree :worktree)
                 (_ :plain)))
         (extra-args
          (pcase action-type
            (:launch-resume
             (list "--resume" (plist-get payload :sid)))
            (_ (plist-get payload :extra-args))))
         (p (make-claude-dashboard-pending-launch
             :id id :kind kind
             :cwd (plist-get payload :cwd)
             :extra-args extra-args
             :branch (plist-get payload :branch)
             :initial-message (plist-get payload :initial-message)
             :scheduled (current-time)
             :created (current-time))))
    (puthash id p claude-dashboard--pending-launches)
    (claude-dashboard--write-pending-launches)
    (claude-dashboard--deliver-pending-launch id)))

(defun claude-dashboard--deliver-recurring (id)
  "Fire the recurring entry ID, then re-arm for the next occurrence."
  (let ((r (gethash id claude-dashboard--recurring)))
    (when r
      ;; Fire the underlying action, but only if enabled.  Disabled
      ;; entries still re-arm so they resume cleanly when toggled back on.
      (when (claude-dashboard-recurring-enabled r)
        (condition-case err
            (pcase (claude-dashboard-recurring-action-type r)
              (:send
               (claude-dashboard--fire-recurring-send
                (claude-dashboard-recurring-payload r)))
              ((or :launch :launch-worktree :launch-resume)
               (claude-dashboard--fire-recurring-launch
                (claude-dashboard-recurring-action-type r)
                (claude-dashboard-recurring-payload r)))
              (k (error "Unknown recurring action-type: %S" k)))
          (error (message "claude-dashboard: recurring %s failed: %S"
                          (substring id 0 (min 8 (length id))) err))))
      ;; Advance bookkeeping + arm the next fire.
      (setf (claude-dashboard-recurring-last-fired r) (current-time))
      (let ((next (claude-dashboard--recur-next-fire
                   (claude-dashboard-recurring-spec r) (current-time))))
        (setf (claude-dashboard-recurring-next-fire r) next
              (claude-dashboard-recurring-timer r)
              (and next
                   (run-at-time next nil
                                #'claude-dashboard--deliver-recurring id))))
      (claude-dashboard--write-recurring))))

;;; --- Public commands -------------------------------------------------------

(defun claude-dashboard--register-recurring (action-type spec-string payload)
  "Helper: build, register, persist, and arm a recurring entry.
Returns its id."
  (let* ((spec (claude-dashboard--parse-recur-spec spec-string))
         (next (claude-dashboard--recur-next-fire spec (current-time)))
         (id (claude-dashboard--make-id))
         (r (make-claude-dashboard-recurring
             :id id
             :action-type action-type
             :spec-string spec-string
             :spec spec
             :payload payload
             :last-fired nil
             :next-fire next
             :enabled t
             :created (current-time))))
    (setf (claude-dashboard-recurring-timer r)
          (and next
               (run-at-time next nil
                            #'claude-dashboard--deliver-recurring id)))
    (puthash id r claude-dashboard--recurring)
    (claude-dashboard--write-recurring)
    (message "claude-dashboard: recurring %s scheduled — next fire %s (id %s)"
             action-type
             (claude-dashboard--format-when next)
             (substring id 0 (min 8 (length id))))
    id))

;;;###autoload
(defun claude-dashboard-schedule-recurring-send (instance message recur-spec)
  "Send MESSAGE to INSTANCE on a recurring schedule (RECUR-SPEC).
At each occurrence, delivery uses the same busy/idle defer logic as a
one-shot scheduled send — if the target is offline at fire time, that
occurrence is skipped (the next one still fires)."
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
                   "Recurring send to: " (mapcar #'car table)
                   nil t nil nil default-label))
          (inst (cdr (assoc chosen table)))
          (msg (read-string "Message: "))
          (rec (read-string
                "Recurrence (e.g. weekdays 9:00, daily 14:00, every 30m): ")))
     (list inst msg rec)))
  (when (string-empty-p (string-trim message))
    (user-error "Empty message"))
  (claude-dashboard--register-recurring
   :send recur-spec
   (list :cwd (and (claude-dashboard-instance-cwd instance)
                   (expand-file-name
                    (claude-dashboard-instance-cwd instance)))
         :sid (or (and (fboundp 'claude-dashboard--live-session-id)
                       (claude-dashboard--live-session-id instance))
                  (claude-dashboard-instance-session-id instance))
         :message message)))

;;;###autoload
(defun claude-dashboard-schedule-recurring-launch (cwd recur-spec
                                                       &optional initial-message
                                                       extra-args)
  "Cold-launch claude in CWD on a recurring schedule (RECUR-SPEC).
INITIAL-MESSAGE, if given, is delivered after each launch settles
\(see `claude-dashboard-pending-launch-followup-delay').
EXTRA-ARGS are passed to claude on every launch."
  (interactive
   (let* ((cwd (claude-dashboard--read-project))
          (rec (read-string
                "Recurrence (e.g. weekdays 9:00, daily 14:00, every 30m): "))
          (msg (read-string "Initial message (empty = none): ")))
     (list cwd rec
           (and (not (string-empty-p (string-trim msg))) msg)
           nil)))
  (claude-dashboard--register-recurring
   :launch recur-spec
   (list :cwd (expand-file-name cwd)
         :extra-args extra-args
         :initial-message initial-message)))

;;;###autoload
(defun claude-dashboard-schedule-recurring-launch-worktree
    (source-cwd branch recur-spec &optional initial-message)
  "Recurring `claude-dashboard-new-worktree' SOURCE-CWD BRANCH.
Each occurrence creates a NEW worktree branch — careful with this one.
The BRANCH name should usually reference the schedule itself (date
template substitution is a TODO), or you'll get conflicts on the
second fire.  Useful for one-shot \"create today's work branch at
9am\" workflows when paired with a date template, less useful as a
naive recurring action."
  (interactive
   (list (claude-dashboard--read-project)
         (read-string "Branch / worktree name (will be reused each fire!): ")
         (read-string "Recurrence: ")
         (let ((m (read-string "Initial message (empty = none): ")))
           (and (not (string-empty-p (string-trim m))) m))))
  (when (or (null branch) (string-empty-p (string-trim branch)))
    (user-error "Branch name is required"))
  (claude-dashboard--register-recurring
   :launch-worktree recur-spec
   (list :cwd (expand-file-name source-cwd)
         :branch (string-trim branch)
         :initial-message initial-message)))

;;;###autoload
(defun claude-dashboard-cancel-recurring (id)
  "Cancel the recurring schedule with ID."
  (interactive
   (let ((cands (cl-loop for r being the hash-values
                         of claude-dashboard--recurring
                         collect (cons (format "%s  %s  %s%s"
                                               (claude-dashboard-recurring-spec-string r)
                                               (claude-dashboard-recurring-action-type r)
                                               (or (plist-get
                                                    (claude-dashboard-recurring-payload r)
                                                    :cwd) "?")
                                               (if (claude-dashboard-recurring-enabled r)
                                                   "" " [paused]"))
                                       (claude-dashboard-recurring-id r)))))
     (when (null cands) (user-error "No recurring schedules"))
     (list (cdr (assoc (completing-read "Cancel recurring: "
                                        (mapcar #'car cands) nil t)
                       cands)))))
  (let ((r (gethash id claude-dashboard--recurring)))
    (when (and r (claude-dashboard-recurring-timer r))
      (cancel-timer (claude-dashboard-recurring-timer r)))
    (remhash id claude-dashboard--recurring)
    (claude-dashboard--write-recurring)
    (message "claude-dashboard: cancelled recurring %s"
             (substring id 0 (min 8 (length id))))))

;;;###autoload
(defun claude-dashboard-toggle-recurring (id)
  "Pause / resume the recurring schedule with ID.
A paused entry keeps re-arming its timer but skips the action at
fire time, so toggling it back to enabled resumes cleanly without
losing the cadence."
  (interactive
   (let ((cands (cl-loop for r being the hash-values
                         of claude-dashboard--recurring
                         collect (cons (format "[%s] %s %s"
                                               (if (claude-dashboard-recurring-enabled r)
                                                   "ON " "OFF")
                                               (claude-dashboard-recurring-spec-string r)
                                               (claude-dashboard-recurring-action-type r))
                                       (claude-dashboard-recurring-id r)))))
     (when (null cands) (user-error "No recurring schedules"))
     (list (cdr (assoc (completing-read "Toggle: "
                                        (mapcar #'car cands) nil t)
                       cands)))))
  (let ((r (gethash id claude-dashboard--recurring)))
    (when r
      (setf (claude-dashboard-recurring-enabled r)
            (not (claude-dashboard-recurring-enabled r)))
      (claude-dashboard--write-recurring)
      (message "claude-dashboard: recurring %s now %s"
               (substring id 0 (min 8 (length id)))
               (if (claude-dashboard-recurring-enabled r)
                   "ENABLED" "PAUSED")))))

(defun claude-dashboard--restore-recurring ()
  "Re-arm timers for persisted recurring schedules.  Idempotent."
  (unless claude-dashboard--recurring-restored
    (setq claude-dashboard--recurring-restored t)
    (let ((count 0))
      (dolist (e (claude-dashboard--read-lisp-data
                  claude-dashboard-recurring-file))
        (let* ((id (plist-get e :id))
               (spec (plist-get e :spec))
               (next (claude-dashboard--recur-next-fire spec (current-time)))
               (r (make-claude-dashboard-recurring
                   :id id
                   :action-type (plist-get e :action-type)
                   :spec-string (plist-get e :spec-string)
                   :spec spec
                   :payload (plist-get e :payload)
                   :last-fired (plist-get e :last-fired)
                   :next-fire next
                   :enabled (plist-get e :enabled)
                   :created (plist-get e :created))))
          (puthash id r claude-dashboard--recurring)
          (setf (claude-dashboard-recurring-timer r)
                (and next
                     (run-at-time next nil
                                  #'claude-dashboard--deliver-recurring id)))
          (cl-incf count)))
      (when (> count 0)
        (message "claude-dashboard: restored %d recurring schedule(s)" count)))))

;; Hook into the existing resume command so the user only has to run one.
(advice-add 'claude-dashboard-resume-pending-sends :after
            #'claude-dashboard--restore-recurring)

;;; --- List buffer -----------------------------------------------------------

(defvar claude-dashboard-recurring-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "+" #'claude-dashboard-recurring--new-at-point)
    (define-key map "d" #'claude-dashboard-recurring--cancel-at-point)
    (define-key map "t" #'claude-dashboard-recurring--toggle-at-point)
    (define-key map "v" #'claude-dashboard-recurring--view-at-point)
    (define-key map (kbd "RET") #'claude-dashboard-recurring--view-at-point)
    (define-key map "g" #'claude-dashboard-recurring-refresh)
    map)
  "Keymap for `claude-dashboard-recurring-mode'.")

(define-derived-mode claude-dashboard-recurring-mode tabulated-list-mode
  "ClaudeRecur"
  "Major mode listing claude-dashboard recurring schedules."
  (setq tabulated-list-format
        [("State"     6 t)
         ("Recur"    18 t)
         ("Action"   16 t)
         ("Next fire" 18 t)
         ("Detail"    0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "Next fire" nil))
  (tabulated-list-init-header))

(defun claude-dashboard--row-for-recurring (r)
  "Build a tabulated-list row for recurring R."
  (let* ((payload (claude-dashboard-recurring-payload r))
         (action (claude-dashboard-recurring-action-type r))
         (detail
          (pcase action
            (:send (format "%s — %.60s"
                           (or (plist-get payload :cwd) "?")
                           (or (plist-get payload :message) "")))
            (:launch (format "%s%s%s"
                             (or (plist-get payload :cwd) "?")
                             (if-let ((a (plist-get payload :extra-args)))
                                 (format " %S" a) "")
                             (if-let ((m (plist-get payload :initial-message)))
                                 (format " — %.40s" m) "")))
            (:launch-worktree (format "%s @ %s%s"
                                      (plist-get payload :branch)
                                      (or (plist-get payload :cwd) "?")
                                      (if-let ((m (plist-get payload :initial-message)))
                                          (format " — %.40s" m) "")))
            (:launch-resume (format "%s --resume %s%s"
                                    (or (plist-get payload :cwd) "?")
                                    (or (plist-get payload :sid) "?")
                                    (if-let ((m (plist-get payload :initial-message)))
                                        (format " — %.40s" m) "")))
            (_ (format "%S" action)))))
    (list (claude-dashboard-recurring-id r)
          (vector
           (if (claude-dashboard-recurring-enabled r) "on" "PAUSE")
           (claude-dashboard-recurring-spec-string r)
           (symbol-name action)
           (if-let ((nf (claude-dashboard-recurring-next-fire r)))
               (claude-dashboard--format-when nf)
             "—")
           detail))))

(defun claude-dashboard-recurring-refresh ()
  "Repopulate the recurring list buffer."
  (interactive)
  (setq tabulated-list-entries
        (cl-loop for r being the hash-values of claude-dashboard--recurring
                 collect (claude-dashboard--row-for-recurring r)))
  (tabulated-list-print t))

;;;###autoload
(defun claude-dashboard-list-recurring ()
  "Open a tabulated-list buffer of all recurring schedules."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Recurring*")))
    (with-current-buffer buf
      (claude-dashboard-recurring-mode)
      (claude-dashboard-recurring-refresh))
    (pop-to-buffer buf)))

(defun claude-dashboard-recurring--id-at-point ()
  (or (tabulated-list-get-id)
      (user-error "No recurring entry on this line")))

(defun claude-dashboard-recurring--cancel-at-point ()
  (interactive)
  (claude-dashboard-cancel-recurring
   (claude-dashboard-recurring--id-at-point))
  (claude-dashboard-recurring-refresh))

(defun claude-dashboard-recurring--toggle-at-point ()
  (interactive)
  (claude-dashboard-toggle-recurring
   (claude-dashboard-recurring--id-at-point))
  (claude-dashboard-recurring-refresh))

(defun claude-dashboard-recurring--new-at-point ()
  "Prompt for a new recurring schedule kind, then invoke its command."
  (interactive)
  (let ((kind (completing-read
               "New recurring (kind): "
               '("send" "launch" "launch-worktree") nil t)))
    (call-interactively
     (intern (concat "claude-dashboard-schedule-recurring-" kind))))
  (claude-dashboard-recurring-refresh))

(defun claude-dashboard-recurring--view-at-point ()
  "Pop a buffer with the full detail of the recurring entry at point."
  (interactive)
  (let* ((id (claude-dashboard-recurring--id-at-point))
         (r (gethash id claude-dashboard--recurring)))
    (unless r (user-error "Entry no longer exists"))
    (let ((buf (get-buffer-create
                (format "*Claude Recurring %s*"
                        (substring id 0 (min 8 (length id)))))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Id:          %s\n" id))
          (insert (format "State:       %s\n"
                          (if (claude-dashboard-recurring-enabled r) "enabled"
                            "PAUSED")))
          (insert (format "Action:      %s\n"
                          (claude-dashboard-recurring-action-type r)))
          (insert (format "Recurrence:  %s\n"
                          (claude-dashboard-recurring-spec-string r)))
          (insert (format "  parsed:    %S\n"
                          (claude-dashboard-recurring-spec r)))
          (insert (format "Next fire:   %s\n"
                          (if-let ((n (claude-dashboard-recurring-next-fire r)))
                              (format-time-string "%Y-%m-%d %H:%M" n) "—")))
          (insert (format "Last fired:  %s\n"
                          (if-let ((l (claude-dashboard-recurring-last-fired r)))
                              (format-time-string "%Y-%m-%d %H:%M:%S" l)
                            "never")))
          (insert (format "Created:     %s\n"
                          (format-time-string
                           "%Y-%m-%d %H:%M:%S"
                           (claude-dashboard-recurring-created r))))
          (insert "\nPayload:\n")
          (pp (claude-dashboard-recurring-payload r) (current-buffer))
          (goto-char (point-min)))
        (special-mode))
      (display-buffer buf))))

;;; --- Dashboard integration -------------------------------------------------

(with-eval-after-load 'claude-dashboard
  (define-key claude-dashboard-mode-map "r"
              #'claude-dashboard-list-recurring))

(provide 'claude-dashboard-recurring)
;;; claude-dashboard-recurring.el ends here
