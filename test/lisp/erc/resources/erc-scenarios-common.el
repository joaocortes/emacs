;;; erc-scenarios-common.el --- Common helpers for ERC scenarios -*- lexical-binding: t -*-

;; Copyright (C) 2022 Free Software Foundation, Inc.
;;
;; This file is part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; These are e2e-ish test cases primarily intended to assert core,
;; fundamental behavior expected of any modern IRC client.  Tests may
;; also simulate specific scenarios drawn from bug reports.  Incoming
;; messages are provided by playback scripts resembling I/O logs.  In
;; place of time stamps, they have time deltas, which are used to
;; govern the test server in a fashion reminiscent of music rolls (or
;; the script(1) UNIX program).  These scripts can be found in the
;; other directories under test/lisp/erc/resources.
;;
;; Isolation:
;;
;; The set of enabled modules is shared among all tests.  The function
;; `erc-update-modules' activates them (as minor modes), but it never
;; deactivates them.  So there's no going back, and let-binding
;; `erc-modules' is useless.  The safest route is therefore to (1)
;; assume the set of default modules is already activated or will be
;; over the course of the test session and (2) let-bind relevant user
;; options as needed.  For example, to limit the damage of
;; `erc-autojoin-channels-alist' to a given test, assume the
;; `erc-join' library has already been loaded or will be on the next
;; call to `erc-open'.  And then just let-bind
;; `erc-autojoin-channels-alist' for the duration of the test.
;;
;; Playing nice:
;;
;; Right now, these tests all rely on an ugly fixture macro named
;; `erc-scenarios-common-with-cleanup', which is defined just below.
;; It helps restore (but not really prepare) the environment by
;; destroying any stray processes or buffers named in the first
;; argument, a `let*'-style VAR-LIST.  Relying on such a macro is
;; unfortunate because in many ways it actually hampers readability by
;; favoring magic over verbosity.  But without it (or something
;; similar), any failing test would cause all subsequent tests in this
;; file to fail like dominoes (making all but the first backtrace
;; useless).
;;
;; Misc:
;;
;; Note that in the following examples, nicknames Alice and Bob are
;; always associated with the fake network FooNet, while nicks Joe and
;; Mike are always on BarNet.  (Networks are sometimes downcased.)
;;
;; XXX This file should *not* contain any test cases.

;;; Code:

