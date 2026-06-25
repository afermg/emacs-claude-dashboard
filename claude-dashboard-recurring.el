;;; claude-dashboard-recurring.el --- Backward-compat shim for llm-dashboard-recurring -*- lexical-binding: t; -*-

;; Author: Alán F. Muñoz
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (llm-dashboard "0.2") (claude-dashboard-schedule "0.2"))
;; Keywords: tools, convenience

;;; Commentary:

;; Transitional shim — forwards `(require 'claude-dashboard-recurring)' to
;; the renamed `llm-dashboard-recurring'.  Drop on the next major version.

;;; Code:

(require 'llm-dashboard-recurring)
(provide 'claude-dashboard-recurring)
;;; claude-dashboard-recurring.el ends here
