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

;;; --- Backend selection ---------------------------------------------------
;;
;; The dashboard was originally Claude-specific; it now multiplexes over
;; backend CLIs that follow the same shape (a TUI agent, a per-user state
;; directory with per-project session transcripts, a --resume / --continue
;; convention).  `claude-dashboard-backend' picks which one is active for
;; this Emacs session; `claude-dashboard-backends' is the registry the
;; rest of the file dispatches against.  Claude remains the default —
;; switching is a single defcustom change.
;;
;; Adding a new backend means: append an entry to `claude-dashboard-backends'
;; with the keys documented in its docstring, and (when feature parity
;; matters) implement the transcript-reader hooks.  The accessor helpers
;; (`claude-dashboard--backend-prop' etc.) below are the only callers that
;; need to know about the registry.

(defcustom claude-dashboard-backend 'claude
  "Active backend CLI for the dashboard.
A symbol whose `assq' lookup against `claude-dashboard-backends'
yields the running backend's plist.  Claude is the default; the
other shipped backends are `opencode' (SQLite transcripts) and
`codex' (rollout JSONL).  Per-instance backend is captured at
launch time and stored on the instance struct, so changing this
defcustom only affects *new* sessions — existing rows keep
dispatching through the backend they were launched against."
  :type '(choice (const :tag "Claude Code" claude)
                 (const :tag "opencode" opencode)
                 (const :tag "codex" codex)
                 (symbol :tag "Other"))
  :group 'claude-dashboard)

(defcustom claude-dashboard-backends
  `((claude
     :program          "claude"
     :state-dir        ,(expand-file-name "~/.claude")
     :spinner-regexp   "esc to interrupt"
     :resume-flag      "--resume"
     :continue-flag    "--continue"
     :worktree-subdir  ".claude/worktrees"
     :transcript-style jsonl
     :badge            "C"
     :badge-color      "#61afef"
     :supports-auto-name t
     :session-id-fn    claude-dashboard--claude-session-id-fn
     :session-name-fn  claude-dashboard--claude-session-name-fn
     :transcript-path-fn claude-dashboard--claude-transcript-path-fn
     :transcript-walk-fn claude-dashboard--claude-transcript-walk-fn
     :list-sessions-fn claude-dashboard--claude-list-sessions-fn
     :rename-fn        claude-dashboard--claude-rename-fn)
    (opencode
     :program          "opencode"
     :state-dir        ,(expand-file-name "~/.local/share/opencode")
     ;; Opencode's TUI spinner phrasing is not yet mapped; this regex
     ;; intentionally matches nothing so a running opencode session shows
     ;; as IDL rather than flapping.  Override per-backend once the real
     ;; marker is known.
     :spinner-regexp   "\\`a\\`"
     :resume-flag      "--session"
     :continue-flag    "--continue"
     :worktree-subdir  ".opencode/worktrees"
     :transcript-style sqlite
     :badge            "O"
     :badge-color      "#e5c07b"
     :supports-auto-name nil
     :session-id-fn    claude-dashboard--opencode-session-id-fn
     :session-name-fn  claude-dashboard--opencode-session-name-fn
     :transcript-path-fn claude-dashboard--opencode-transcript-path-fn
     :transcript-walk-fn claude-dashboard--opencode-transcript-walk-fn
     :list-sessions-fn claude-dashboard--opencode-list-sessions-fn
     :rename-fn        nil)
    (codex
     :program          "codex"
     :state-dir        ,(expand-file-name "~/.codex")
     :spinner-regexp   "esc to interrupt\\|Working\\|Thinking"
     :resume-flag      "resume"
     :continue-flag    "resume"
     :worktree-subdir  ".codex/worktrees"
     :transcript-style rollout
     :badge            "X"
     :badge-color      "#98c379"
     :supports-auto-name t
     :session-id-fn    claude-dashboard--codex-session-id-fn
     :session-name-fn  claude-dashboard--codex-session-name-fn
     :transcript-path-fn claude-dashboard--codex-transcript-path-fn
     :transcript-walk-fn claude-dashboard--codex-transcript-walk-fn
     :list-sessions-fn claude-dashboard--codex-list-sessions-fn
     :rename-fn        claude-dashboard--codex-rename-fn))
  "Registry of supported backend CLIs.
Each entry is `(NAME . PLIST)' where PLIST has at least the
following static slots:

  :program          Executable name used to launch a session.
  :state-dir        Per-user state directory the backend writes to.
  :spinner-regexp   Regex matched in the eat tail to detect `running'.
  :resume-flag      CLI flag for resuming a session by id.
  :continue-flag    CLI flag for resuming the most recent session.
  :worktree-subdir  Relative path under the main worktree where new
                    branch worktrees are created.
  :transcript-style Symbol describing how this backend stores session
                    transcripts (`jsonl' for claude, `sqlite' for
                    opencode, `rollout' for codex).
  :badge            One-glyph backend tag rendered before TOPIC.
  :badge-color      Hex color for the badge.
  :supports-auto-name  Whether the auto-`/name'-after-N-turns workflow
                    is relevant for this backend.

And these function slots (each a SYMBOL naming a defun, or nil
for unsupported):

  :session-id-fn    (INST) → SID string or nil.  Live session-id
                    discovery for the running INST (typically from
                    per-PID state, or by mtime-scanning the state dir
                    for the freshest session whose cwd matches).
  :session-name-fn  (INST) → user-set name (post-`/rename') or nil.
  :transcript-path-fn (CWD SID) → transcript file path or nil.
  :transcript-walk-fn (PATH) → list of normalized messages, each an
                    alist `((role . SYM) (text . STR) (ts . FLOAT)
                            (raw . OBJ))', iterated chronologically.
                    Backend-agnostic column extractors consume this.
  :list-sessions-fn () → list of `claude-dashboard-past-session'
                    structs, newest-first.
  :rename-fn        (PROC SLUG) → non-nil on successful injection;
                    nil when the backend has no rename slash command."
  :type '(alist :key-type symbol
                :value-type (plist :key-type symbol :value-type sexp))
  :group 'claude-dashboard)

(defun claude-dashboard--backend-plist (&optional name)
  "Return the plist for backend NAME (or the active backend)."
  (or (cdr (assq (or name claude-dashboard-backend)
                 claude-dashboard-backends))
      (cdr (assq 'claude claude-dashboard-backends))))

(defun claude-dashboard--backend-prop (key &optional name)
  "Look up KEY in backend NAME's plist (or the active backend's)."
  (plist-get (claude-dashboard--backend-plist name) key))

(defun claude-dashboard--backend-call (slot backend &rest args)
  "Invoke BACKEND's SLOT function with ARGS, returning its result or nil.
SLOT must name a function-slot (e.g. `:session-id-fn').  When the
slot is nil or its function is not bound the call is a no-op."
  (let ((fn (claude-dashboard--backend-prop slot backend)))
    (when (and fn (fboundp fn))
      (apply fn args))))

(defun claude-dashboard--instance-backend (inst)
  "Return INST's backend symbol, falling back to the active default."
  (or (and (claude-dashboard-instance-p inst)
           (claude-dashboard-instance-backend inst))
      claude-dashboard-backend))

(defun claude-dashboard--inst-transcript-path (inst &optional sid)
  "Return INST's session transcript path via its backend, or nil.
SID defaults to the live session-id (falling back to the cached
struct slot)."
  (let* ((backend (claude-dashboard--instance-backend inst))
         (sid (or sid
                  (and (fboundp 'claude-dashboard--live-session-id)
                       (claude-dashboard--live-session-id inst))
                  (claude-dashboard-instance-session-id inst)))
         (cwd (claude-dashboard-instance-cwd inst)))
    (and sid (claude-dashboard--backend-call
              :transcript-path-fn backend cwd sid))))

(defun claude-dashboard--inst-walk-messages (inst &optional sid)
  "Return a chronological normalized message list for INST's session.
Each element is an alist `((role . SYM) (text . STR) (ts . FLOAT)
\(raw . OBJ))'.  Dispatches through the backend's
`:transcript-walk-fn'.  Returns nil when the transcript path can't
be resolved or the backend has no walker."
  (when-let* ((path (claude-dashboard--inst-transcript-path inst sid)))
    (claude-dashboard--backend-call
     :transcript-walk-fn (claude-dashboard--instance-backend inst)
     path)))

(defcustom claude-dashboard-program nil
  "Executable used to launch a backend instance.
When nil (the default) the program name is taken from the active
backend's `:program' slot — this keeps Claude as the default and
lets `claude-dashboard-backend' switch the CLI without touching
this defcustom.  Set explicitly to override per-Emacs-session."
  :type '(choice (const :tag "From active backend" nil) string))

(defun claude-dashboard--program ()
  "Resolve the current program name (override → backend default)."
  (or claude-dashboard-program
      (claude-dashboard--backend-prop :program)))

(defcustom claude-dashboard-program-args nil
  "Extra arguments passed to the backend program on launch."
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

(defcustom claude-dashboard-claude-dir nil
  "Override for the backend's per-user state directory.
When nil (the default) the directory is taken from the active
backend's `:state-dir' slot — e.g. `~/.claude' for Claude,
`~/.local/share/opencode' for opencode.  Set to a directory to
pin it regardless of the active backend."
  :type '(choice (const :tag "From active backend" nil) directory))

(defun claude-dashboard--state-dir ()
  "Resolve the current state directory (override → backend default)."
  (or claude-dashboard-claude-dir
      (claude-dashboard--backend-prop :state-dir)))

;;; Data model

(cl-defstruct claude-dashboard-instance
  buffer cwd started-at last-output
  session-id model
  ;; Backend symbol (`claude', `opencode', `codex', ...) captured at launch
  ;; so per-row dispatch sees the backend the agent was actually started
  ;; against, even if the user later flips `claude-dashboard-backend' for
  ;; the next session.  Defaults to `claude' for legacy manifest entries
  ;; that pre-date this slot.
  (backend 'claude)
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

(defun claude-dashboard--count-user-turns (inst)
  "Return the number of user-role entries in INST's transcript, or 0."
  (cl-count-if (lambda (m) (eq (alist-get 'role m) 'user))
               (claude-dashboard--inst-walk-messages inst)))

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
  "Send `/name <slug>' (or backend equivalent) to INST when ready.
Worktree-launched instances use their registered branch name on first
idle; otherwise we wait `claude-dashboard-auto-name-after-turns' user
turns and derive a slug from the first prompt.  No-ops for backends
whose `:supports-auto-name' slot is nil or whose `:rename-fn' is
absent.  Fires once per buffer."
  (let* ((buf (claude-dashboard-instance-buffer inst))
         (cwd (claude-dashboard-instance-cwd inst))
         (backend (claude-dashboard--instance-backend inst))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst)))
         (proc (claude-dashboard--instance-process inst))
         (preassigned (and buf (gethash buf claude-dashboard--worktree-names))))
    (when (and buf (buffer-live-p buf) cwd proc (process-live-p proc)
               (claude-dashboard--backend-prop :supports-auto-name backend)
               (claude-dashboard--backend-prop :rename-fn backend)
               (not (gethash buf claude-dashboard--name-injected))
               (eq (claude-dashboard--status inst) 'idle)
               (or preassigned
                   (and claude-dashboard-auto-name-after-turns
                        sid
                        (null (claude-dashboard--session-name-from-transcript
                               inst sid))
                        (>= (claude-dashboard--count-user-turns inst)
                            claude-dashboard-auto-name-after-turns))))
      (let ((slug (or preassigned
                      (claude-dashboard--kebab-from-prompt
                       (claude-dashboard--first-prompt-from-transcript
                        inst)))))
        (when (and slug (not (string-empty-p slug)))
          (puthash buf t claude-dashboard--name-injected)
          (when (claude-dashboard--backend-call :rename-fn backend proc slug)
            (message "claude-dashboard: named %s → %s"
                     (buffer-name buf) slug)))))))

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
  "Manually send a rename command to the instance at point.