(require 'ert-x) ; cl-lib
(eval-and-compile
  (let* ((d (expand-file-name ".." (ert-resource-directory)))
         (load-path (cons (concat d "/erc-d") load-path)))
    (require 'erc-d-t)
    (require 'erc-d)))

(require 'erc-backend)

(eval-when-compile (require 'erc-join)
                   (require 'erc-services))

(declare-function erc-network "erc-networks")
(defvar erc-network)

(defvar erc-scenarios-common--resources-dir
  (expand-file-name "../" (ert-resource-directory)))

;; Teardown is already inhibited when running interactively, which
;; prevents subsequent tests from succeeding, so we might as well
;; treat inspection as the goal.
(unless noninteractive
  (setq erc-server-auto-reconnect nil))

(defvar erc-scenarios-common-dialog nil)
(defvar erc-scenarios-common-extra-teardown nil)

(defun erc-scenarios-common--add-silence ()
  (advice-add #'erc-login :around #'erc-d-t-silence-around)
  (advice-add #'erc-handle-login :around #'erc-d-t-silence-around)
  (advice-add #'erc-server-connect :around #'erc-d-t-silence-around))

(defun erc-scenarios-common--remove-silence ()
  (advice-remove #'erc-login #'erc-d-t-silence-around)
  (advice-remove #'erc-handle-login #'erc-d-t-silence-around)
  (advice-remove #'erc-server-connect #'erc-d-t-silence-around))

(defun erc-scenarios-common--print-trace ()
  (when (and (boundp 'trace-buffer) (get-buffer trace-buffer))
    (with-current-buffer trace-buffer
      (message "%S" (buffer-string))
      (kill-buffer))))

(eval-and-compile
  (defun erc-scenarios-common--make-bindings (bindings)
    `((erc-d-u-canned-dialog-dir (expand-file-name
                                  (or erc-scenarios-common-dialog
                                      (cadr (assq 'erc-scenarios-common-dialog
                                                  ',bindings)))
                                  erc-scenarios-common--resources-dir))
      (erc-d-tmpl-vars `(,@erc-d-tmpl-vars
                         (quit . ,(erc-quit/part-reason-default))
                         (erc-version . ,erc-version)))
      (erc-modules (copy-sequence erc-modules))
      (inhibit-interaction t)
      (auth-source-do-cache nil)
      (erc-autojoin-channels-alist nil)
      (erc-server-auto-reconnect nil)
      (erc-d-linger-secs 10)
      ,@bindings)))

(defmacro erc-scenarios-common-with-cleanup (bindings &rest body)
  "Provide boilerplate cleanup tasks after calling BODY with BINDINGS.

If an `erc-d' process exists, wait for it to start before running BODY.
If `erc-autojoin-mode' mode is bound, restore it during cleanup if
disabled by BODY.  Other defaults common to these test cases are added
below and can be overridden, except when wanting the \"real\" default
value, which must be looked up or captured outside of the calling form.

Dialog resource directories are located by expanding the variable
`erc-scenarios-common-dialog' or its value in BINDINGS."
  (declare (indent 1))

  (let* ((orig-autojoin-mode (make-symbol "orig-autojoin-mode"))
         (combind `((,orig-autojoin-mode (bound-and-true-p erc-autojoin-mode))
                    ,@(erc-scenarios-common--make-bindings bindings))))

    `(erc-d-t-with-cleanup (,@combind)

         (ert-info ("Restore autojoin, etc., kill ERC buffers")
           (dolist (buf (buffer-list))
             (when-let ((erc-d-u--process-buffer)
                        (proc (get-buffer-process buf)))
               (delete-process proc)))

           (erc-scenarios-common--remove-silence)

           (when erc-scenarios-common-extra-teardown
             (ert-info ("Running extra teardown")
               (funcall erc-scenarios-common-extra-teardown)))

           (when (and (boundp 'erc-autojoin-mode)
                      (not (eq erc-autojoin-mode ,orig-autojoin-mode)))
             (erc-autojoin-mode (if ,orig-autojoin-mode +1 -1)))

           (when noninteractive
             (erc-scenarios-common--print-trace)
             (erc-d-t-kill-related-buffers)
             (delete-other-windows)))

       (erc-scenarios-common--add-silence)

       (ert-info ("Wait for dumb server")
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when erc-d-u--process-buffer
               (erc-d-t-search-for 3 "Starting")))))

       (ert-info ("Activate erc-debug-irc-protocol")
         (unless (and noninteractive (not erc-debug-irc-protocol))
           (erc-toggle-debug-irc-protocol)))

       ,@body)))

(defun erc-scenarios-common-assert-initial-buf-name (id port)
  ;; Assert no limbo period when explicit ID given
  (should (string= (if id
                       (symbol-name id)
                     (format "127.0.0.1:%d" port))
                   (buffer-name))))

(defun erc-scenarios-common-buflist (prefix)
  "Return list of buffers with names sharing PREFIX."
  (let (case-fold-search)
    (erc-networks--id-sort-buffers
     (delq nil
           (mapcar (lambda (b)
                     (when (string-prefix-p prefix (buffer-name b)) b))
                   (buffer-list))))))

;; This is more realistic than `erc-send-message' because it runs
;; `erc-pre-send-functions', etc.  Keyboard macros may be preferable,
;; but they sometimes experience complications when an earlier test
;; has failed.
(defun erc-scenarios-common-say (str)
  (let (erc-accidental-paste-threshold-seconds)
    (goto-char erc-input-marker)
    (insert str)
    (erc-send-current-line)))


;;;; Fixtures

(cl-defun erc-scenarios-common--base-network-id-bouncer
    ((&key autop foo-id bar-id after
           &aux
           (foo-id (and foo-id 'oofnet))
           (bar-id (and bar-id 'rabnet))
           (serv-buf-foo (if foo-id "oofnet" "foonet"))
           (serv-buf-bar (if bar-id "rabnet" "barnet"))
           (chan-buf-foo (if foo-id "#chan@oofnet" "#chan@foonet"))
           (chan-buf-bar (if bar-id "#chan@rabnet" "#chan@barnet")))
     &rest dialogs)
  "Ensure retired option `erc-rename-buffers' is now the default behavior.
The option `erc-rename-buffers' is now deprecated and on by default, so
this now just asserts baseline behavior.  Originally from scenario
clash-of-chans/rename-buffers as explained in Bug#48598: 28.0.50;
buffer-naming collisions involving bouncers in ERC."
  (erc-scenarios-common-with-cleanup
      ((erc-scenarios-common-dialog "base/netid/bouncer")
       (erc-d-t-cleanup-sleep-secs 1)
       (erc-server-flood-penalty 0.1)
       (dumb-server (apply #'erc-d-run "localhost" t dialogs))
       (port (process-contact dumb-server :service))
       (expect (erc-d-t-make-expecter))
       (erc-server-auto-reconnect autop)
       erc-server-buffer-foo erc-server-process-foo
       erc-server-buffer-bar erc-server-process-bar)

    (ert-info ("Connect to foonet")
      (with-current-buffer
          (setq erc-server-buffer-foo (erc :server "127.0.0.1"
                                           :port port
                                           :nick "tester"
                                           :password "foonet:changeme"
                                           :full-name "tester"
                                           :id foo-id))
        (setq erc-server-process-foo erc-server-process)
        (erc-scenarios-common-assert-initial-buf-name foo-id port)
        (erc-d-t-wait-for 3 (eq (erc-network) 'foonet))
        (erc-d-t-wait-for 3 (string= (buffer-name) serv-buf-foo))
        (funcall expect 5 "foonet")))

    (ert-info ("Join #chan@foonet")
      (with-current-buffer erc-server-buffer-foo (erc-cmd-JOIN "#chan"))
      (with-current-buffer (erc-d-t-wait-for 5 (get-buffer "#chan"))
        (funcall expect 5 "<alice>")))

    (ert-info ("Connect to barnet")
      (with-current-buffer
          (setq erc-server-buffer-bar (erc :server "127.0.0.1"
                                           :port port
                                           :nick "tester"
                                           :password "barnet:changeme"
                                           :full-name "tester"
                                           :id bar-id))
        (setq erc-server-process-bar erc-server-process)
        (erc-scenarios-common-assert-initial-buf-name bar-id port)
        (erc-d-t-wait-for 6 (eq (erc-network) 'barnet))
        (erc-d-t-wait-for 3 (string= (buffer-name) serv-buf-bar))
        (funcall expect 5 "barnet")))

    (ert-info ("Server buffers are unique, no names based on IPs")
      (should-not (eq erc-server-buffer-foo erc-server-buffer-bar))
      (should-not (erc-scenarios-common-buflist "127.0.0.1")))

    (ert-info ("Join #chan@barnet")
      (with-current-buffer erc-server-buffer-bar (erc-cmd-JOIN "#chan")))

    (erc-d-t-wait-for 5 "Exactly 2 #chan-prefixed buffers exist"
      (equal (list (get-buffer chan-buf-bar)
                   (get-buffer chan-buf-foo))
             (erc-scenarios-common-buflist "#chan")))

    (ert-info ("#chan@<esid> is exclusive to foonet")
      (with-current-buffer chan-buf-foo
        (erc-d-t-search-for 1 "<bob>")
        (erc-d-t-absent-for 0.1 "<joe>")
        (should (eq erc-server-process erc-server-process-foo))
        (erc-d-t-search-for 10 "ape is dead")
        (erc-d-t-wait-for 5 (not (erc-server-process-alive)))))

    (ert-info ("#chan@<esid> is exclusive to barnet")
      (with-current-buffer chan-buf-bar
        (erc-d-t-search-for 1 "<joe>")
        (erc-d-t-absent-for 0.1 "<bob>")
        (erc-d-t-wait-for 5 (eq erc-server-process erc-server-process-bar))
        (erc-d-t-search-for 15 "keeps you from dishonour")
        (erc-d-t-wait-for 5 (not (erc-server-process-alive)))))

    (when after (funcall after))))

(defun erc-scenarios-common--clash-rename-pass-handler (dialog exchange)
  (when (eq (erc-d-dialog-name dialog) 'stub-again)
    (let* ((match (erc-d-exchange-match exchange 1))
           (sym (if (string= match "foonet") 'foonet-again 'barnet-again)))
      (should (member match (list "foonet" "barnet")))
      (erc-d-load-replacement-dialog dialog sym 1))))

(defun erc-scenarios-common--base-network-id-bouncer--reconnect (foo-id bar-id)
  (let ((erc-d-tmpl-vars '((token . (group (| "barnet" "foonet")))))
        (erc-d-match-handlers
         ;; Auto reconnect is nondeterministic, so let computer decide
         (list :pass #'erc-scenarios-common--clash-rename-pass-handler))
        (after
         (lambda ()
           ;; Simulate disconnection and `erc-server-auto-reconnect'
           (ert-info ("Reconnect to foonet and barnet back-to-back")
             (with-current-buffer (if foo-id "oofnet" "foonet")
               (erc-d-t-wait-for 10 (erc-server-process-alive)))
             (with-current-buffer (if bar-id "rabnet" "barnet")
               (erc-d-t-wait-for 10 (erc-server-process-alive))))

           (ert-info ("#chan@foonet is exclusive to foonet")
             (with-current-buffer (if foo-id "#chan@oofnet" "#chan@foonet")
               (erc-d-t-search-for 1 "<alice>")
               (erc-d-t-absent-for 0.1 "<joe>")
               (erc-d-t-search-for 20 "please your lordship")))

           (ert-info ("#chan@barnet is exclusive to barnet")
             (with-current-buffer (if bar-id "#chan@rabnet" "#chan@barnet")
               (erc-d-t-search-for 1 "<joe>")
               (erc-d-t-absent-for 0.1 "<bob>")
               (erc-d-t-search-for 20 "much in private")))

           ;; XXX this is important (reconnects overlapped, so we'd get
           ;; chan@127.0.0.1:6667)
           (should-not (erc-scenarios-common-buflist "127.0.0.1"))
           ;; Reconnection order doesn't matter here because session objects
           ;; are persisted, meaning original timestamps preserved.
           (should (equal (list (get-buffer (if bar-id "#chan@rabnet"
                                              "#chan@barnet"))
                                (get-buffer (if foo-id "#chan@oofnet"
                                              "#chan@foonet")))
                          (erc-scenarios-common-buflist "#chan"))))))
    (erc-scenarios-common--base-network-id-bouncer
     (list :autop t :foo-id foo-id :bar-id bar-id :after after)
     'foonet-drop 'barnet-drop
     'stub-again 'stub-again
     'foonet-again 'barnet-again)))

(defun erc-scenarios-common--upstream-reconnect (test &rest dialogs)
  (erc-scenarios-common-with-cleanup
      ((erc-scenarios-common-dialog "base/upstream-reconnect")
       (erc-d-t-cleanup-sleep-secs 1)
       (erc-server-flood-penalty 0.1)
       (dumb-server (apply #'erc-d-run "localhost" t dialogs))
       (port (process-contact dumb-server :service))
       (expect (erc-d-t-make-expecter)))

    (ert-info ("Connect to foonet")
      (with-current-buffer (erc :server "127.0.0.1"
                                :port port
                                :nick "tester"
                                :user "tester@vanilla/foonet"
                                :password "changeme"
                                :full-name "tester")
        (erc-scenarios-common-assert-initial-buf-name nil port)
        (erc-d-t-wait-for 3 (eq (erc-network) 'foonet))
        (erc-d-t-wait-for 3 (string= (buffer-name) "foonet"))
        (funcall expect 5 "foonet")))

    (ert-info ("Join #chan@foonet")
      (with-current-buffer (erc-d-t-wait-for 5 (get-buffer "#chan"))
        (funcall expect 5 "<alice>")))

    (ert-info ("Connect to barnet")
      (with-current-buffer (erc :server "127.0.0.1"
                                :port port
                                :nick "tester"
                                :user "tester@vanilla/barnet"
                                :password "changeme"
                                :full-name "tester")
        (erc-scenarios-common-assert-initial-buf-name nil port)
        (erc-d-t-wait-for 10 (eq (erc-network) 'barnet))
        (erc-d-t-wait-for 3 (string= (buffer-name) "barnet"))
        (funcall expect 5 "barnet")))

    (ert-info ("Server buffers are unique, no names based on IPs")
      (should-not (erc-scenarios-common-buflist "127.0.0.1")))

    (with-current-buffer (erc-d-t-wait-for 5 (get-buffer "#chan@foonet"))
      (funcall expect 5 "#chan was created on ")
      (ert-info ("Joined again #chan@foonet")
        (funcall expect 10 "#chan was created on "))
      (funcall expect 10 "My lord, in heart"))

    (with-current-buffer (erc-d-t-wait-for 5 (get-buffer "#chan@barnet"))
      (funcall expect 5 "#chan was created on ")
      (ert-info ("Joined again #chan@barnet")
        (funcall expect 10 "#chan was created on "))
      (funcall expect 10 "Go to; farewell"))

    (funcall test)))

(provide 'erc-scenarios-common)

;;; erc-scenarios-common.el ends here
