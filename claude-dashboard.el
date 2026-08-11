;;; claude-dashboard.el --- Backward-compat shim for llm-dashboard -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (llm-dashboard "0.2"))
;; Keywords: tools, processes
;; URL: https://github.com/afermg/emacs-llm-dashboard

;;; Commentary:

;; The package was renamed from `claude-dashboard' to `llm-dashboard'.
;; This shim keeps `(require 'claude-dashboard)' working for one
;; release cycle — it just forwards to `llm-dashboard', which installs
;; the `claude-dashboard-*' → `llm-dashboard-*' aliases on load.

;;; Code:

(require 'llm-dashboard)
(provide 'claude-dashboard)
;;; claude-dashboard.el ends here