Prompts for a name (default derived from the session's first user
prompt).  Dispatches through the active backend's `:rename-fn';
signals when the backend does not support renaming."
  (interactive)
  (let* ((inst (claude-dashboard--current-instance))
         (backend (claude-dashboard--instance-backend inst))
         (default (or (claude-dashboard--kebab-from-prompt
                       (claude-dashboard--first-prompt-from-transcript inst))
                      ""))
         (name (read-string (format "rename (default %s): " default)
                            nil nil default))
         (proc (claude-dashboard--instance-process inst)))
    (unless (and proc (process-live-p proc))
      (user-error "Instance has no live process"))
    (unless (claude-dashboard--backend-prop :rename-fn backend)
      (user-error "Backend %s does not support renaming" backend))
    (if (claude-dashboard--backend-call :rename-fn backend proc name)
        (progn
          (puthash (claude-dashboard-instance-buffer inst) t
                   claude-dashboard--name-injected)
          (message "Sent rename %s to %s" name
                   (buffer-name (claude-dashboard-instance-buffer inst))))
      (user-error "Rename injection failed"))))

;;; --- Phase classification ------------------------------------------------
;;
;; Three phases:
;;   `exited'   OS process is gone.
;;   `running'  Spinner (`esc to interrupt') visible in the eat tail.
;;   `idle'     Process alive, no spinner.
;;
;; Earlier versions tried to detect `awaiting' (a pending menu / question)
;; and `monitoring' (polling / sleeping); both proved unreliable enough
;; that they misclassified more often than they helped, so they're gone.

(defcustom claude-dashboard-fit-window t
  "Resize the dashboard's window to its content after each render.
When non-nil, the dashboard is docked as a side window at
`claude-dashboard-side' and its height is fit to the visible
content (heading + column header + one line per instance).
Set to nil to let your usual window-management rules size it."
  :type 'boolean :group 'claude-dashboard)

(defcustom claude-dashboard-fit-min-height 4
  "Minimum number of lines the dashboard window may shrink to."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-fit-max-height nil
  "Maximum number of lines the dashboard window may grow to.
When nil, the dashboard is sized to `2 + N' where N is the number
of currently-tracked instances — so the window always shows the
instance rows and nothing else, regardless of how many query
sections happen to be expanded.  An integer pins the cap to that
many rows instead."
  :type '(choice (const :tag "Auto: 2 + N instances" nil) integer)
  :group 'claude-dashboard)

(defcustom claude-dashboard-side 'bottom
  "Frame side the dashboard occupies when `claude-dashboard-fit-window' is on.
One of `top' or `bottom'.  Side windows give `fit-window-to-buffer'
something to shrink against (the rest of the frame), so the
dashboard ends up at the minimum height that shows all rows."
  :type '(choice (const top) (const bottom)) :group 'claude-dashboard)

(defcustom claude-dashboard-tail-chars 2000
  "Trailing eat-buffer chars used by `claude-dashboard--status'.
Wide enough to catch the spinner across the framing borders that may
sit between it and point-max."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-spinner-regexp nil
  "Override for the running-spinner regexp.
When nil (the default) the regexp is taken from the active
backend's `:spinner-regexp' slot — Claude's `esc to interrupt'
for `claude', a backend-specific marker for others.  Match
anywhere in the tail means the agent is actively working
\(generating tokens or running a tool); absence means it's idle."
  :type '(choice (const :tag "From active backend" nil) regexp)
  :group 'claude-dashboard)

(defun claude-dashboard--spinner-regexp ()
  "Resolve the current spinner regexp (override → backend default)."
  (or claude-dashboard-spinner-regexp
      (claude-dashboard--backend-prop :spinner-regexp)))

;;; --- Session-kind classification (monitor vs code) ----------------------
;;
;; This is *session-level*, not moment-level: we ask "does this agent's
;; purpose look like polling a background process?" by mining the
;; per-session transcript on disk.  Independent of RUN/IDL/EXT — a
;; running session and an idle session can both be `monitor'-kind.
;;
;; Four features, each contributes 1 to a 0–4 score; >=2 → `monitor'.
;;
;;   1. ScheduleWakeup-tool rate (per assistant turn) > 0.010
;;   2. Polling-bash fraction > 7%   (verbs in `claude-dashboard-monitor-bash-verbs')
;;   3. Assistant-prose fraction starting with monitoring verbs > 1%
;;   4. File-ops (Edit/Read/Write) fraction < 30%
;;
;; Verified against labelled examples: `aliby-ts-monitor' scores 4/4,
;; this very session scores 0/4.

(defcustom claude-dashboard-classify-min-turns 20
  "Minimum assistant turns before a session is eligible for kind classification.
Below this, `claude-dashboard--classify-kind' returns nil so a
brand-new session isn't labelled prematurely."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-kind-cache-ttl 300
  "Seconds a session-kind verdict is cached before recomputation.
The classifier reads megabytes of transcript so cannot run on every
5-second refresh; classification changes slowly so 5 minutes is fine."
  :type 'integer :group 'claude-dashboard)

(defcustom claude-dashboard-monitor-bash-verbs
  '("ps" "pgrep" "pidof" "tail" "sleep" "watch" "screen" "kill"
    "free" "df" "top" "nvidia-smi" "rocm-smi" "htop" "journalctl"
    "systemctl" "ping" "tmux")
  "Bash verbs treated as polling/monitoring for the kind classifier.
Match is on the first non-prefix verb of the command (after any
leading `cd …;' / `&&' / env-var assignments are stripped)."
  :type '(repeat string) :group 'claude-dashboard)

(defcustom claude-dashboard-monitor-prose-regexp
  "\\`\\(?:Sleeping\\|Waiting\\|Continuing\\|Still\\|Monitor\\|Polling\\|Watching\\)\\b"
  "Regexp matched against the leading word of an assistant text item.
Each match contributes to the monitor-prose fraction feature."
  :type 'regexp :group 'claude-dashboard)

(defcustom claude-dashboard-classify-thresholds
  '((wakeup-rate       . 0.010)
    (polling-frac      . 0.07)
    (prose-frac        . 0.01)
    (file-ops-frac-max . 0.30))
  "Per-feature thresholds for the session-kind score.
Each threshold met contributes 1 to a 0–4 score; the verdict is
`monitor' iff score >= 2.  See the commentary above
`claude-dashboard-classify-min-turns' for the four features."
  :type '(alist :key-type symbol :value-type number)
  :group 'claude-dashboard)

(defcustom claude-dashboard-monitor-color "#36c0c0"
  "Foreground color of the monitor-kind glyph in the project cell."
  :type 'color :group 'claude-dashboard)

(defcustom claude-dashboard-monitor-glyph "↻"
  "Glyph prepended to the project cell of monitor-kind rows."
  :type 'string :group 'claude-dashboard)

