;;; llm-dashboard-test.el --- Tests for llm-dashboard -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'llm-dashboard)

(defun llm-dashboard-test--instance (buffer cwd &optional sid)
  "Build a minimal Pi instance for BUFFER, CWD, and optional SID."
  (make-llm-dashboard-instance
   :buffer buffer :cwd cwd :started-at 1.0 :last-output 1.0
   :session-id sid :backend 'pi))

(ert-deftest llm-dashboard-test-pi-terminal-session-name ()
  "Pi OSC titles identify named branches without losing embedded separators."
  (let* ((root (make-temp-file "llm-dashboard-title-" t))
         (cwd (expand-file-name "sample-project" root))
         (buf (generate-new-buffer " *llm-dashboard-title*"))
         (inst (llm-dashboard-test--instance buf cwd)))
    (unwind-protect
        (progn
          (make-directory cwd)
          (dolist (case '(("π - build-api - sample-project" . "build-api")
                          ("π - sample-project" . nil)
                          ("⠼ π - live-review - sample-project" . "live-review")
                          ("π - review - followup - sample-project"
                           . "review - followup")
                          ("editor: π - injected - sample-project" . nil)))
            (with-current-buffer buf
              (setq-local ghostel--title (car case)))
            (should (equal (cdr case)
                           (llm-dashboard--pi-terminal-session-name inst))))
          (with-current-buffer buf
            (setq-local ghostel--title "π - sample-project"))
          (should (equal '(t)
                         (llm-dashboard--pi-terminal-title-state inst))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-pi-live-topics-distinguish-shared-session ()
  "Two Pi branches sharing one SID use their distinct live titles."
  (let* ((root (make-temp-file "llm-dashboard-shared-" t))
         (cwd (expand-file-name "project" root))
         (buf-a (generate-new-buffer " *llm-dashboard-branch-a*"))
         (buf-b (generate-new-buffer " *llm-dashboard-branch-b*"))
         (inst-a (llm-dashboard-test--instance buf-a cwd "shared-sid"))
         (inst-b (llm-dashboard-test--instance buf-b cwd "shared-sid"))
         (llm-dashboard--topic-cache (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (make-directory cwd)
          (with-current-buffer buf-a
            (setq-local ghostel--title "π - rename-figs - project"))
          (with-current-buffer buf-b
            (setq-local ghostel--title "⠋ π - cpg-adj - project"))
          ;; Reproduce the old failure: a plausible but unrelated topic was
          ;; already cached for each buffer.
          (puthash buf-a (cons "P wrong-a" (float-time))
                   llm-dashboard--topic-cache)
          (puthash buf-b (cons "P wrong-b" (float-time))
                   llm-dashboard--topic-cache)
          (should (equal "P rename-figs"
                         (substring-no-properties
                          (llm-dashboard--instance-topic inst-a))))
          (should (equal "P cpg-adj"
                         (substring-no-properties
                          (llm-dashboard--instance-topic inst-b)))))
      (dolist (buf (list buf-a buf-b))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-pi-named-to-unnamed-bypasses-topic-cache ()
  "A recognized unnamed Pi title immediately replaces a cached live name."
  (let* ((root (make-temp-file "llm-dashboard-unnamed-" t))
         (cwd (expand-file-name "project" root))
         (buf (generate-new-buffer " *llm-dashboard-unnamed*"))
         (inst (llm-dashboard-test--instance buf cwd))
         (llm-dashboard--topic-cache (make-hash-table :test 'eq))
         (llm-dashboard--worktree-names (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (make-directory cwd)
          (puthash buf "fallback" llm-dashboard--worktree-names)
          (with-current-buffer buf
            (setq-local ghostel--title "π - named - project"))
          (should (equal "P named"
                         (substring-no-properties
                          (llm-dashboard--instance-topic inst))))
          (with-current-buffer buf
            (setq-local ghostel--title "π - project"))
          (cl-letf (((symbol-function 'llm-dashboard--live-session-id)
                     (lambda (_) nil))
                    ((symbol-function
                      'llm-dashboard--session-name-from-transcript)
                     (lambda (&rest _) nil)))
            (should (equal "P fallback"
                           (substring-no-properties
                            (llm-dashboard--instance-topic inst))))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-register-canonicalizes-and-seeds-session ()
  "Registration resolves local aliases and installs a known SID immediately."
  (let* ((root (make-temp-file "llm-dashboard-register-" t))
         (real (expand-file-name "real/project" root))
         (alias (expand-file-name "alias" root))
         (buf (generate-new-buffer " *llm-dashboard-register*"))
         (llm-dashboard--instances (make-hash-table :test 'eq))
         (llm-dashboard--explicit-session-ids (make-hash-table :test 'eq))
         observed)
    (unwind-protect
        (progn
          (make-directory real t)
          (make-symbolic-link real alias)
          ;; Symlink resolution is Pi-specific; other backends keep the path
          ;; the user launched from.
          (should (equal (file-name-as-directory alias)
                         (llm-dashboard--normalize-cwd alias)))
          (should (equal (file-name-as-directory (file-truename real))
                         (llm-dashboard--normalize-cwd alias t)))
          (let ((llm-dashboard-claude-dir
                 (file-name-as-directory (expand-file-name "state" root))))
            (should (equal (llm-dashboard--pi-session-directory alias)
                           (llm-dashboard--pi-session-directory real))))
          (cl-letf (((symbol-function 'llm-dashboard--git-branch)
                     (lambda (_) nil))
                    ((symbol-function 'llm-dashboard--configure-managed-terminal)
                     #'ignore)
                    ((symbol-function 'llm-dashboard--write-manifest) #'ignore)
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'llm-dashboard--retag-buffer)
                     (lambda (inst)
                       (setq observed
                             (list (llm-dashboard-instance-session-id inst)
                                   (gethash buf
                                            llm-dashboard--explicit-session-ids))))))
            (let ((inst (llm-dashboard--register
                         buf (concat alias "/.git/objects") 'pi "known-sid")))
              (should (equal (file-name-as-directory (file-truename real))
                             (llm-dashboard-instance-cwd inst)))
              (should (equal "known-sid"
                             (llm-dashboard-instance-session-id inst)))
              (should (equal '("known-sid" "known-sid") observed)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-pi-explicit-sid-survives-duplicates-and-churn ()
  "Explicit Pi resume IDs remain authoritative with duplicate owners."
  (let* ((root (make-temp-file "llm-dashboard-explicit-" t))
         (cwd (expand-file-name "project" root))
         (state (expand-file-name "state" root))
         (buf-a (generate-new-buffer " *llm-dashboard-explicit-a*"))
         (buf-b (generate-new-buffer " *llm-dashboard-explicit-b*"))
         (inst-a (llm-dashboard-test--instance buf-a cwd "same-sid"))
         (inst-b (llm-dashboard-test--instance buf-b cwd "same-sid"))
         (llm-dashboard-claude-dir state)
         (llm-dashboard--instances (make-hash-table :test 'eq))
         (llm-dashboard--explicit-session-ids (make-hash-table :test 'eq))
         (llm-dashboard--pi-transcript-path-cache (make-hash-table :test 'equal))
         (llm-dashboard--pi-unresolved-directory-mtimes
          (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (make-directory cwd)
          (make-directory state)
          (puthash buf-a inst-a llm-dashboard--instances)
          (puthash buf-b inst-b llm-dashboard--instances)
          (puthash buf-a "same-sid" llm-dashboard--explicit-session-ids)
          (puthash buf-b "same-sid" llm-dashboard--explicit-session-ids)
          (should (equal "same-sid" (llm-dashboard--pi-session-id-fn inst-a)))
          (should (equal "same-sid" (llm-dashboard--pi-session-id-fn inst-b)))
          ;; Churn the canonical project session directory with an unrelated ID.
          (let ((dir (llm-dashboard--pi-session-directory cwd)))
            (make-directory dir t)
            (with-temp-file (expand-file-name "new_unrelated.jsonl" dir)
              (insert "{}\n")))
          (should (equal "same-sid" (llm-dashboard--pi-session-id-fn inst-a)))
          (should (equal "same-sid" (llm-dashboard--pi-session-id-fn inst-b))))
      (dolist (buf (list buf-a buf-b))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-shared-sid-cache-ownership ()
  "A surviving Pi branch keeps shared transcript caches alive."
  (let* ((buf-a (generate-new-buffer " *llm-dashboard-owner-a*"))
         (buf-b (generate-new-buffer " *llm-dashboard-owner-b*"))
         (inst-a (llm-dashboard-test--instance buf-a "/tmp/project/" "sid"))
         (inst-b (llm-dashboard-test--instance buf-b "/tmp/project/" "sid"))
         (llm-dashboard--instances (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (puthash buf-a inst-a llm-dashboard--instances)
          (puthash buf-b inst-b llm-dashboard--instances)
          (should (llm-dashboard--pi-sid-used-by-other-instance-p
                   buf-a "sid"))
          (remhash buf-b llm-dashboard--instances)
          (should-not (llm-dashboard--pi-sid-used-by-other-instance-p
                       buf-a "sid")))
      (dolist (buf (list buf-a buf-b))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest llm-dashboard-test-pi-fresh-sessions-match-process-start ()
  "Fresh Pi buffers match UUID creation time, not mutable file mtimes."
  (let* ((root (make-temp-file "llm-dashboard-start-match-" t))
         (cwd (expand-file-name "project" root))
         (state (expand-file-name "state" root))
         (path-a (expand-file-name "a.jsonl" root))
         (path-b (expand-file-name "b.jsonl" root))
         (path-external (expand-file-name "external.jsonl" root))
         (buf-a (generate-new-buffer " *llm-dashboard-start-a*"))
         (buf-b (generate-new-buffer " *llm-dashboard-start-b*"))
         (inst-a (llm-dashboard-test--instance buf-a cwd))
         (inst-b (llm-dashboard-test--instance buf-b cwd))
         (llm-dashboard-claude-dir state)
         (llm-dashboard--instances (make-hash-table :test 'eq))
         (llm-dashboard--explicit-session-ids (make-hash-table :test 'eq))
         (llm-dashboard--pi-transcript-path-cache (make-hash-table :test 'equal))
         (llm-dashboard--pi-unresolved-directory-mtimes
          (make-hash-table :test 'eq))
         candidates)
    (unwind-protect
        (progn
          (make-directory cwd)
          (make-directory state)
          (dolist (path (list path-a path-b path-external))
            (with-temp-file path (insert "{}\n")))
          (setf (llm-dashboard-instance-started-at inst-a) 100.0
                (llm-dashboard-instance-started-at inst-b) 200.0)
          (puthash buf-a inst-a llm-dashboard--instances)
          (puthash buf-b inst-b llm-dashboard--instances)
          ;; Deliberately give the external candidate the newest mtime-like
          ;; ordering.  Creation time nearest each process must win.
          (setq candidates
                (list (list :sid "external" :cwd cwd :created-at 220.0
                            :mtime '(99999 0 0 0) :path path-external)
                      (list :sid "sid-b" :cwd cwd :created-at 201.0
                            :mtime '(10 0 0 0) :path path-b)
                      (list :sid "sid-a" :cwd cwd :created-at 101.0
                            :mtime '(20 0 0 0) :path path-a)))
          (cl-letf (((symbol-function
                      'llm-dashboard--pi-instance-process-started-at)
                     (lambda (inst)
                       (llm-dashboard-instance-started-at inst)))
                    ((symbol-function 'llm-dashboard--pi-session-candidates)
                     (lambda (&optional _) candidates)))
            (should (equal "sid-a"
                           (llm-dashboard--pi-session-id-fn inst-a)))
            (setf (llm-dashboard-instance-session-id inst-a) "sid-a")
            (should (equal "sid-b"
                           (llm-dashboard--pi-session-id-fn inst-b)))
            (setf (llm-dashboard-instance-session-id inst-b) "sid-b")
            ;; Later unrelated session creation must not dislodge a unique
            ;; cached assignment.
            (should (equal "sid-a"
                           (llm-dashboard--pi-session-id-fn inst-a)))
            (should (equal "sid-b"
                           (llm-dashboard--pi-session-id-fn inst-b)))))
      (dolist (buf (list buf-a buf-b))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-pi-rejects-delayed-unrelated-session ()
  "A missing fresh transcript is safer than borrowing a later subagent SID."
  (let* ((root (make-temp-file "llm-dashboard-delayed-" t))
         (cwd (expand-file-name "project" root))
         (buf (generate-new-buffer " *llm-dashboard-delayed*"))
         (inst (llm-dashboard-test--instance buf cwd))
         (llm-dashboard--instances (make-hash-table :test 'eq))
         (llm-dashboard--explicit-session-ids (make-hash-table :test 'eq))
         (llm-dashboard--pi-transcript-path-cache (make-hash-table :test 'equal))
         (llm-dashboard--pi-unresolved-directory-mtimes
          (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (make-directory cwd)
          (puthash buf inst llm-dashboard--instances)
          (cl-letf (((symbol-function
                      'llm-dashboard--pi-instance-process-started-at)
                     (lambda (_) 100.0))
                    ((symbol-function 'llm-dashboard--pi-session-candidates)
                     (lambda (&optional _)
                       (list (list :sid "unrelated" :cwd cwd
                                   :created-at 120.0 :mtime '(1 0 0 0)
                                   :path (expand-file-name "other" root))))))
            (should-not (llm-dashboard--pi-session-id-fn inst))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-pi-non-v7-header-time-fallback ()
  "CWD-scoped discovery reads a header for a non-UUIDv7 session ID."
  (let* ((root (make-temp-file "llm-dashboard-legacy-id-" t))
         (cwd (expand-file-name "project" root))
         (state (expand-file-name "state" root))
         (llm-dashboard-claude-dir state))
    (unwind-protect
        (progn
          (make-directory cwd)
          (let* ((dir (llm-dashboard--pi-session-directory cwd))
                 (path (expand-file-name
                        "2026-08-11T12-00-00-000Z_legacy-id.jsonl" dir)))
            (make-directory dir t)
            (with-temp-file path
              (insert (format
                       "{\"type\":\"session\",\"id\":\"legacy-id\",\"timestamp\":\"2026-08-11T16:00:00.000Z\",\"cwd\":%S}\n"
                       cwd)))
            (let ((candidate (car (llm-dashboard--pi-session-candidates cwd))))
              (should (equal "legacy-id" (plist-get candidate :sid)))
              (should (numberp (plist-get candidate :created-at))))))
      (delete-directory root t))))

(ert-deftest llm-dashboard-test-resume-picker-passes-known-sid-to-launch ()
  "The resume picker hands its SID to launch, not a post-launch mutation."
  (let* ((sess (make-llm-dashboard-past-session
                :session-id "picked-sid" :cwd "/tmp/project/"))
         captured)
    (cl-letf (((symbol-function 'llm-dashboard--read-past-session)
               (lambda (_) sess))
              ((symbol-function 'llm-dashboard--backend-prop)
               (lambda (&rest _) "--session"))
              ((symbol-function 'llm-dashboard--launch)
               (lambda (cwd args &optional sid)
                 (setq captured (list cwd args sid)))))
      (llm-dashboard-resume)
      (should (equal '("/tmp/project/" ("--session" "picked-sid")
                       "picked-sid")
                     captured)))))

(ert-deftest llm-dashboard-test-resume-all-passes-known-sid-to-launch ()
  "Manifest recovery seeds its known SID before registration."
  (let* ((cwd (make-temp-file "llm-dashboard-resume-all-" t))
         (entry (list :cwd cwd :sid "manifest-sid" :backend 'pi))
         captured)
    (unwind-protect
        (cl-letf (((symbol-function 'llm-dashboard--read-manifest)
                   (lambda () (list entry)))
                  ((symbol-function 'llm-dashboard--instances-list)
                   (lambda () nil))
                  ((symbol-function 'llm-dashboard--backend-prop)
                   (lambda (&rest _) "--session"))
                  ((symbol-function 'llm-dashboard--launch)
                   (lambda (launch-cwd args &optional sid)
                     (setq captured (list launch-cwd args sid))))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                  ((symbol-function 'message) #'ignore))
          (llm-dashboard-resume-all)
          (should (equal (list (llm-dashboard--normalize-cwd cwd)
                               '("--session" "manifest-sid")
                               "manifest-sid")
                         captured)))
      (delete-directory cwd t))))

(ert-deftest llm-dashboard-test-auto-name-preserves-live-pi-name ()
  "Auto-name does not overwrite a live title on a resumed Pi branch."
  (let* ((buf (generate-new-buffer " *llm-dashboard-auto-name*"))
         (inst (llm-dashboard-test--instance buf "/tmp/project/" "sid"))
         (llm-dashboard-auto-name-after-turns 5)
         (llm-dashboard--name-injected (make-hash-table :test 'eq))
         renamed)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local ghostel--title "π - already-named - project"))
          (cl-letf (((symbol-function 'llm-dashboard--instance-process)
                     (lambda (_) 'fake-process))
                    ((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'llm-dashboard--status)
                     (lambda (_) 'idle))
                    ((symbol-function 'llm-dashboard--live-session-id)
                     (lambda (_) "sid"))
                    ((symbol-function 'llm-dashboard--backend-prop)
                     (lambda (key &optional _)
                       (memq key '(:supports-auto-name :rename-fn))))
                    ((symbol-function 'llm-dashboard--backend-call)
                     (lambda (&rest _)
                       (setq renamed t))))
            (llm-dashboard--maybe-auto-name inst)
            (should-not renamed)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'llm-dashboard-test)
;;; llm-dashboard-test.el ends here
