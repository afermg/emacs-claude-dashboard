;;; claude-dashboard-usage.el --- Monitor Claude usage limits + auto-resume -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "28.1") (claude-dashboard "0.1") (claude-dashboard-schedule "0.1"))

;;; Commentary:
;;
;; Scans each live claude instance's eat buffer for the TUI's
;; usage-limit warnings (5-hour session, weekly, Opus, Sonnet, overage)
;; and reacts according to `claude-dashboard-usage-mode':
;;
;;   :monitor      (default) — populate a per-instance usage cache;
;;                 expose via `M-x claude-dashboard-usage-list'.  No
;;                 actions taken.
;;
;;   :notify       — additionally fire `notifications-notify' on every
;;                 state transition (none → approaching → reached).
;;
;;   :auto-resume  — additionally, on first detection of a
;;                 `Approaching' warning with a parseable reset time,
;;                 auto-enqueue a `claude-dashboard-schedule-send'
;;                 with `claude-dashboard-usage-resume-message'
;;                 (default "continue") at
;;                 (reset-time + claude-dashboard-usage-resume-buffer-seconds).
;;                 Idempotent per (sid, reset-time) pair.
;;
;; Detection is buffer-scan based: claude does NOT log limit events to
;; its JSONL transcripts, so we have no choice but to match against the
;; rendered TUI text.  Patterns derived from the bundled binary at
;; /nix/store/.../claude-code-X.Y.Z/bin/.claude-unwrapped — see the
;; emacs-pair skill SKILL.md for the extraction recipe if patterns
;; need updating.
;;
;; Entry points:
;;   M-x claude-dashboard-usage-list      — current usage state, all instances
;;   M-x claude-dashboard-usage-now       — force a one-shot scan
;;
;; Configuration entry points:
;;   `claude-dashboard-usage-mode'
;;   `claude-dashboard-usage-resume-message'
;;   `claude-dashboard-usage-resume-buffer-seconds'
;;   `claude-dashboard-usage-patterns'

;;; Code:

(require 'cl-lib)
(require 'claude-dashboard)
(require 'claude-dashboard-schedule)
(require 'tabulated-list)

;;; --- Customs ---------------------------------------------------------------

(defcustom claude-dashboard-usage-mode :monitor
  "Reaction policy when a usage limit is detected.

  :monitor      — track state, expose via the list command.  Default.
                  Best while the patterns are still being validated.
  :notify       — additionally fire `notifications-notify' on
                  state transitions.
  :auto-resume  — additionally enqueue a `continue' send at the
                  parsed reset time + buffer seconds."
  :type '(choice (const :tag "Track only" :monitor)
                 (const :tag "Track + notify" :notify)
                 (const :tag "Track + notify + auto-resume" :auto-resume))
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-scan-interval 5
  "Seconds between background scans of live instances for limit text."
  :type 'number
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-tail-chars 4000
  "Characters from each instance's buffer tail to scan for limit text.
4000 covers the warning + a few rows of conversation; bump if claude
buffers a lot of output between the warning and the prompt."
  :type 'integer
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-resume-message "continue"
  "Message body sent at reset time when `claude-dashboard-usage-mode'
is `:auto-resume'."
  :type 'string
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-resume-buffer-seconds 90
  "Seconds added to the parsed reset time before firing the resume.
A small buffer avoids racing the limit window — claude's reset is
rounded to the minute, so firing at the exact reset can occasionally
get caught by the same limit."
  :type 'integer
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-kind-labels
  '(("session limit"        . session)
    ("weekly limit"         . weekly)
    ("usage limit"          . usage)
    ("extra usage limit"    . overage)
    ("Opus limit"           . opus)
    ("Sonnet limit"         . sonnet))
  "Map of TUI-displayed limit labels to internal symbols.
Labels match those rendered by claude code (extracted from the
bundled binary's SE1 map).  If claude introduces a new label, add it
here so the scanner classifies it instead of falling through to
`other'."
  :type '(alist :key-type string :value-type symbol)
  :group 'claude-dashboard)

(defcustom claude-dashboard-usage-patterns
  '(;; Approaching warning (with reset time).
    (approaching
     .
     "^[[:space:]]*Approaching \\([A-Za-z ]+limit\\)[[:space:]]+\
·[[:space:]]+resets[[:space:]]+\\([^·\n]+?\\)\
\\(?:[[:space:]]+·\\|[[:space:]]*$\\)")
    ;; Utilization warning (with %).
    (utilization
     .
     "^[[:space:]]*You've used \\([0-9]+\\)% of your \
\\([A-Za-z ]+limit\\)\
\\(?:[[:space:]]+·[[:space:]]+resets[[:space:]]+\
\\([^·\n]+?\\)\
\\(?:[[:space:]]+·\\|[[:space:]]*$\\)\\)?")
    ;; Hard rejection — no reset time in the same line.
    (reached
     .
     "^[[:space:]]*usage limit reached"))
  "Alist `(STATE . REGEXP)' for limit-state detection.
STATE is `approaching', `utilization', or `reached'.  Regexps are
anchored to start-of-line so user-typed text matching the substring
doesn't trigger detection.

Group captures depend on STATE:
  approaching  : 1=label    2=when-text
  utilization  : 1=percent  2=label  3=when-text (optional)
  reached      : (none)

The middle-dot character is U+00B7 — claude renders it literally in
the TUI between segments.  The patterns also accept the ASCII bullet
`*' as a fallback for terminals that down-translate the codepoint."
  :type '(alist :key-type symbol :value-type regexp)
  :group 'claude-dashboard)

;;; --- Data ------------------------------------------------------------------

(cl-defstruct claude-dashboard-usage
  ;; STATE: nil | 'approaching | 'utilization | 'reached
  state
  ;; KIND: 'session | 'weekly | 'usage | 'overage | 'opus | 'sonnet | 'other
  kind
  ;; KIND-LABEL: original human label string from the TUI
  kind-label
  ;; PCT: integer 0-100 if STATE = 'utilization, else nil
  pct
  ;; WHEN-TEXT: raw string captured from the buffer ("9pm", "tomorrow at 6am", ...)
  when-text
  ;; RESET-TIME: encoded-time parsed from WHEN-TEXT, or nil if unparseable
  reset-time
  ;; DETECTED-AT: encoded-time when this row was first observed
  detected-at)

(defvar claude-dashboard--usage-cache (make-hash-table :test 'eq)
  "Map: instance buffer -> latest claude-dashboard-usage struct (or nil).")

(defvar claude-dashboard--usage-actioned (make-hash-table :test 'equal)
  "Set: keys (sid . reset-text) we've already auto-actioned.
Prevents the 5-second scanner from re-enqueuing the same resume on
every tick while the warning text remains in the buffer.")

(defvar claude-dashboard--usage-timer nil
  "Background timer running `claude-dashboard-usage--refresh-all'.")

;;; --- Reset-time parser -----------------------------------------------------
;;
;; Claude renders reset times in compact human form (`9pm', `5:30 PM',
;; `tomorrow at 9am', `in 2 hours').  We try a series of patterns; first
;; match wins.  Anything that doesn't parse leaves `reset-time' as nil
;; and the user can still see the raw text via the list command.

(defun claude-dashboard-usage--parse-when (text)
  "Parse TEXT (claude's reset-time string) into encoded-time or nil."
  (when (stringp text)
    (let ((s (string-trim text))
          (now (current-time)))
      (or
       ;; "in N (hours|minutes)"
       (when (string-match
              "\\`in[[:space:]]+\\([0-9]+\\)[[:space:]]+\
\\(hour\\|minute\\)s?\\'" s)
         (let* ((n (string-to-number (match-string 1 s)))
                (unit (match-string 2 s))
                (sec (* n (if (equal unit "hour") 3600 60))))
           (time-add now (seconds-to-time sec))))
       ;; "tomorrow at <H>(am|pm)" / "tomorrow at <H>:<MM>(am|pm)"
       (when (string-match
              "\\`tomorrow[[:space:]]+at[[:space:]]+\
\\([0-9]\\{1,2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?[[:space:]]*\
\\(am\\|pm\\|AM\\|PM\\)?\\'" s)
         (claude-dashboard-usage--at-clock-time
          (string-to-number (match-string 1 s))
          (string-to-number (or (match-string 2 s) "0"))
          (match-string 3 s)
          1))                  ; tomorrow
       ;; "<H>(am|pm)" / "<H>:<MM>(am|pm)" — today, roll to tomorrow if past
       (when (string-match
              "\\`\\([0-9]\\{1,2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?\
[[:space:]]*\\(am\\|pm\\|AM\\|PM\\)\\'" s)
         (claude-dashboard-usage--at-clock-time
          (string-to-number (match-string 1 s))
          (string-to-number (or (match-string 2 s) "0"))
          (match-string 3 s)
          0))
       ;; 24-hour "HH:MM"
       (when (string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'" s)
         (claude-dashboard-usage--at-clock-time
          (string-to-number (match-string 1 s))
          (string-to-number (match-string 2 s))
          nil 0))))))

(defun claude-dashboard-usage--at-clock-time (h m am-pm day-offset)
  "Build encoded-time at H:M today + DAY-OFFSET days.
AM-PM is `am'/`pm' (or nil for 24h).  When AM-PM is present, H is in
12-hour form.  If the resulting time is in the past *and DAY-OFFSET
is 0*, roll forward 24h."
  (let* ((h-24 (cond
                ((null am-pm) h)
                ((string-match-p "p" (downcase am-pm))
                 (if (= h 12) 12 (+ h 12)))
                (t (if (= h 12) 0 h))))
         (now (current-time))
         (decoded (decode-time now))
         (target (encode-time
                  (list 0 m h-24
                        (+ (decoded-time-day decoded) day-offset)
                        (decoded-time-month decoded)
                        (decoded-time-year decoded)
                        nil nil
                        (decoded-time-zone decoded)))))
    (if (and (zerop day-offset) (time-less-p target now))
        (time-add target (seconds-to-time 86400))
      target)))

;;; --- Scanner ---------------------------------------------------------------

(defun claude-dashboard-usage--label->kind (label)
  "Map a TUI label string to an internal symbol via
`claude-dashboard-usage-kind-labels'.  Falls back to `other'."
  (or (cdr (assoc-string label claude-dashboard-usage-kind-labels)) 'other))

(defun claude-dashboard-usage--scan-buffer (buf)
  "Scan BUF's tail for limit text. Return claude-dashboard-usage or nil."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (save-excursion
        (let* ((tail-start (max (point-min)
                                (- (point-max)
                                   claude-dashboard-usage-tail-chars)))
               (tail (buffer-substring-no-properties tail-start (point-max)))
               result)
          ;; Test patterns in priority order: reached > approaching >
          ;; utilization. The first match wins; we don't keep looking
          ;; for higher-severity hits beyond the first pattern's match.
          (cl-block scan
            ;; Reached (rejected) — priority 1.
            (when (string-match (alist-get 'reached
                                            claude-dashboard-usage-patterns)
                                tail)
              (setq result (make-claude-dashboard-usage
                            :state 'reached
                            :kind 'unknown
                            :kind-label "usage limit reached"
                            :detected-at (current-time)))
              (cl-return-from scan))
            ;; Approaching — priority 2.
            (when (string-match (alist-get 'approaching
                                            claude-dashboard-usage-patterns)
                                tail)
              (let* ((label (string-trim (match-string 1 tail)))
                     (when-text (string-trim (match-string 2 tail))))
                (setq result (make-claude-dashboard-usage
                              :state 'approaching
                              :kind (claude-dashboard-usage--label->kind label)
                              :kind-label label
                              :when-text when-text
                              :reset-time
                              (claude-dashboard-usage--parse-when when-text)
                              :detected-at (current-time))))
              (cl-return-from scan))
            ;; Utilization — priority 3.
            (when (string-match (alist-get 'utilization
                                            claude-dashboard-usage-patterns)
                                tail)
              (let* ((pct (string-to-number (match-string 1 tail)))
                     (label (string-trim (match-string 2 tail)))
                     (when-text (and (match-string 3 tail)
                                     (string-trim (match-string 3 tail)))))
                (setq result (make-claude-dashboard-usage
                              :state 'utilization
                              :kind (claude-dashboard-usage--label->kind label)
                              :kind-label label
                              :pct pct
                              :when-text when-text
                              :reset-time (and when-text
                                               (claude-dashboard-usage--parse-when
                                                when-text))
                              :detected-at (current-time))))))
          result)))))

(defun claude-dashboard-usage--refresh-all ()
  "Scan every live instance, update the cache, fire mode-dependent reactions."
  (dolist (inst (claude-dashboard--instances-list))
    (let* ((buf (claude-dashboard-instance-buffer inst))
           (before (gethash buf claude-dashboard--usage-cache))
           (after (claude-dashboard-usage--scan-buffer buf)))
      (puthash buf after claude-dashboard--usage-cache)
      ;; Only react on transitions, not on every tick while the warning
      ;; sits in the buffer.  A "transition" is: state changed, OR the
      ;; reset-time changed (a fresh window after a previous reset).
      (when (and after
                 (not (equal (and before (claude-dashboard-usage-state before))
                             (claude-dashboard-usage-state after)))
                 (not (equal (and before
                                  (claude-dashboard-usage-when-text before))
                             (claude-dashboard-usage-when-text after))))
        (claude-dashboard-usage--on-transition inst after)))))

;;;###autoload
(defun claude-dashboard-usage-now ()
  "Force a one-shot usage scan across all live instances."
  (interactive)
  (claude-dashboard-usage--refresh-all)
  (let ((hits (cl-count-if #'identity
                           (hash-table-values
                            claude-dashboard--usage-cache))))
    (message "claude-dashboard usage: scanned %d instance(s), %d with active limit text"
             (hash-table-count claude-dashboard--usage-cache)
             hits)))

;;; --- Reactions per mode ----------------------------------------------------

(defun claude-dashboard-usage--on-transition (inst usage)
  "Mode-dependent reaction when INST transitions to USAGE state."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (sid (or (and (fboundp 'claude-dashboard--live-session-id)
                       (claude-dashboard--live-session-id inst))
                  (claude-dashboard-instance-session-id inst)))
         (state (claude-dashboard-usage-state usage))
         (label (or (claude-dashboard-usage-kind-label usage) "limit"))
         (when-text (claude-dashboard-usage-when-text usage))
         (reset-time (claude-dashboard-usage-reset-time usage))
         (mode claude-dashboard-usage-mode))
    ;; Always emit a brief modeline message in monitor mode.
    (message "claude-dashboard usage: %s — %s%s"
             (buffer-name buf)
             (pcase state
               ('approaching (format "approaching %s%s" label
                                     (if when-text
                                         (format " (resets %s)" when-text)
                                       "")))
               ('utilization (format "%s%% of %s%s"
                                     (claude-dashboard-usage-pct usage)
                                     label
                                     (if when-text
                                         (format ", resets %s" when-text)
                                       "")))
               ('reached "LIMIT REACHED — agent is blocked")
               (s (format "%s" s)))
             "")
    ;; Notification (in :notify and :auto-resume modes).
    (when (and (memq mode '(:notify :auto-resume))
               (fboundp 'notifications-notify))
      (ignore-errors
        (notifications-notify
         :title (format "Claude usage: %s" (buffer-name buf))
         :body (pcase state
                 ('approaching
                  (format "Approaching %s%s" label
                          (if when-text (format " · resets %s" when-text) "")))
                 ('reached "Limit reached — agent is blocked")
                 (_ (format "%s" state)))
         :urgency (if (eq state 'reached) 'critical 'normal))))
    ;; Auto-resume (only :auto-resume).
    (when (and (eq mode :auto-resume)
               (eq state 'approaching)
               sid
               reset-time)
      (let ((key (cons sid when-text)))
        (unless (gethash key claude-dashboard--usage-actioned)
          (puthash key t claude-dashboard--usage-actioned)
          (let* ((fire-time
                  (time-add reset-time
                            (seconds-to-time
                             claude-dashboard-usage-resume-buffer-seconds))))
            (claude-dashboard-schedule-send
             inst
             claude-dashboard-usage-resume-message
             (format-time-string "%Y-%m-%d %H:%M" fire-time))
            (message
             "claude-dashboard usage: auto-resume queued for %s at %s (after %s)"
             (buffer-name buf)
             (format-time-string "%H:%M" fire-time)
             when-text)))))))

;;; --- List buffer -----------------------------------------------------------

(defvar claude-dashboard-usage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "g" #'claude-dashboard-usage-list-refresh)
    (define-key map "n" #'claude-dashboard-usage-now)
    map)
  "Keymap for `claude-dashboard-usage-list-mode'.")

(define-derived-mode claude-dashboard-usage-list-mode tabulated-list-mode
  "ClaudeUsage"
  "List buffer for `claude-dashboard-usage-list'."
  (setq tabulated-list-format
        [("Instance"  28 t)
         ("State"     12 t)
         ("Limit"     16 t)
         ("Pct"        5 t)
         ("Resets in" 28 nil)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun claude-dashboard-usage-list-refresh ()
  "Repopulate the *Claude Usage* buffer from the cache."
  (interactive)
  (claude-dashboard-usage--refresh-all)
  (setq tabulated-list-entries
        (cl-loop
         for buf being the hash-keys of claude-dashboard--usage-cache
         using (hash-values usage)
         when (buffer-live-p buf)
         collect
         (let* ((state (and usage (claude-dashboard-usage-state usage)))
                (label (and usage (claude-dashboard-usage-kind-label usage)))
                (pct (and usage (claude-dashboard-usage-pct usage)))
                (when-text (and usage (claude-dashboard-usage-when-text usage)))
                (reset-time (and usage (claude-dashboard-usage-reset-time usage)))
                (resets-display
                 (cond ((and reset-time when-text)
                        (format "%s (parsed: %s)"
                                when-text
                                (format-time-string "%a %H:%M" reset-time)))
                       (when-text (format "%s (unparsed)" when-text))
                       (t "—"))))
           (list (buffer-name buf)
                 (vector (buffer-name buf)
                         (pcase state
                           ('approaching
                            (propertize "approaching" 'face 'warning))
                           ('utilization
                            (propertize "warn" 'face 'warning))
                           ('reached
                            (propertize "REACHED" 'face 'error))
                           (_ "ok"))
                         (or label "—")
                         (if pct (format "%d%%" pct) "—")
                         resets-display)))))
  (tabulated-list-print t))

;;;###autoload
(defun claude-dashboard-usage-list ()
  "Open the *Claude Usage* list buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Usage*")))
    (with-current-buffer buf
      (claude-dashboard-usage-list-mode)
      (claude-dashboard-usage-list-refresh))
    (pop-to-buffer buf)))

;;; --- Background timer -----------------------------------------------------

(defun claude-dashboard-usage--ensure-timer ()
  "Start the background scan timer if not already running."
  (unless (and claude-dashboard--usage-timer
               (memq claude-dashboard--usage-timer timer-list))
    (setq claude-dashboard--usage-timer
          (run-with-timer
           claude-dashboard-usage-scan-interval
           claude-dashboard-usage-scan-interval
           #'claude-dashboard-usage--refresh-all))))

(defun claude-dashboard-usage--cancel-timer ()
  "Stop the background scan timer."
  (when claude-dashboard--usage-timer
    (cancel-timer claude-dashboard--usage-timer)
    (setq claude-dashboard--usage-timer nil)))

;; Auto-start the timer once this module loads.
(claude-dashboard-usage--ensure-timer)

;;; --- Dashboard integration -------------------------------------------------

(with-eval-after-load 'claude-dashboard
  (define-key claude-dashboard-mode-map "U" #'claude-dashboard-usage-list))

(provide 'claude-dashboard-usage)
;;; claude-dashboard-usage.el ends here
