;;; claude-dashboard-schedule.el --- Backward-compat shim for llm-dashboard-schedule -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (llm-dashboard "0.2"))
;; Keywords: tools, convenience

;;; Commentary:

;; Transitional shim — forwards `(require 'claude-dashboard-schedule)' to
;; the renamed `llm-dashboard-schedule'.  Drop on the next major version.

;;; Code:

(require 'llm-dashboard-schedule)
(provide 'claude-dashboard-schedule)
;;; claude-dashboard-schedule.el ends here
