;;; claude-dashboard-usage.el --- Backward-compat shim for llm-dashboard-usage -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (llm-dashboard "0.2") (claude-dashboard-schedule "0.2"))
;; Keywords: tools, convenience

;;; Commentary:

;; Transitional shim — forwards `(require 'claude-dashboard-usage)' to
;; the renamed `llm-dashboard-usage'.  Drop on the next major version.

;;; Code:

(require 'llm-dashboard-usage)
(provide 'claude-dashboard-usage)
;;; claude-dashboard-usage.el ends here