(defvar claude-dashboard--kind-cache (make-hash-table :test 'equal)
  "Map sid (string) → (KIND . FLOAT-TIME).  KIND is `monitor', `code', or nil.")

(defun claude-dashboard--bash-first-verb (cmd)
  "Return the first non-prefix verb of bash CMD, or nil."
  (when (stringp cmd)
    (let ((stripped (replace-regexp-in-string
                     ;; Strip leading `cd <path>;' / `cd <path> &&' /
                     ;; `FOO=bar BAZ=qux ' env-var assignments.
                     "\\`\\(?:[ \t]*\\(?:cd[ \t]+[^ \t;&|]+[ \t]*\\(?:&&\\|;\\)\\|[A-Z_]+=[^ \t]+\\)[ \t]*\\)+"
                     "" cmd)))
      (car (split-string stripped "[ \t\n]+" t)))))

(defun claude-dashboard--classify-kind (cwd sid)
  "Return `monitor', `code', or nil for SID's transcript at CWD."
  (when-let ((file (claude-dashboard--transcript-file-for-sid sid cwd)))
    (let ((assistant-turns 0)
          (tool-uses 0)
          (wakeups 0)
          (file-ops 0)
          (bash-cmds 0)
          (polling-cmds 0)
          (prose-prefixes 0))
      (claude-dashboard--map-jsonl-entries
       file
       (lambda (entry)
         (when (equal "assistant" (alist-get 'type entry))
           (cl-incf assistant-turns)
           (let ((content (alist-get 'content (alist-get 'message entry))))
             (when (listp content)
               (dolist (c content)
                 (let ((ctype (alist-get 'type c)))
                   (cond
                    ((equal ctype "text")
                     (let ((txt (alist-get 'text c)))
                       (when (and txt
                                  (string-match-p
                                   claude-dashboard-monitor-prose-regexp
                                   (string-trim txt)))
                         (cl-incf prose-prefixes))))
                    ((equal ctype "tool_use")
                     (cl-incf tool-uses)
                     (let ((name (alist-get 'name c)))
                       (cond
                        ((equal name "ScheduleWakeup") (cl-incf wakeups))
                        ((member name '("Edit" "Read" "Write" "MultiEdit"
                                        "NotebookEdit"))
                         (cl-incf file-ops))
                        ((equal name "Bash")
                         (cl-incf bash-cmds)
                         (let ((verb (claude-dashboard--bash-first-verb
                                      (alist-get 'command
                                                 (alist-get 'input c)))))
                           (when (member verb
                                         claude-dashboard-monitor-bash-verbs)
                             (cl-incf polling-cmds)))))))))))))
         nil)
       nil nil)
      (cond
       ((or (< assistant-turns claude-dashboard-classify-min-turns)
            (< tool-uses 10))
        nil)
       (t
        (let* ((th claude-dashboard-classify-thresholds)
               (wakeup-rate (/ (float wakeups) (max 1 assistant-turns)))
               (polling-frac (if (zerop bash-cmds) 0.0
                               (/ (float polling-cmds) bash-cmds)))
               (prose-frac (/ (float prose-prefixes)
                              (max 1 assistant-turns)))
               (file-ops-frac (if (zerop tool-uses) 0.0
                                (/ (float file-ops) tool-uses)))
               (score (+ (if (> wakeup-rate
                                (alist-get 'wakeup-rate th)) 1 0)
                         (if (> polling-frac
                                (alist-get 'polling-frac th)) 1 0)
                         (if (> prose-frac
                                (alist-get 'prose-frac th)) 1 0)
                         (if (< file-ops-frac
                                (alist-get 'file-ops-frac-max th)) 1 0))))
          (if (>= score 2) 'monitor 'code)))))))

(defun claude-dashboard--instance-kind (inst)
  "Return INST's session kind (`monitor' or `code'), cached.
Returns nil for sessions with insufficient data, or for backends
other than Claude (the classifier mines Claude's tool_use entries
and has no equivalent for opencode/codex)."
  (when (and (eq (claude-dashboard--instance-backend inst) 'claude)
             (claude-dashboard--live-session-id inst))
    (let* ((sid (or (claude-dashboard--live-session-id inst)
                    (claude-dashboard-instance-session-id inst)))
           (cur (gethash sid claude-dashboard--kind-cache))
           (now (float-time)))
      (if (and cur (< (- now (cdr cur))
                      claude-dashboard-kind-cache-ttl))
          (car cur)
        (let ((kind (claude-dashboard--classify-kind
                     (claude-dashboard-instance-cwd inst) sid)))
          (puthash sid (cons kind now) claude-dashboard--kind-cache)
          kind)))))

(defun claude-dashboard-reclassify-instance ()
  "Force a fresh kind classification for the row at point.
Useful after an agent's purpose has shifted (e.g. a coding session
that started polling after finishing the bug fix)."
  (interactive)
  (let* ((inst (claude-dashboard--current-instance))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst))))
    (when sid (remhash sid claude-dashboard--kind-cache))
    (let ((kind (claude-dashboard--instance-kind inst)))
      (claude-dashboard--maybe-refresh)
      (message "claude-dashboard: kind = %s" (or kind "(undetermined)")))))

(defun claude-dashboard--status (inst)
  "Return INST's current phase symbol: `exited', `running', or `idle'."
  (let ((proc (claude-dashboard--instance-process inst)))
    (cond
     ((not (and proc (process-live-p proc))) 'exited)
     ((with-current-buffer (claude-dashboard-instance-buffer inst)
        (save-excursion
          (goto-char (point-max))
          (re-search-backward (claude-dashboard--spinner-regexp)
                              (max (point-min)
                                   (- (point-max)
                                      claude-dashboard-tail-chars))
                              t)))
      'running)
     (t 'idle))))

(defun claude-dashboard--state-color (status)
  (pcase status
    ('running "#22cc22")
    ('idle    "#3b9bff")
    ('exited  "#ff4d4d")
    (_        "gray60")))

(defun claude-dashboard--status-glyph (status)
  (let ((face `(:foreground ,(claude-dashboard--state-color status) :weight bold)))
    (pcase status
      ('running (propertize "●" 'face face))
      ('idle    (propertize "◐" 'face face))
      ('exited  (propertize "○" 'face face)))))

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
  "Tail the backend's history.jsonl and return the most recent prompt for CWD.
Returns nil for backends without the Claude-style history.jsonl
\(currently anything other than `:transcript-style' = `jsonl')."
  (let ((file (expand-file-name "history.jsonl" (claude-dashboard--state-dir))))
    (when (and (eq (claude-dashboard--backend-prop :transcript-style) 'jsonl)
               (file-readable-p file))
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
  "Read the backend's sessions/<PID>.json and return its alist, or nil.
Returns nil for backends that don't keep a per-PID JSON metadata
file (i.e. anything other than `:transcript-style' = `jsonl').
Callers — `--live-session-id', `--live-session-name', and
`--enrich-instance' — already tolerate a nil return."
  (let ((file (expand-file-name (format "sessions/%d.json" pid)
                                (claude-dashboard--state-dir))))
    (when (and (eq (claude-dashboard--backend-prop :transcript-style) 'jsonl)
               (file-readable-p file))
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
  "Fill in session-id (and Claude's model) on INST from on-disk metadata.
Session-id discovery dispatches through the backend's
`:session-id-fn'.  Model extraction remains Claude-specific
because opencode and codex don't store a `message.model' field
the same way."
  (let ((backend (claude-dashboard--instance-backend inst)))
    (when-let ((sid (claude-dashboard--backend-call
                     :session-id-fn backend inst)))
      (setf (claude-dashboard-instance-session-id inst) sid))
    (when (and (eq backend 'claude)
               (not (claude-dashboard-instance-model inst)))
      (let* ((cwd (claude-dashboard-instance-cwd inst))
             (proj-dir (expand-file-name
                        (format "projects/%s"
                                (claude-dashboard--encode-cwd cwd))
                        (claude-dashboard--state-dir)))
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
    (claude-dashboard--retag-buffer inst)
    (claude-dashboard--write-manifest)))

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

(defun claude-dashboard--activity-cell (inst)
  "Return a short summary of INST's most recent agent activity.
For Claude, walks the JSONL bottom-up and returns the first
sentence of the latest assistant text content, OR a `<Tool>
<hint>' summary when the very last assistant content item is a
tool_use rather than prose.  For other backends, returns the
first sentence of the most recent assistant message from the
normalized walker.  Falls back to `—' when no assistant turn
exists yet."
  (let* ((backend (claude-dashboard--instance-backend inst))
         (cwd (claude-dashboard-instance-cwd inst))
         (sid (or (claude-dashboard--live-session-id inst)
                  (claude-dashboard-instance-session-id inst))))
    (or (and (eq backend 'claude)
             (claude-dashboard--map-jsonl-entries
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
              t))
        ;; Generic path for non-Claude backends: first sentence of the
        ;; latest assistant message from the normalized walker.
        (when-let* ((msgs (claude-dashboard--inst-walk-messages inst))
                    (last-asst (cl-some
                                (lambda (m)
                                  (and (eq (alist-get 'role m) 'assistant)
                                       (alist-get 'text m)))
                                (reverse msgs))))
          (claude-dashboard--first-sentence last-asst))
        "—")))

(defun claude-dashboard--all-exchanges (inst)
  "Return every (:user STR :asst STR :id STR) exchange in INST's session.
Walked top-down so the result is chronological.  Uses INST's
backend `:transcript-walk-fn' for backend-agnostic message access.
An exchange is opened on each user message; subsequent assistant
messages are concatenated with a blank line into its :asst."
  (let (exchanges current)
    (dolist (m (claude-dashboard--inst-walk-messages inst))
      (let* ((role (alist-get 'role m))
             (txt (alist-get 'text m))
             (raw (alist-get 'raw m))
             (pid (and (listp raw) (alist-get 'promptId raw))))
        (cond
         ((and (eq role 'user) txt
               (not (string-prefix-p "<" txt))
               (> (length (string-trim txt)) 0))
          (when current (push current exchanges))
          (setq current
                (list :user (string-trim txt)
                      :asst nil
                      :id (or pid (md5 txt)))))
         ((and (eq role 'assistant) current txt
               (> (length (string-trim txt)) 0))
          (let ((prior (plist-get current :asst))
                (new (string-trim txt)))
            (setq current
                  (plist-put current :asst
                             (if prior
                                 (concat prior "\n\n" new)
                               new))))))))
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
  "Return past sessions for the active backend, newest first.
Dispatches through the backend's `:list-sessions-fn'."
  (or (claude-dashboard--backend-call
       :list-sessions-fn claude-dashboard-backend)
      '()))

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

(defun claude-dashboard--register (buffer cwd &optional backend)
  "Insert BUFFER as an instance rooted at CWD into the registry.
BACKEND defaults to the currently-active `claude-dashboard-backend'."
  (let* ((cwd (claude-dashboard--normalize-cwd cwd))
         (inst (make-claude-dashboard-instance
                :buffer buffer
                :cwd cwd
                :started-at (float-time)
                :last-output (float-time)
                :backend (or backend claude-dashboard-backend)))
         (deploy-branch (claude-dashboard--git-branch cwd)))
    (puthash buffer inst claude-dashboard--instances)
    (when deploy-branch
      (puthash buffer deploy-branch claude-dashboard--deploy-branches))
    (with-current-buffer buffer
      (setq-local eat-kill-buffer-on-exit nil)
      (add-hook 'kill-buffer-hook #'claude-dashboard--on-buffer-killed nil t)
      (add-hook 'eat-update-hook #'claude-dashboard--note-activity nil t))
    (run-at-time 2 nil #'claude-dashboard--enrich-instance inst)
    (claude-dashboard--write-manifest)
    inst))

(defun claude-dashboard--on-buffer-killed ()
  (when-let ((inst (gethash (current-buffer) claude-dashboard--instances))
             (sid (claude-dashboard-instance-session-id inst)))
    (remhash sid claude-dashboard--kind-cache))
  (remhash (current-buffer) claude-dashboard--instances)
  (claude-dashboard--write-manifest)
  (claude-dashboard--maybe-refresh))

;;; Crash recovery — manifest of running sessions

(defcustom claude-dashboard-manifest-file 'auto
  "File where a snapshot of currently-running sessions is persisted.
Read by `claude-dashboard-resume-all' to relaunch every session
that was open before an emacs crash / quit.  When the symbol
`auto' (the default), the file lives at
`dashboard-manifest.el' under the active backend's state dir,
so claude and opencode get separate manifests automatically.
Set to nil to disable manifest writes entirely, or to an
explicit file path to pin it."
  :type '(choice (const :tag "Auto (per backend)" auto)
                 (const :tag "Disabled" nil)
                 file)
  :group 'claude-dashboard)

(defun claude-dashboard--manifest-path ()
  "Resolve the current manifest path, or nil when manifest is disabled."
  (pcase claude-dashboard-manifest-file
    ('nil  nil)
    ('auto (expand-file-name "dashboard-manifest.el"
                             (claude-dashboard--state-dir)))
    (path  path)))

(defun claude-dashboard--write-manifest ()
  "Persist (cwd, sid, backend) for each registered instance.
Safe to call any number of times; entries without a resolved sid
are written too (sid = nil) so `--resume-all' can attempt to look
them up at recovery time, but they're best-effort.  The `:backend'
field lets resume reconstruct each row with the same adapter the
instance was originally launched against; entries from older
manifests without `:backend' are treated as `claude' at read time."
  (when-let ((manifest-file (claude-dashboard--manifest-path)))
    (let ((entries
           (cl-loop for inst in (claude-dashboard--instances-list)
                    for cwd = (claude-dashboard-instance-cwd inst)
                    for sid = (or (and (fboundp 'claude-dashboard--live-session-id)
                                       (claude-dashboard--live-session-id inst))
                                  (claude-dashboard-instance-session-id inst))
                    for backend = (claude-dashboard--instance-backend inst)
                    when cwd
                    collect (list :cwd cwd :sid sid
                                  :backend backend
                                  :recorded (current-time)))))
      (let ((dir (file-name-directory manifest-file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (with-temp-file manifest-file
        (insert ";;; -*- lisp-data -*-\n")
        (let ((print-level nil) (print-length nil))
          (prin1 entries (current-buffer)))
        (insert "\n")))))

(defun claude-dashboard--read-manifest ()
  "Read the active manifest file and return the entry list, or nil."
  (when-let* ((manifest-file (claude-dashboard--manifest-path))
              (_ (file-readable-p manifest-file)))
    (with-temp-buffer
      (insert-file-contents manifest-file)
      (goto-char (point-min))
      (ignore-errors (read (current-buffer))))))

;;;###autoload
(defun claude-dashboard-resume-all ()
  "Relaunch every session in the manifest via its backend's resume flag.
For each entry (:cwd :sid :backend) in `claude-dashboard-manifest-file':
- if its cwd is gone, skip;
- if no sid, skip (nothing to resume);
- if an instance for that cwd is already running in the dashboard,
  skip (avoid duplicate launches);
- otherwise launch via that backend's `:program' + `:resume-flag'.
Entries without `:backend' (older manifests) default to `claude'.
Asks for confirmation before launching so a stale manifest from
weeks ago doesn't surprise you."
  (interactive)
  (let* ((entries (claude-dashboard--read-manifest))
         (live-cwds (mapcar #'claude-dashboard-instance-cwd
                            (claude-dashboard--instances-list)))
         (candidates
          (cl-loop for e in entries
                   for cwd = (plist-get e :cwd)
                   for sid = (plist-get e :sid)
                   for backend = (or (plist-get e :backend) 'claude)
                   when (and cwd sid
                             (file-directory-p cwd)
                             (not (member cwd live-cwds)))
                   collect (list :cwd cwd :sid sid :backend backend))))
    (cond
     ((null entries)
      (message "claude-dashboard: manifest is empty (or unreadable)"))
     ((null candidates)
      (message "claude-dashboard: nothing to resume (manifest sessions all live, missing, or sid-less)"))
     ((y-or-n-p (format "Resume %d session(s) from manifest? "
                        (length candidates)))
      (dolist (c candidates)
        (let ((claude-dashboard-backend (plist-get c :backend)))
          (claude-dashboard--launch
           (plist-get c :cwd)
           (list (claude-dashboard--backend-prop :resume-flag)
                 (plist-get c :sid)))))
      (message "claude-dashboard: resumed %d session(s)" (length candidates))))))

(defun claude-dashboard--launch (cwd extra-args)
  "Launch the active backend in CWD with EXTRA-ARGS, register, refresh, pop."
  (let* ((default-directory cwd)
         (name (claude-dashboard--unique-buffer-name cwd))
         (buf (get-buffer-create name))
         (program (claude-dashboard--program))
         (args (append claude-dashboard-program-args extra-args)))
    (with-current-buffer buf
      ;; Eat's shell-prompt annotation reserves a one-column left margin.
      ;; Backends like Claude Code are TUI apps, not shells — the column
      ;; shifts the whole frame right and clips the right edge of the
      ;; boxed prompt, producing an apparent extra wrap line.  Disable it
      ;; before `eat-mode' runs so the margin isn't installed.
      (setq-local eat-enable-shell-prompt-annotation nil)
      (unless (derived-mode-p 'eat-mode) (eat-mode))
      (eat-exec buf name program nil args))
    (claude-dashboard--register buf cwd)
    (claude-dashboard--maybe-refresh)
    (pop-to-buffer buf claude-dashboard-instance-window-action)
    buf))

;;;###autoload
(defun claude-dashboard-new (cwd)
  "Launch a new backend instance in CWD as an eat buffer."
  (interactive (list (claude-dashboard--read-project)))
  (claude-dashboard--launch cwd nil))

(defun claude-dashboard--worktree-target-dir (main-wt branch)
  "Return the backend's standard worktree path: <MAIN-WT>/<subdir>/<BRANCH>.
The `<subdir>' comes from the active backend's `:worktree-subdir'
slot (e.g. `.claude/worktrees' for Claude)."
  (file-name-as-directory
   (expand-file-name (format "%s/%s"
                             (claude-dashboard--backend-prop :worktree-subdir)
                             branch)
                     main-wt)))

;;;###autoload
(defun claude-dashboard-new-worktree (source-cwd branch)
  "Create a new git worktree + BRANCH under SOURCE-CWD's repo, then launch backend.
Worktree lands at `<main-worktree>/<backend-subdir>/<BRANCH>'.  TOPIC
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
  "Resume the most recent session in CWD via the backend's continue flag."
  (interactive (list (claude-dashboard--read-project)))
  (claude-dashboard--launch
   cwd (list (claude-dashboard--backend-prop :continue-flag))))

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
         (buf (claude-dashboard--launch
               cwd (list (claude-dashboard--backend-prop :resume-flag) sid)))
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

(defun claude-dashboard--reuse-instance-window (buffer alist)
  "`display-buffer' action: reuse any window already showing an instance.
Returns the window after swapping in BUFFER, or nil if no other
instance buffer is currently displayed.  Pairs naturally with
`display-buffer-pop-up-window' as a fallback in the action list."
  (when-let ((win (cl-find-if
                   (lambda (w)
                     (let ((b (window-buffer w)))
                       (and (not (eq b buffer))
                            (not (eq b (get-buffer
                                        claude-dashboard-buffer-name)))
                            (gethash b claude-dashboard--instances))))
                   (window-list (selected-frame)))))
    (window--display-buffer buffer win 'reuse alist)
    win))

(defcustom claude-dashboard-instance-window-action
  '((claude-dashboard--reuse-instance-window
     display-buffer-pop-up-window)
    (inhibit-same-window . nil))
  "Display action for popping into an instance buffer.
The default reuses any window currently showing another dashboard
instance (so only one agent is visible at a time and switching
agents replaces the visible buffer in place); falls back to
opening a new window when no instance is shown yet."
  :type 'sexp :group 'claude-dashboard)

(defun claude-dashboard-visit (inst)
  "Pop to INST's eat buffer.
Reuses the window currently showing another instance, so visiting
a second agent replaces the first one in place rather than piling
up windows.  See `claude-dashboard-instance-window-action'."
  (interactive (list (claude-dashboard--current-instance)))
  (pop-to-buffer (claude-dashboard-instance-buffer inst)
                 claude-dashboard-instance-window-action))

(defun claude-dashboard-display (inst)
  "Display INST's eat buffer without selecting it.
Reuses an existing instance window if one is visible."
  (interactive (list (claude-dashboard--current-instance)))
  (display-buffer (claude-dashboard-instance-buffer inst)
                  claude-dashboard-instance-window-action))

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
                  (claude-dashboard--program) nil
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
  "Return the first prompt logged for session SID in history.jsonl, or nil.
Backend-specific: only the `jsonl' transcript style stores prompts
in a single per-user history file; other backends return nil."
  (when (and sid (eq (claude-dashboard--backend-prop :transcript-style)
                     'jsonl))
    (claude-dashboard--map-jsonl-entries
     (expand-file-name "history.jsonl" (claude-dashboard--state-dir))
     (lambda (entry)
       (and (equal sid (alist-get 'sessionId entry))
            (alist-get 'display entry))))))

(defun claude-dashboard--transcript-file-for-sid (sid &optional cwd backend)
  "Locate the transcript file for SID under the chosen backend.
BACKEND defaults to the active `claude-dashboard-backend'.
Dispatches through the backend's `:transcript-path-fn'."
  (claude-dashboard--backend-call
   :transcript-path-fn (or backend claude-dashboard-backend) cwd sid))

(defun claude-dashboard--session-name-from-transcript (inst &optional sid)
  "Return the latest `customTitle' for INST's session, or nil.
Claude-specific: walks the JSONL transcript bottom-up for the most
recent `custom-title' entry; other backends have no equivalent
`/name' marker in their transcripts and return nil."
  (let ((backend (claude-dashboard--instance-backend inst)))
    (when (eq backend 'claude)
      (let* ((sid (or sid
                      (claude-dashboard--live-session-id inst)
                      (claude-dashboard-instance-session-id inst)))
             (path (claude-dashboard--inst-transcript-path inst sid)))
        (claude-dashboard--map-jsonl-entries
         path
         (lambda (entry)
           (when (equal "custom-title" (alist-get 'type entry))
             (let ((ct (alist-get 'customTitle entry)))
               (and ct (not (string-empty-p ct)) ct))))
         t)))))

(defun claude-dashboard--first-prompt-from-transcript (inst)
  "Return the first human-typed user prompt from INST's transcript, or nil.
Uses INST's backend `:transcript-walk-fn'.  Skips synthetic `<…>'
messages."
  (cl-some (lambda (m)
             (and (eq (alist-get 'role m) 'user)
                  (let ((txt (alist-get 'text m)))
                    (and (stringp txt)
                         (not (string-prefix-p "<" txt))
                         txt))))
           (claude-dashboard--inst-walk-messages inst)))

(defun claude-dashboard--live-session-id (inst)
  "Return the *current* session-id for INST via its backend, or nil.
The struct's `session-id' is captured shortly after launch and can
go stale when the agent is resumed with a new id under the same
buffer, so a fresh per-backend lookup is more reliable when the
cached id has no on-disk transcript."
  (claude-dashboard--backend-call
   :session-id-fn (claude-dashboard--instance-backend inst) inst))

(defun claude-dashboard--live-session-name (inst)
  "Return the *current* conversation name for INST, or nil.
Dispatches through the backend's `:session-name-fn'.  For Claude
this reads `~/.claude/sessions/<PID>.json' and returns its `name'
field, updated in real-time on `/rename'; opencode falls back to
`session.title' in its SQLite db."
  (claude-dashboard--backend-call
   :session-name-fn (claude-dashboard--instance-backend inst) inst))

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
      (let* ((live-sid (claude-dashboard--live-session-id inst))
             (cached-sid (claude-dashboard-instance-session-id inst))
             (name (or (claude-dashboard--live-session-name inst)
                       (claude-dashboard--session-name-from-transcript
                        inst live-sid)
                       (claude-dashboard--session-name-from-transcript
                        inst cached-sid)
                       (gethash buf claude-dashboard--worktree-names)
                       "—"))
             ;; Prepend a one-glyph colored backend badge so multi-backend
             ;; dashboards distinguish claude / opencode / codex rows at
             ;; a glance.  Width is counted toward TOPIC's column budget.
             (backend (claude-dashboard--instance-backend inst))
             (badge-str (or (claude-dashboard--backend-prop :badge backend)
                            "?"))
             (badge-color (or (claude-dashboard--backend-prop :badge-color
                                                             backend)
                              "gray60"))
             (badge (propertize badge-str
                                'face `(:foreground ,badge-color
                                                    :weight bold)))
             (val (concat badge " " name)))
        (when (and live-sid (not (equal live-sid cached-sid)))
          (setf (claude-dashboard-instance-session-id inst) live-sid))
        (puthash buf (cons val now) claude-dashboard--topic-cache)
        val))))

(defun claude-dashboard--row-format (branch-w topic-w)
  "Return the row format with dynamic BRANCH-W and TOPIC-W widths.
ACTIVITY is the trailing column and is rendered with `%s' so it
doesn't pad with trailing spaces — that padding could push the
visible row past the window's right edge and wrap to a second
line on narrower windows.  TOPIC sits before ACTIVITY at a width
that fits the longest actual session name (capped by
`claude-dashboard-topic-max-width'), so short topics never get
clipped while ACTIVITY absorbs whatever space remains."
  (format "%%s %%s %%-%ds %%-3s %%5s %%-%ds %%-8s %%-%ds  %%s"
          claude-dashboard-project-max-width branch-w topic-w))

(defun claude-dashboard--instance-deploy-branch (inst)
  "Return the branch INST was deployed against, falling back to live."
  (or (gethash (claude-dashboard-instance-buffer inst)
               claude-dashboard--deploy-branches)
      (claude-dashboard--instance-branch inst)
      "—"))

(defun claude-dashboard--state-abbrev (status &optional kind)
  "Abbreviate STATUS.  When KIND is `monitor', `idle' is shown as MON."
  (pcase status
    ('running "RUN")
    ('idle    (if (eq kind 'monitor) "MON" "IDL"))
    ('exited  "EXT")
    (_        "?")))

(defun claude-dashboard--status-rank (status)
  "Sort priority for STATUS: lower wins (sorts higher in the list)."
  (pcase status
    ('running 0)
    ('idle    1)
    ('exited  2)
    (_        3)))

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
           "SESSION" "TOPIC" "ACTIVITY")
   'face 'magit-section-heading))

(defun claude-dashboard--format-instance-line (inst branch-w topic-w activity-w)
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
         ;; (e.g. a multi-line first prompt) had a newline.  The TOPIC
         ;; from `--instance-topic' already carries the backend badge
         ;; prefix (`C '/`O '/`X '), so badge width is included in the
         ;; column-width fit upstream — no extra accounting needed here.
         (topic (replace-regexp-in-string
                 "[\t\n\r ]+" " "
                 (or (claude-dashboard--instance-topic inst) "")))
         (sid-full (or (claude-dashboard--live-session-id inst)
                       (claude-dashboard-instance-session-id inst)))
         (sid (or (and sid-full (substring sid-full 0 8)) "—"))
         (activity-cell
          (truncate-string-to-width
           (claude-dashboard--activity-cell inst)
           activity-w nil nil "…"))
         ;; Session-kind annotation: if the classifier says this row is
         ;; a monitor session, prepend `↻ ' to the project name (and
         ;; shrink its truncate budget by 2 so the column width stays
         ;; the same).
         (kind (claude-dashboard--instance-kind inst))
         (kind-prefix (if (eq kind 'monitor)
                          (concat
                           (propertize claude-dashboard-monitor-glyph
                                       'face `(:foreground ,claude-dashboard-monitor-color
                                                           :weight bold))
                           " ")
                        ""))
         (proj-budget (- claude-dashboard-project-max-width
                         (length kind-prefix))))
    (format (claude-dashboard--row-format branch-w topic-w)
            (if (gethash (claude-dashboard-instance-buffer inst)
                         claude-dashboard--marks)
                (propertize "*" 'face 'warning)
              " ")
            glyph
            (concat
             kind-prefix
             (propertize (truncate-string-to-width
                          proj proj-budget nil ?\s "…")
                         'face `(:foreground ,root-color :weight bold)))
            (propertize (claude-dashboard--state-abbrev status kind)
                        'face (if (and (eq status 'idle) (eq kind 'monitor))
                                  `(:foreground ,claude-dashboard-monitor-color
                                                :weight bold)
                                (claude-dashboard--state-face status)))
            uptime
            (truncate-string-to-width branch branch-w nil ?\s "…")
            sid
            (truncate-string-to-width topic topic-w nil ?\s "…")
            ;; ACTIVITY is the trailing column — already truncated to
            ;; activity-w above with no padding char, so short activity
            ;; cells don't pad the row past the window's right edge.
            activity-cell)))

(defun claude-dashboard--insert-query-section (xch)
  "Insert a magit subsection for one exchange XCH (`:user :asst :id').
The user prompt is the section heading (`❯ …'); the formatted
assistant response is the section body, dimmed in `shadow' face.
Sections start collapsed; press TAB on the heading or `3' globally
to reveal responses."
  (let* ((user-text (or (plist-get xch :user) ""))
         (asst-text (or (plist-get xch :asst) ""))
         (win (get-buffer-window (current-buffer) 'visible))
         (win-w (if win (window-text-width win) (frame-text-width)))
         ;; Heading prefix is "    ❯ " (6 chars); body prefix is 6 spaces.
         ;; Truncate each rendered line to the window's right edge with
         ;; `…' so no row, query heading, or body line ever wraps.
         (heading-w (max 16 (- win-w 6)))
         (body-w (max 16 (- win-w 6)))
         (heading
          (concat "    "
                  (propertize "❯" 'face 'font-lock-keyword-face)
                  " "
                  (propertize
                   (truncate-string-to-width
                    (replace-regexp-in-string "[\t\n\r ]+" " " user-text)
                    heading-w nil nil "…")
                   'face 'default)))
         (section
          (magit-insert-section (claude-dashboard-query-section
                                 (plist-get xch :id) t)
            (magit-insert-heading heading)
            (when (> (length (string-trim asst-text)) 0)
              (let* ((lines (split-string (string-trim-right asst-text) "\n"))
                     (rendered
                      (mapconcat
                       (lambda (l)
                         (concat "      "
                                 (truncate-string-to-width
                                  l body-w nil nil "…")))
                       lines "\n")))
                (insert (propertize rendered 'face 'shadow) "\n"))))))
    (when (and section (oref section hidden))
      (magit-section-hide section))))

(defun claude-dashboard--insert-instance-overview (inst)
  "Insert the per-instance overview body (visible when row unfolds).
Each user query becomes its own foldable subsection whose body is
the formatted assistant response.  Combined with magit-section's
`magit-section-show-level-N-all' bindings on `1'..`4', this gives
three progressive views: rows-only (1), rows + queries (2), rows
+ queries + responses (3)."
  (let* ((exchanges (claude-dashboard--all-exchanges inst)))
    (if exchanges
        (dolist (xch exchanges)
          (claude-dashboard--insert-query-section xch))
      (insert "    "
              (propertize "(no exchange yet)" 'face 'shadow)
              "\n"))))

(defun claude-dashboard--insert-instance-section (inst branch-w topic-w activity-w)
  ;; Each instance row is the heading of a magit section whose body
  ;; is the per-instance overview.  TAB (inherited from
  ;; `magit-section-mode-map' as `magit-section-toggle') expands or
  ;; collapses individual rows; `magit-section-cache-visibility' set
  ;; in the mode init preserves state across the 5-second refresh.
  (let ((section
         (magit-insert-section (claude-dashboard-instance-section inst t)
           (magit-insert-heading
             (claude-dashboard--format-instance-line
              inst branch-w topic-w activity-w))
           (claude-dashboard--insert-instance-overview inst))))
    ;; The HIDE arg sets the slot but doesn't apply the invisibility
    ;; overlay; do that explicitly so the body actually starts folded.
    (when (and section (oref section hidden))
      (magit-section-hide section))))

(defun claude-dashboard--render ()
  "Replace the current buffer's contents with a fresh dashboard."
  (let ((inhibit-read-only t)
        (instances (claude-dashboard--instances-list))
        (cur-win (get-buffer-window (current-buffer) 'visible)))
    (when cur-win
      (setq claude-dashboard--last-rendered-width (window-text-width cur-win)))
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
             (topics (mapcar #'claude-dashboard--instance-topic instances))
             ;; TOPIC takes exactly the width of the longest current
             ;; session name, capped by `topic-max-width' — so it never
             ;; clips a topic that would otherwise fit, and never wastes
             ;; horizontal space when topics are short.
             (topic-w (claude-dashboard--column-width
                       "TOPIC" topics
                       claude-dashboard-topic-max-width))
             ;; M G PROJECT(P) ST(3) UP(5) BRANCH(B) SESSION(8) TOPIC(T)  ACT
             (prefix-w (+ 1 1 1 1 claude-dashboard-project-max-width
                            1 3 1 5 1 branch-w 1 8 1 topic-w 2))
             (win (get-buffer-window (current-buffer) 'visible))
             (frame-w (if win (window-text-width win) (frame-text-width)))
             ;; ACTIVITY absorbs whatever horizontal space is left, with
             ;; a floor of 16 so it stays usable on narrow windows.
             (activity-w (max 16 (- frame-w prefix-w))))
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
               inst branch-w topic-w activity-w))))))))

(defun claude-dashboard--fit-window (buf)
  "Shrink BUF's visible window to fit its content (when configured).
Sizes the window to just the instance rows (`2 + N': the summary
line + column header + N instance rows) so expanded query
sections don't make the side window swallow the frame.  The user
can still scroll inside the dashboard to reach expanded bodies."
  (when claude-dashboard-fit-window
    (when-let ((win (get-buffer-window buf 'visible)))
      ;; Don't fit a window that's the only one in its frame — there's
      ;; nothing to shrink to.
      (unless (frame-root-window-p win)
        (with-selected-window win
          (let* ((n (length (claude-dashboard--instances-list)))
                 (auto-h (+ 2 (max 1 n)))
                 (max-h (max claude-dashboard-fit-min-height
                             (or claude-dashboard-fit-max-height auto-h))))
            (fit-window-to-buffer
             win max-h claude-dashboard-fit-min-height nil nil t)))))))

(defun claude-dashboard--display-action ()
  "Action argument for `display-buffer' that docks the dashboard.
Returns a side-window action when `claude-dashboard-fit-window' is
on; nil otherwise (so `display-buffer' uses default rules).
`no-delete-other-windows' is explicitly cleared so `C-x 1' from a
sibling window and `C-x 0' from the dashboard window itself both
remove it from sight; without this override
`display-buffer-in-side-window' sets the parameter to t and the
side window survives both commands."
  (when claude-dashboard-fit-window
    `((display-buffer-in-side-window)
      (side          . ,claude-dashboard-side)
      (slot          . 0)
      (window-height . fit-window-to-buffer)
      (preserve-size . (nil . t))
      (window-parameters . ((no-delete-other-windows . nil))))))

(defun claude-dashboard--maybe-refresh ()
  "Re-render the dashboard if its buffer is live."
  ;; Auto-naming runs ahead of render so a freshly-injected /name has a
  ;; chance to land in the transcript before the topic resolver reads it.
  (dolist (inst (claude-dashboard--instances-list))
    (ignore-errors (claude-dashboard--maybe-auto-name inst)))
  ;; Heartbeat: keep the crash-recovery manifest current so a sudden
  ;; emacs exit leaves a usable snapshot for `claude-dashboard-resume-all'.
  (ignore-errors (claude-dashboard--write-manifest))
  (let ((buf (get-buffer claude-dashboard-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((line (line-number-at-pos)))
          (claude-dashboard--render)
          (goto-char (point-min))
          (forward-line (1- line))))
      (claude-dashboard--fit-window buf))))

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

;; `global-visual-line-mode-enable-in-buffer' runs from
;; `after-change-major-mode-hook' (after this mode's body), so a plain
;; `(visual-line-mode -1)' inside the mode init gets silently undone.
;; Filter the globalized enabler so it skips dashboard buffers — same
;; pattern needed for any major mode that wants `truncate-lines' to win.
(with-eval-after-load 'simple
  (when (fboundp 'global-visual-line-mode-enable-in-buffer)
    (advice-add 'global-visual-line-mode-enable-in-buffer :around
                (lambda (orig &rest args)
                  (unless (derived-mode-p 'claude-dashboard-mode)
                    (apply orig args)))
                '((name . claude-dashboard-skip)))))

(define-derived-mode claude-dashboard-mode magit-section-mode "ClaudeDash"
  "Major mode for the Claude Code instance dashboard."
  :group 'claude-dashboard
  ;; Rows are rendered to fit the window's current width exactly.
  ;; `truncate-lines' keeps them on one line if the window narrows after
  ;; render (e.g. user moves the frame to a smaller monitor); the
  ;; resize hook below re-renders so content adapts to the new width.
  (setq-local truncate-lines t)
  (setq-local word-wrap nil)
  (when (bound-and-true-p visual-line-mode)
    (visual-line-mode -1))
  (add-hook 'window-size-change-functions
            #'claude-dashboard--on-window-size-change nil t)
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

(defvar-local claude-dashboard--last-rendered-width nil
  "Window text width used for the most recent render of this buffer.
Tracked per-buffer so the resize hook can no-op when nothing changed.")

(defun claude-dashboard--on-window-size-change (frame)
  "Re-render the dashboard when its window's text width changes on FRAME.
Hooked into `window-size-change-functions' so the column layout
adapts when the user moves the frame between monitors of different
widths, splits the window, or resizes it manually."
  (dolist (win (window-list frame 'no-mini))
    (let ((buf (window-buffer win)))
      (when (and (buffer-live-p buf)
                 (eq (buffer-local-value 'major-mode buf)
                     'claude-dashboard-mode))
        (let ((new-w (window-text-width win))
              (old-w (buffer-local-value 'claude-dashboard--last-rendered-width
                                         buf)))
          (when (and (integerp new-w) (or (null old-w) (/= new-w old-w)))
            (with-current-buffer buf
              (setq claude-dashboard--last-rendered-width new-w)
              (claude-dashboard-refresh))))))))

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
  "Open the Claude Code dashboard.
With `claude-dashboard-fit-window' (default), the buffer is docked
as a side window at `claude-dashboard-side' so it occupies only the
rows needed to show the current instances; otherwise standard
display rules apply."
  (interactive)
  (let ((buf (get-buffer-create claude-dashboard-buffer-name)))
    (with-current-buffer buf
      (claude-dashboard-mode)
      (claude-dashboard--render)
      (claude-dashboard--goto-first-instance))
    (let ((action (claude-dashboard--display-action)))
      (if action
          (pop-to-buffer buf action)
        (pop-to-buffer buf)))
    (with-current-buffer buf
      (claude-dashboard--goto-first-instance))
    (claude-dashboard--fit-window buf)))

;;; --- Backend adapters ----------------------------------------------------
;;
;; One block per backend.  Each defines the function-slot implementations
;; referenced by name in `claude-dashboard-backends'.  Forward references
;; are fine because the registry stores SYMBOLS that
;; `claude-dashboard--backend-call' resolves with `fboundp' at dispatch
;; time, not at registry-build time.

;; ----- Claude ----------------------------------------------------------

(defun claude-dashboard--claude-session-id-fn (inst)
  "Claude `:session-id-fn' — read sessionId from ~/.claude/sessions/<PID>.json."
  (when-let* ((proc (claude-dashboard--instance-process inst))
              (pid (and proc (process-id proc)))
              (json (claude-dashboard--read-session-json pid)))
    (alist-get 'sessionId json)))

(defun claude-dashboard--claude-session-name-fn (inst)
  "Claude `:session-name-fn' — `name' field of the live PID-json file."
  (when-let* ((proc (claude-dashboard--instance-process inst))
              (pid (and proc (process-id proc)))
              (json (claude-dashboard--read-session-json pid))
              (name (alist-get 'name json)))
    (and (stringp name) (not (string-empty-p name)) name)))

(defun claude-dashboard--claude-transcript-path-fn (_cwd sid)
  "Claude `:transcript-path-fn' — newest projects/<slug>/<SID>.jsonl."
  (when sid
    (let* ((target (concat sid ".jsonl"))
           (projects-dir (expand-file-name
                          "projects"
                          (or claude-dashboard-claude-dir
                              (claude-dashboard--backend-prop
                               :state-dir 'claude))))
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

(defun claude-dashboard--claude-transcript-walk-fn (path)
  "Claude `:transcript-walk-fn' — JSONL → normalized message list.
Each user/assistant entry is normalized to `((role . SYM)
\(text . STR) (ts . FLOAT) (raw . ENTRY))'.  Synthetic `<…>'
messages and tool-result-only user turns are filtered out."
  (let (msgs)
    (claude-dashboard--map-jsonl-entries
     path
     (lambda (entry)
       (let* ((type (alist-get 'type entry))
              (msg (alist-get 'message entry))
              (is-meta (alist-get 'isMeta entry))
              (role (cond ((equal type "user") 'user)
                          ((equal type "assistant") 'assistant)))
              (ts-str (alist-get 'timestamp entry))
              (ts (and ts-str (ignore-errors
                                (float-time (date-to-time ts-str)))))
              (content (and msg (alist-get 'content msg))))
         (when (and role (not is-meta))
           (let ((text (cond
                        ((stringp content) content)
                        ((listp content)
                         (when-let ((tb (cl-find-if
                                         (lambda (c)
                                           (equal "text" (alist-get 'type c)))
                                         content)))
                           (alist-get 'text tb))))))
             (when (and text (stringp text)
                        (not (string-prefix-p "<" text))
                        (> (length (string-trim text)) 0))
               (push `((role . ,role)
                       (text . ,(string-trim text))
                       (ts   . ,ts)
                       (raw  . ,entry))
                     msgs)))))
       nil))
    (nreverse msgs)))

(defun claude-dashboard--claude-list-sessions-fn ()
  "Claude `:list-sessions-fn' — scan ~/.claude/projects/ for past sessions."
  (let* ((root (expand-file-name
                "projects"
                (or claude-dashboard-claude-dir
                    (claude-dashboard--backend-prop :state-dir 'claude))))
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

(defun claude-dashboard--claude-rename-fn (proc slug)
  "Claude `:rename-fn' — inject `/name SLUG\\n' into PROC's PTY."
  (when (and proc (process-live-p proc) slug (not (string-empty-p slug)))
    (process-send-string proc (format "/name %s\n" slug))
    t))

;; ----- Opencode --------------------------------------------------------
;;
;; Opencode persists every session and message in a single SQLite
;; database at <state-dir>/opencode-stable.db (WAL mode).  We read
;; through Emacs 30's built-in sqlite-* primitives; older Emacs / Emacs
;; built without sqlite get a graceful nil-stub.  Schema (simplified):
;;
;;   session(id, directory, title, time_updated, time_archived, ...)
;;   message(id, session_id, data, ...)        -- `data' is a JSON blob
;;                                                whose `role' field is
;;                                                the message role.
;;   part(id, message_id, time_created, data)  -- `data' is a JSON blob
;;                                                whose `type' = "text"
;;                                                content carries the
;;                                                actual prose.

(defcustom claude-dashboard-opencode-db-name "opencode-stable.db"
  "Filename (under the opencode state dir) of the sessions database."
  :type 'string :group 'claude-dashboard)

(defvar claude-dashboard--opencode-unavailable-warned nil
  "Non-nil once we've emitted the one-shot `sqlite unavailable' message.")

(defun claude-dashboard--opencode-warn-unavailable ()
  "Emit a one-shot message that opencode columns will be blank.
Triggered when `sqlite-available-p' returns nil — typically an
Emacs build without --with-sqlite3.  Stays silent on subsequent
calls so the message line isn't spammed every refresh."
  (unless claude-dashboard--opencode-unavailable-warned
    (setq claude-dashboard--opencode-unavailable-warned t)
    (message "claude-dashboard: opencode adapter needs Emacs built with sqlite3 support — transcript columns will be blank")))

(defun claude-dashboard--opencode-db-path ()
  "Return the absolute path to opencode's sessions db."
  (expand-file-name claude-dashboard-opencode-db-name
                    (or claude-dashboard-claude-dir
                        (claude-dashboard--backend-prop
                         :state-dir 'opencode))))

(defmacro claude-dashboard--with-opencode-db (var &rest body)
  "Open opencode's SQLite db bound to VAR, run BODY, then close.
Evaluates to BODY's value, or nil when sqlite is unavailable / db
is missing.  Errors during BODY are swallowed (best-effort reads)."
  (declare (indent 1) (debug t))
  `(if (not (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
       (progn (claude-dashboard--opencode-warn-unavailable) nil)
     (let* ((path (claude-dashboard--opencode-db-path)))
       (when (file-readable-p path)
         (let ((,var nil) result)
           (unwind-protect
               (progn
                 (setq ,var (sqlite-open path))
                 (setq result (ignore-errors ,@body)))
             (when ,var (ignore-errors (sqlite-close ,var))))
           result)))))

(defun claude-dashboard--opencode-row-session (row)
  "Pack a `session' row into a `claude-dashboard-past-session'."
  (let* ((id (nth 0 row))
         (dir (nth 1 row))
         (title (nth 2 row))
         (updated (nth 3 row))
         (mtime (when (numberp updated)
                  ;; opencode stores time in ms since epoch.
                  (seconds-to-time (/ updated 1000.0)))))
    (make-claude-dashboard-past-session
     :session-id id
     :cwd (and dir (file-name-as-directory dir))
     :mtime (or mtime (current-time))
     :first-prompt title
     :jsonl-path nil)))

(defun claude-dashboard--opencode-session-id-fn (inst)
  "Opencode `:session-id-fn' — newest session whose directory = INST cwd."
  (let* ((cwd (directory-file-name
               (claude-dashboard-instance-cwd inst))))
    (claude-dashboard--with-opencode-db db
      (let ((rows (sqlite-select
                   db
                   "SELECT id FROM session \
                    WHERE directory = ? AND time_archived IS NULL \
                    ORDER BY time_updated DESC LIMIT 1"
                   (list cwd))))
        (caar rows)))))

(defun claude-dashboard--opencode-session-name-fn (inst)
  "Opencode `:session-name-fn' — `title' of the live session row."
  (let* ((sid (or (claude-dashboard-instance-session-id inst)
                  (claude-dashboard--opencode-session-id-fn inst))))
    (when sid
      (claude-dashboard--with-opencode-db db
        (let ((rows (sqlite-select
                     db
                     "SELECT title FROM session WHERE id = ? LIMIT 1"
                     (list sid))))
          (let ((title (caar rows)))
            (and (stringp title) (not (string-empty-p title)) title)))))))

(defun claude-dashboard--opencode-transcript-path-fn (_cwd sid)
  "Opencode `:transcript-path-fn' — encode SID into a synthetic db: URI.
The opencode walker takes this string and re-derives the db path
\(everything is in a single SQLite file), so we use the slot purely
as a way to keep the dispatch chain identical to the JSONL backends."
  (when sid
    (concat "opencode-db:" sid)))

(defun claude-dashboard--opencode-transcript-walk-fn (path)
  "Opencode `:transcript-walk-fn' — query SQLite for normalized msgs.
PATH is the `opencode-db:<sid>' synthetic URI minted by
`--opencode-transcript-path-fn'."
  (when (and (stringp path) (string-prefix-p "opencode-db:" path))
    (let* ((sid (substring path (length "opencode-db:")))
           msgs)
      (claude-dashboard--with-opencode-db db
        (let ((rows (sqlite-select
                     db
                     "SELECT m.data, p.data, p.time_created \
                      FROM part p JOIN message m ON p.message_id = m.id \
                      WHERE m.session_id = ? \
                      ORDER BY p.time_created ASC"
                     (list sid))))
          (dolist (r rows)
            (let* ((mdata (ignore-errors
                            (json-parse-string
                             (nth 0 r)
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil :false-object nil)))
                   (pdata (ignore-errors
                            (json-parse-string
                             (nth 1 r)
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil :false-object nil)))
                   (role-str (and mdata (alist-get 'role mdata)))
                   (role (pcase role-str
                           ("user" 'user)
                           ("assistant" 'assistant)
                           (_ nil)))
                   (ptype (and pdata (alist-get 'type pdata)))
                   (text (and pdata (alist-get 'text pdata)))
                   (ts-ms (nth 2 r))
                   (ts (when (numberp ts-ms) (/ ts-ms 1000.0))))
              (when (and role (equal ptype "text")
                         (stringp text)
                         (> (length (string-trim text)) 0))
                (push `((role . ,role)
                        (text . ,(string-trim text))
                        (ts   . ,ts)
                        (raw  . ((message . ,mdata) (part . ,pdata))))
                      msgs))))))
      (nreverse msgs))))

(defun claude-dashboard--opencode-list-sessions-fn ()
  "Opencode `:list-sessions-fn' — non-archived sessions, newest first."
  (or (claude-dashboard--with-opencode-db db
        (let ((rows (sqlite-select
                     db
                     "SELECT id, directory, title, time_updated \
                      FROM session \
                      WHERE time_archived IS NULL \
                      ORDER BY time_updated DESC")))
          (mapcar #'claude-dashboard--opencode-row-session rows)))
      '()))

;; ----- Codex -----------------------------------------------------------
;;
;; Codex writes one JSONL per session to
;;   ~/.codex/sessions/YYYY/MM/DD/rollout-<TS>-<UUID>.jsonl
;; The first line is a meta record carrying session_id, cwd, model,
;; and a timestamp.  Subsequent lines are RolloutLine entries; the
;; ones we care about are ResponseItem rows with role user/assistant
;; and a content[0].text field.

(defun claude-dashboard--codex-state-dir ()
  "Resolve codex's state directory."
  (or claude-dashboard-claude-dir
      (claude-dashboard--backend-prop :state-dir 'codex)))

(defun claude-dashboard--codex-rollout-files (&optional max-depth-days)
  "Return rollout JSONL paths under codex's sessions dir, newest first.
MAX-DEPTH-DAYS, when non-nil, restricts the scan to the most
recent N day-directories (cheaper than a full walk; live discovery
only needs today + yesterday)."
  (let* ((sessions (expand-file-name "sessions"
                                     (claude-dashboard--codex-state-dir)))
         files)
    (when (file-directory-p sessions)
      (let ((day-dirs '()))
        ;; YYYY/MM/DD layout.
        (dolist (y (directory-files sessions t "^[0-9]"))
          (when (file-directory-p y)
            (dolist (m (directory-files y t "^[0-9]"))
              (when (file-directory-p m)
                (dolist (d (directory-files m t "^[0-9]"))
                  (when (file-directory-p d)
                    (push d day-dirs)))))))
        (setq day-dirs
              (sort day-dirs
                    (lambda (a b)
                      (time-less-p
                       (file-attribute-modification-time
                        (file-attributes b))
                       (file-attribute-modification-time
                        (file-attributes a))))))
        (when max-depth-days
          (setq day-dirs (seq-take day-dirs max-depth-days)))
        (dolist (d day-dirs)
          (dolist (f (directory-files d t "^rollout-.*\\.jsonl\\'"))
            (push f files)))))
    (sort files
          (lambda (a b)
            (time-less-p (file-attribute-modification-time
                          (file-attributes b))
                         (file-attribute-modification-time
                          (file-attributes a)))))))

(defun claude-dashboard--codex-read-header (path)
  "Return the parsed meta-record (alist) from the head of rollout PATH."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path nil 0 8192)
      (goto-char (point-min))
      (ignore-errors
        (json-parse-buffer :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object nil)))))

(defun claude-dashboard--codex-header-meta (header)
  "Return the `payload' / meta sub-alist from a rollout HEADER record.
Codex's header schema has evolved: older rollouts carry `meta'
directly at top-level, newer ones nest it under `payload'."
  (or (alist-get 'payload header)
      (alist-get 'meta header)
      header))

(defun claude-dashboard--codex-session-id-fn (inst)
  "Codex `:session-id-fn' — newest rollout whose meta.cwd = INST cwd."
  (let* ((target (directory-file-name
                  (claude-dashboard-instance-cwd inst)))
         (started (or (claude-dashboard-instance-started-at inst) 0)))
    (cl-some
     (lambda (path)
       (let* ((mtime (float-time
                      (file-attribute-modification-time
                       (file-attributes path))))
              (header (claude-dashboard--codex-read-header path))
              (meta (claude-dashboard--codex-header-meta header))
              (cwd (and meta (alist-get 'cwd meta)))
              (sid (and meta (or (alist-get 'session_id meta)
                                 (alist-get 'id meta)))))
         (when (and cwd sid
                    (>= mtime (- started 5.0))
                    (equal (directory-file-name cwd) target))
           sid)))
     ;; Today + yesterday is enough for live discovery.
     (claude-dashboard--codex-rollout-files 2))))

(defun claude-dashboard--codex-session-name-fn (_inst)
  "Codex `:session-name-fn' — codex has no live rename file yet."
  nil)

(defun claude-dashboard--codex-transcript-path-fn (_cwd sid)
  "Codex `:transcript-path-fn' — find the rollout JSONL for SID."
  (when sid
    (cl-some
     (lambda (path)
       (let* ((header (claude-dashboard--codex-read-header path))
              (meta (claude-dashboard--codex-header-meta header))
              (this-sid (and meta (or (alist-get 'session_id meta)
                                      (alist-get 'id meta)))))
         (and (equal this-sid sid) path)))
     (claude-dashboard--codex-rollout-files))))

(defun claude-dashboard--codex-transcript-walk-fn (path)
  "Codex `:transcript-walk-fn' — walk rollout JSONL, normalize messages.
Skips the header record; only ResponseItem rows with role
user/assistant and a content[0].text field are emitted."
  (let (msgs)
    (with-temp-buffer
      (when (file-readable-p path)
        (insert-file-contents path)
        (goto-char (point-min))
        ;; Skip header.
        (forward-line 1)
        (while (not (eobp))
          (when (looking-at "{")
            (let* ((entry (ignore-errors
                            (json-parse-buffer
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))))
              (goto-char (line-beginning-position))
              (when entry
                (let* ((type (alist-get 'type entry))
                       (payload (or (alist-get 'payload entry) entry))
                       (item-type (alist-get 'type payload))
                       (role-str (alist-get 'role payload))
                       (role (pcase role-str
                               ("user" 'user)
                               ("assistant" 'assistant)
                               (_ nil)))
                       (content (alist-get 'content payload))
                       (text (cond
                              ((stringp content) content)
                              ((listp content)
                               (when-let ((tb (cl-find-if
                                               (lambda (c)
                                                 (and (listp c)
                                                      (or (equal "input_text"
                                                                 (alist-get 'type c))
                                                          (equal "output_text"
                                                                 (alist-get 'type c))
                                                          (equal "text"
                                                                 (alist-get 'type c)))))
                                               content)))
                                 (alist-get 'text tb)))))
                       (ts-str (alist-get 'timestamp entry))
                       (ts (and ts-str (ignore-errors
                                         (float-time (date-to-time ts-str))))))
                  (when (and role
                             (or (equal item-type "message")
                                 (equal type "response_item"))
                             (stringp text)
                             (> (length (string-trim text)) 0))
                    (push `((role . ,role)
                            (text . ,(string-trim text))
                            (ts   . ,ts)
                            (raw  . ,entry))
                          msgs))))))
          (forward-line 1))))
    (nreverse msgs)))

(defun claude-dashboard--codex-list-sessions-fn ()
  "Codex `:list-sessions-fn' — every rollout file, header parsed."
  (let (acc)
    (dolist (path (claude-dashboard--codex-rollout-files))
      (let* ((header (claude-dashboard--codex-read-header path))
             (meta (claude-dashboard--codex-header-meta header))
             (sid (and meta (or (alist-get 'session_id meta)
                                (alist-get 'id meta))))
             (cwd (and meta (alist-get 'cwd meta)))
             (mtime (file-attribute-modification-time
                     (file-attributes path))))
        (when (and sid cwd)
          (push (make-claude-dashboard-past-session
                 :session-id sid
                 :cwd (file-name-as-directory cwd)
                 :mtime mtime
                 :first-prompt nil
                 :jsonl-path path)
                acc))))
    (nreverse acc)))

(defun claude-dashboard--codex-rename-fn (proc slug)
  "Codex `:rename-fn' — `/rename SLUG' via the split-write rule.
TUI input lines occasionally drop their CR if the body + newline
arrive in the same write; sending the body, sitting for 50ms, and
then writing a lone `\\r' reliably lands the command."
  (when (and proc (process-live-p proc) slug (not (string-empty-p slug)))
    (process-send-string proc (format "/rename %s" slug))
    (sit-for 0.05)
    (process-send-string proc "\r")
    t))

(provide 'claude-dashboard)
;;; claude-dashboard.el ends here
