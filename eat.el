;;; eat.el --- Emulate A Terminal, in a region and in a buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2022, 2023 Akib Azmain Turja.

;; Author: Akib Azmain Turja <akib@disroot.org>
;; Created: 2022-08-15
;; Version: 0.9.4
;; Package-Requires: ((emacs "26.1") (compat "29.1"))
;; Keywords: terminals processes
;; Homepage: https://codeberg.org/akib/emacs-eat

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Eat's name self-explanatory, it stands for "Emulate A Terminal".
;; Eat is a terminal emulator.  It can run most (if not all)
;; full-screen terminal programs, including Emacs.

;; It is pretty fast, more than three times faster than Term, despite
;; being implemented entirely in Emacs Lisp.  So fast that you can
;; comfortably run Emacs inside Eat, or even use your Emacs as a
;; terminal multiplexer.

;; It has many feature that other Emacs terminal emulator still don't
;; have.

;; It flickers less than other Emacs terminal emulator, so you get
;; more performance and a smooth experience.

;; To start Eat, run M-x eat.  Eat has two keybinding modes:

;;   * "emacs" mode: No special keybinding, except the following:

;;       * `C-c' `M-d': Switch to "char" keybinding mode.
;;       * `C-c' `C-k': Kill process.

;;   * "char" mode: All supported keys are bound to send the key to
;;     the terminal, except `C-M-m', `M-RET' or `C-c' `C-e', which are
;;     bound to switch to "emacs" keybinding mode.

;;; Code:

(require 'compat)
(require 'subr-x)
(require 'cl-lib)
(require 'ansi-color)
(require 'color)
(require 'shell)
(require 'term)
(require 'url)
(require 'tramp)
(require 'term/xterm)


;;;; User Options.

(defgroup eat nil
  "Emulate A Terminal."
  :group 'processes
  :group 'terminals
  :link '(url-link "https://codeberg.org/akib/emacs-eat"))

(defgroup eat-term nil
  "Eat terminal emulator."
  :group 'eat)

(defgroup eat-ui nil
  "Eat user interface."
  :group 'eat)

(defcustom eat-default-shell-function #'eat-default-shell
  "Function to call to get the default shell to run."
  :type 'function
  :group 'eat-ui)

(defcustom eat-shell (or explicit-shell-file-name
                         (getenv "ESHELL")
                         shell-file-name)
  "Default shell to run."
  :type 'string
  :group 'eat-ui)

(defcustom eat-tramp-shells '(("docker" . "/bin/sh"))
  "Alist specifying the shells to run in Tramp.

Each element of form (TRAMP-METHOD . SHELL), where SHELL corresponds
to the default shell for remote directories using TRAMP-METHOD."
  :type '(alist :key-type string :value-type string)
  :group 'eat-ui)

(defcustom eat-buffer-name "*eat*"
  "The basename used for Eat buffers.

This is the default name used when running Eat."
  :type 'string
  :group 'eat-ui)

(defcustom eat-kill-buffer-on-exit nil
  "Non-nil means automatically kill Eat buffer when process exits."
  :type 'boolean
  :group 'eat-ui)

(defcustom eat-show-title-on-mode-line t
  "Non-nil means show terminal title on mode line."
  :type 'boolean
  :group 'eat-ui)

(defcustom eat-term-scrollback-size 131072 ; 128 K
  "Size of scrollback area in characters.  nil means unlimited."
  :type '(choice natnum (const nil))
  :group 'eat-term
  :group 'eat-ui)

(defcustom eat-enable-kill-from-terminal t
  "Non-nil means allow terminal program to add text to `kill-ring'.

When non-nil, terminal program can send special escape sequence to add
some text to `kill-ring'."
  :type 'boolean
  :group 'eat-ui)

(defcustom eat-enable-yank-to-terminal nil
  "Non-nil means allow terminal program to get text from `kill-ring'.

When non-nil, terminal program can get killed text from `kill-ring'.
This is left disabled for security reasons."
  :type 'boolean
  :group 'eat-ui)

(defcustom eat-query-before-killing-running-terminal t
  "Whether to query before killing a running terminal."
  :type 'boolean
  :group 'eat-ui)

(defcustom eat-message-handler-alist nil
  "Alist of message handler name and its handler function.

The keys are the names of message handlers, and the values are their
respective handler functions.

Shells can send Eat messages, as defined in this user option.  If an
appropiate message handler is defined, it's called with the other
arguments, otherwise it's ignored."
  :type '(alist :key-type string
                :value-type function)
  :group 'eat-ui)


(defcustom eat-exec-hook nil
  "Hook run after `eat' executes a commamnd.

The hook is run with the process run in the terminal as the only
argument."
  :type 'hook
  :group 'eat-ui)

(defcustom eat-update-hook nil
  "Hook run after the terminal in a Eat buffer is updated."
  :type 'hook
  :group 'eat-ui)

(defcustom eat-exit-hook nil
  "Hook run after the command executed by `eat' exits.

The hook is run with the process that just exited as the only
argument."
  :type 'hook
  :group 'eat-ui)

(defconst eat--cursor-type-value-type
  '(choice
    (const :tag "Frame default" t)
    (const :tag "Filled box" box)
    (cons :tag "Box with specified size" (const box) integer)
    (const :tag "Hollow cursor" hollow)
    (const :tag "Vertical bar" bar)
    (cons :tag "Vertical bar with specified height" (const bar) integer)
    (const :tag "Horizontal bar" hbar)
    (cons :tag "Horizontal bar with specified width" (const hbar) integer)
    (const :tag "None" nil))
  "Custom type specification for Eat's cursor type variables.")

(defcustom eat-invisible-cursor-type nil
  "Type of cursor to use as invisible cursor in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-default-cursor-type (default-value 'cursor-type)
  "Cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-very-visible-cursor-type 'hollow
  "Very visible cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-vertical-bar-cursor-type 'bar
  "Vertical bar cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-very-visible-vertical-bar-cursor-type 'bar
  "Very visible vertical bar cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-horizontal-bar-cursor-type 'hbar
  "Horizontal bar cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-very-visible-horizontal-bar-cursor-type 'hbar
  "Very visible horizontal bar cursor to use in Eat buffer."
  :type eat--cursor-type-value-type
  :group 'eat-ui)

(defcustom eat-minimum-latency 0.008
  "Minimum display latency in seconds.

Lowering it too much may cause (or increase) flickering and decrease
performance due to too many redisplays.  Increasing it too much will
cause the terminal to feel less responsive.  Try to increase this
value if the terminal flickers."
  :type 'number
  :group 'eat-ui)

(defcustom eat-maximum-latency 0.033
  "Minimum display latency in seconds.

Increasing it too much may make the terminal feel less responsive in
case of huge burst of output.  Try to increase this value if the
terminal flickers.  Try to lower the value if the terminal feels less
responsive."
  :type 'number
  :group 'eat-ui)

(defcustom eat-term-name "xterm-256color"
  "Value for the `TERM' environment variable.

This value is used by terminal programs to identify the terminal."
  :type 'string
  :group 'eat-term)

(defcustom eat-term-inside-emacs (format "%s,eat" emacs-version)
  "Value for the `INSIDE_EMACS' environment variable."
  :type 'string
  :group 'eat-term)

(defcustom eat-input-chunk-size 1024
  "Maximum size of chunk of data send at once.

Long inputs send to Eat processes are broken up into chunks of this
size.

If your process is choking on big inputs, try lowering the value."
  :type 'integer
  :group 'eat-ui)

(defface eat-term-bold '((t :inherit bold))
  "Face used to render bold text."
  :group 'eat-term)

(defface eat-term-faint '((t :weight light))
  "Face used to render faint text."
  :group 'eat-term)

(defface eat-term-italic '((t :inherit italic))
  "Face used to render italic text."
  :group 'eat-term)

;; Define color faces.
(let ((face-counter 0))
  (let ((colors '("black" "red" "green" "yellow" "blue" "magenta"
                  "cyan" "white")))
    ;; Basic colors.
    (dolist (color colors)
      (let ((face (intern (format "eat-term-color-%i" face-counter))))
        (custom-declare-face
         face `((t :inherit
                   ,(intern (format (if (eval-when-compile
                                          (>= emacs-major-version 28))
                                        "ansi-color-%s"
                                      "term-color-%s")
                                    color))))
         (format "Face used to render %s color text." color)
         :group 'eat-term)
        (put (intern (format "eat-term-color-%s" color))
             'face-alias face))
      (cl-incf face-counter))
    ;; Bright colors.
    (dolist (color colors)
      (let ((face (intern (format "eat-term-color-%i" face-counter))))
        (custom-declare-face
         face `((t :inherit
                   ,(intern (format (if (eval-when-compile
                                          (>= emacs-major-version 28))
                                        "ansi-color-bright-%s"
                                      "term-color-%s")
                                    color))))
         (format "Face used to render bright %s color text." color)
         :group 'eat-term)
        (put (intern (format "eat-term-color-bright-%s" color))
             'face-alias face))
      (cl-incf face-counter)))
  ;; 256-colors.
  (while (< face-counter 256)
    (let ((color
           (if (>= face-counter 232)
               (format "#%06X"
                       (* #x010101
                          (+ 8 (* 10 (- face-counter 232)))))
             (let ((col (- face-counter 16))
                   (res 0)
                   (frac (* 6 6)))
               (while (<= 1 frac)
                 (setq res (* res #x000100))
                 (let ((color-num (mod (/ col frac) 6)))
                   (unless (zerop color-num)
                     (setq res (+ res #x37 (* #x28 color-num)))))
                 (setq frac (/ frac 6)))
               (format "#%06X" res)))))
      (custom-declare-face
       (intern (format "eat-term-color-%i" face-counter))
       `((t :foreground ,color :background ,color))
       (format "Face used to render text with %i%s color of 256 color\
 palette."
               face-counter
               (or (and (not (<= 11 (% face-counter 100) 13))
                        (nth (% face-counter 10)
                             '(nil "st" "nd" "rd")))
                   "th"))
       :group 'eat-term))
    (cl-incf face-counter)))

(defface eat-term-font-0 '((t))
  "Default font."
  :group 'eat-term)

(put 'eat-term-font-default 'face-alias 'eat-term-font-0)

;; Font faces, 1 to 9 (inclusive).
(cl-loop for counter from 1 to 9
         do (custom-declare-face
             (intern (format "eat-term-font-%i" counter)) '((t))
             (format "Alternative font %i." counter)
             :group 'eat-term))

(defsubst eat--t-color-face (index)
  "Return face symbol for terminal color INDEX."
  (intern (format "eat-term-color-%i" index)))

(defsubst eat--t-font-face (index)
  "Return face symbol for terminal font INDEX."
  (intern (format "eat-term-font-%i" index)))


;;;; Utility Functions.

(defun eat--t-goto-bol (&optional n)
  "Go to the beginning of current line.

With optional argument N, go to the beginning of Nth next line if N is
positive, otherwise go to the beginning of -Nth previous line.  If the
specified position is before `point-min' or after `point-max', go to
that point.

Return the number of lines moved.

Treat LINE FEED (?\\n) as the line delimiter."
  ;; TODO: Comment.
  (setq n (or n 0))
  (cond ((> n 0)
         (let ((moved 0))
           (while (and (< (point) (point-max))
                       (< moved n))
             (and (search-forward "\n" nil 'move)
                  (cl-incf moved)))
           moved))
        ((<= n 0)
         (let ((moved 1))
           (while (and (or (= moved 1)
                           (< (point-min) (point)))
                       (< n moved))
             (cl-decf moved)
             (and (search-backward "\n" nil 'move)
                  (= moved n)
                  (goto-char (match-end 0))))
           moved))))

(defun eat--t-goto-eol (&optional n)
  "Go to the end of current line.

With optional argument N, go to the end of Nth next line if N is
positive, otherwise go to the end of -Nth previous line.  If the
specified position is before `point-min' or after `point-max', go to
that point.

Return the number of lines moved.

Treat LINE FEED (?\\n) as the line delimiter."
  ;; TODO: Comment.
  (setq n (or n 0))
  (cond ((>= n 0)
         (let ((moved -1))
           (while (and (or (= moved -1)
                           (< (point) (point-max)))
                       (< moved n))
             (cl-incf moved)
             (and (search-forward "\n" nil 'move)
                  (= moved n)
                  (goto-char (match-beginning 0))))
           moved))
        ((< n 0)
         (let ((moved 0))
           (while (and (< (point-min) (point))
                       (< n moved))
             (and (search-backward "\n" nil 'move)
                  (cl-decf moved)))
           moved))))

(defun eat--t-bol (&optional n)
  "Return the beginning of current line.

With optional argument N, return a cons cell whose car is the
beginning of Nth next line and cdr is N, if N is positive, otherwise
return a cons cell whose car is the beginning of -Nth previous line
and cdr is N.  If the specified position is before `point-min' or
after `point-max', return a cons cell whose car is that point and cdr
is number of lines that point is away from current line.

Treat LINE FEED (?\\n) as the line delimiter."
  ;; Move to the beginning of line, record the point, and return that
  ;; point and the distance of that point from current line in lines.
  (save-excursion
    ;; `let' is neccessary, we need to evaluate (point) after going to
    ;; `(eat--t-goto-bol N)'.
    (let ((moved (eat--t-goto-bol n)))
      (cons (point) moved))))

(defun eat--t-eol (&optional n)
  "Return the end of current line.

With optional argument N, return a cons cell whose car the end of Nth
next line and cdr is N, if N is positive, otherwise return a cons cell
whose car is the end of -Nth previous line and cdr in N.  If the
specified position is before `point-min' or after `point-max', return
a cons cell whose car is that point and cdr is number of lines that
point is away from current line.

Treat LINE FEED (?\\n) as the line delimiter."
  ;; Move to the beginning of line, record the point, and return that
  ;; point and the distance of that point from current line in lines.
  (save-excursion
    ;; `let' is neccessary, we need to evaluate (point) after going to
    ;; (eat--t-goto-eol N).
    (let ((moved (eat--t-goto-eol n)))
      (cons (point) moved))))

(defun eat--t-col-motion (n)
  "Move to Nth next column.

Go to Nth next column if N is positive, otherwise go to -Nth previous
column.  If the specified position is before `point-min' or after
`point-max', go to that point.

Return the number of columns moved.

Assume all characters occupy a single column."
  ;; Record the current position.
  (let ((start-pos (point)))
    ;; Move to the new position.
    (cond ((> n 0)
           (let ((eol (car (eat--t-eol)))
                 (pos (+ (point) n)))
             (goto-char (min pos eol))))
          ((< n 0)
           (let ((bol (car (eat--t-bol)))
                 (pos (+ (point) n)))
             (goto-char (max pos bol)))))
    ;; Return the distance from the previous position.
    (- (point) start-pos)))

(defun eat--t-current-col ()
  "Return the current column.

Assume all characters occupy a single column."
  ;; We assume that that all characters occupy a single column, so a
  ;; subtraction should work.  For multi-column characters, we add
  ;; extra invisible spaces before the character to make it occupy as
  ;; many character is its width.
  (- (point) (car (eat--t-bol))))

(defun eat--t-goto-col (n)
  "Go to column N.

Return the current column after moving point.

Assume all characters occupy a single column."
  ;; Move to column 0.
  (eat--t-goto-bol)
  ;; Now the target column is N characters away.
  (eat--t-col-motion n))

(defun eat--t-repeated-insert (c n &optional face)
  "Insert character C, N times, using face FACE, if given."
  (insert (if face
              (let ((str (make-string n c)))
                (put-text-property 0 n 'face face str)
                (put-text-property 0 n 'font-lock-face face str)
                str)
            ;; Avoid the `let'.
            (make-string n c))))

(defun eat--t-join-long-line (&optional limit)
  "Join long line once, but don't try to go beyond LIMIT.

For example: \"*foo\\nbar\\nbaz\" is converted to \"foo*bar\\nbaz\",
where `*' indicates point."
  ;; Are we already at the end a part of a long line?
  (unless (get-text-property (point) 'eat--t-wrap-line)
    ;; Find the next end of a part of a long line.
    (goto-char (or (next-single-property-change
                    (point) 'eat--t-wrap-line nil limit)
                   limit (point-max))))
  ;; Remove the newline.
  (when (< (point) (or limit (point-max)))
    (1value (cl-assert (1value (= (1value (char-after)) ?\n))))
    (delete-char 1)))

(defun eat--t-break-long-line (threshold)
  "Break a line longer than THRESHOLD once.

For example: when THRESHOLD is 3, \"*foobarbaz\" is converted to
\"foo\\n*barbaz\", where `*' indicates point."
  (let ((loop t))
    ;; Find a too long line.
    (while (and loop (< (point) (point-max)))
      ;; Go to the threshold column.
      (eat--t-goto-col threshold)
      ;; Are we at the end of line?
      (if (eq (char-after) ?\n)
          ;; We are already at the end of line, so move to the next
          ;; line and start from the beginning.
          (forward-char)
        ;; The next character is not a newline, so we must be at a
        ;; long line, or we are the end of the accessible part of the
        ;; buffer.  Whatever the case, we break the loop, and if it is
        ;; a long line, we break the line.
        (setq loop nil)
        (unless (= (point) (point-max))
          (insert-before-markers
           #("\n" 0 1 (eat--t-wrap-line t))))))))


;;;; Emulator.

(cl-defstruct (eat--t-cur
               (:constructor eat--t-make-cur)
               (:copier eat--t-copy-cur))
  "Structure describing cursor position."
  (position nil :documentation "Position of cursor.")
  (y 1 :documentation "Y coordinate of cursor.")
  (x 1 :documentation "X coordinate of cursor."))

(cl-defstruct (eat--t-disp
               (:constructor eat--t-make-disp)
               (:copier eat--t-copy-disp))
  "Structure describing the display."
  (begin nil :documentation "Beginning of visible display.")
  (width 80 :documentation "Width of display.")
  (height 24 :documentation "Height of display.")
  (cursor nil :documentation "Cursor.")
  (saved-cursor
   (1value (eat--t-make-cur))
   :documentation "Saved cursor.")
  (old-begin
   nil
   :documentation
   "Beginning of visible display during last Eat redisplay."))

(cl-defstruct (eat--t-face
               (:constructor eat--t-make-face)
               (:copier eat--t-copy-face))
  "Structure describing the display attributes to use."
  (face nil :documentation "Face to use.")
  (fg nil :documentation "Foreground color.")
  (bg nil :documentation "Background color.")
  (intensity nil :documentation "Intensity face, or nil.")
  (italic nil :documentation "Non-nil means use italic face.")
  (underline nil :documentation "Non-nil means underline text.")
  (underline-color nil :documentation "Underline color.")
  (crossed nil :documentation "Non-nil means strike-through text.")
  (conceal nil :documentation "Non-nil means invisible text.")
  (inverse nil :documentation "Non-nil means inverse colors.")
  (font 'eat-term-font-0 :documentation "Current font face."))

(cl-defstruct (eat--t-term
               (:constructor eat--t-make-term)
               (:copier eat--t-copy-term))
  "Structure describing a terminal."
  (buffer nil :documentation "The buffer of terminal.")
  (begin nil :documentation "Beginning of terminal.")
  (end nil :documentation "End of terminal area.")
  (title "" :documentation "The title of the terminal.")
  (parser-state nil :documentation "State of parser.")
  (scroll-begin 1 :documentation "First line of scroll region.")
  (scroll-end 24 :documentation "Last line of scroll region.")
  (display nil :documentation "The display.")
  (main-display nil :documentation "Main display.

Nil when not in alternative display mode.")
  (face
   (1value (eat--t-make-face))
   :documentation "Display attributes.")
  (auto-margin t :documentation "State of auto margin mode.")
  (ins-mode nil :documentation "State of insert mode.")
  (charset
   (copy-tree '(g0 . ((g0 . us-ascii)
                      (g1 . us-ascii)
                      (g2 . us-ascii)
                      (g3 . us-ascii))))
   :documentation "Current character set.")
  (cur-state :block :documentation "Current state of cursor.")
  (cur-visible-p t :documentation "Is the cursor visible?")
  (saved-face
   (1value (eat--t-make-face))
   :documentation "Saved SGR attributes.")
  (bracketed-yank nil :documentation "State of bracketed yank mode.")
  (keypad-mode nil :documentation "State of keypad mode.")
  (focus-event-mode nil :documentation "Whether to send focus event.")
  (cut-buffers
   (1value (make-vector 8 nil))
   :documentation "Cut buffers."))

(defvar eat--t-term nil
  "The current terminal.

Don't `set' it, bind it to a value with `let'.")


(defun eat--t-reset ()
  "Reset terminal."
  (let ((disp (eat--t-term-display eat--t-term)))
    ;; Reset most of the things to their respective default values.
    (setf (eat--t-term-parser-state eat--t-term) nil)
    (setf (eat--t-disp-begin disp) (point-min-marker))
    (setf (eat--t-disp-old-begin disp) (point-min-marker))
    (setf (eat--t-disp-cursor disp)
          (eat--t-make-cur :position (point-min-marker)))
    (setf (eat--t-disp-saved-cursor disp) (eat--t-make-cur))
    (setf (eat--t-term-scroll-begin eat--t-term) 1)
    (setf (eat--t-term-scroll-end eat--t-term)
          (eat--t-disp-height disp))
    (setf (eat--t-term-main-display eat--t-term) nil)
    (setf (eat--t-term-face eat--t-term) (eat--t-make-face))
    (setf (eat--t-term-auto-margin eat--t-term) t)
    (setf (eat--t-term-ins-mode eat--t-term) nil)
    (setf (eat--t-term-charset eat--t-term)
          '(g0 (g0 . us-ascii)
               (g1 . dec-line-drawing)
               (g2 . dec-line-drawing)
               (g3 . dec-line-drawing)))
    (setf (eat--t-term-saved-face eat--t-term) (eat--t-make-face))
    (setf (eat--t-term-bracketed-yank eat--t-term) nil)
    (setf (eat--t-term-cur-state eat--t-term) :block)
    (setf (eat--t-term-cur-visible-p eat--t-term) t)
    (setf (eat--t-term-title eat--t-term) "")
    (setf (eat--t-term-keypad-mode eat--t-term) nil)
    (setf (eat--t-term-focus-event-mode eat--t-term) nil)
    ;; Clear everything.
    (delete-region (point-min) (point-max))
    ;; Inform the UI about our new state.
    (eat--set-cursor eat--t-term :block)))

(defun eat--t-cur-right (&optional n)
  "Move cursor N columns right.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is less than 1, set N to 1.  If N is more than the number
    ;; of available columns on the right side, set N to the maximum
    ;; possible value.
    (setq n (min (- (eat--t-disp-width disp) (eat--t-cur-x cursor))
                 (max (or n 1) 1)))
    ;; N is non-zero in most cases, except at the edge of display.
    (unless (zerop n)
      ;; Move to the Nth next column, use spaces to reach that column
      ;; if needed.
      (eat--t-repeated-insert ?\s (- n (eat--t-col-motion n)))
      (cl-incf (eat--t-cur-x cursor) n))))

(defun eat--t-cur-left (&optional n)
  "Move cursor N columns left.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is less than 1, set N to 1.  If N is more than the number
    ;; of available columns on the left side, set N to the maximum
    ;; possible value.
    (setq n (min (1- (eat--t-cur-x cursor)) (max (or n 1) 1)))
    ;; N is non-zero in most cases, except at the edge of display.
    (unless (zerop n)
      ;; Move to the Nth previous column.
      (cl-assert (1value (>= (eat--t-current-col) n)))
      (backward-char n)
      (cl-decf (eat--t-cur-x cursor) n))))

(defun eat--t-cur-horizontal-abs (&optional n)
  "Move cursor to Nth column on current line.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is out of range, bring it within the bounds of range.
    (setq n (min (max (or n 1) 1) (eat--t-disp-width disp)))
    ;; Depending on the current position of cursor, move right or
    ;; left.
    (cond ((< (eat--t-cur-x cursor) n)
           (eat--t-cur-right (- n (eat--t-cur-x cursor))))
          ((< n (eat--t-cur-x cursor))
           (eat--t-cur-left (- (eat--t-cur-x cursor) n))))))

(defun eat--t-beg-of-next-line (n)
  "Move to beginning of Nth next line."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is less than 1, set N to 1.  If N is more than the number
    ;; of available lines below, set N to the maximum possible value.
    (setq n (min (- (eat--t-disp-height disp) (eat--t-cur-y cursor))
                 (max (or n 1) 1)))
    ;; N is non-zero in most cases, except at the edge of display.
    ;; Whatever the case, we move to the beginning of line.
    (if (zerop n)
        (1value (eat--t-goto-bol))
      ;; Move to the Nth next line, use newlines to reach that line if
      ;; needed.
      (eat--t-repeated-insert ?\n (- n (eat--t-goto-bol n)))
      (cl-incf (eat--t-cur-y cursor) n))
    (1value (setf (eat--t-cur-x cursor) 1))))

(defun eat--t-beg-of-prev-line (n)
  "Move to beginning of Nth previous line."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is less than 1, set N to 1.  If N is more than the number
    ;; of available lines above, set N to the maximum possible value.
    (setq n (min (1- (eat--t-cur-y cursor)) (max (or n 1) 1)))
    ;; Move to the beginning Nth previous line.  Even if there are no
    ;; line above, move to the beginning of the line.
    (eat--t-goto-bol (- n))
    (cl-decf (eat--t-cur-y cursor) n)
    (1value (setf (eat--t-cur-x cursor) 1))))

(defun eat--t-cur-down (&optional n)
  "Move cursor N lines down.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let ((x (eat--t-cur-x (eat--t-disp-cursor
                          (eat--t-term-display eat--t-term)))))
    ;; Move to the beginning of target line.
    (eat--t-beg-of-next-line n)
    ;; If the cursor wasn't at column one, move the cursor to the
    ;; cursor to that column.
    (unless (= x 1)
      (eat--t-cur-right (1- x)))))

(defun eat--t-cur-up (&optional n)
  "Move cursor N lines up.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let ((x (eat--t-cur-x (eat--t-disp-cursor
                          (eat--t-term-display eat--t-term)))))
    ;; Move to the beginning of target line.
    (eat--t-beg-of-prev-line n)
    ;; If the cursor wasn't at column one, move the cursor to the
    ;; cursor to that column.
    (unless (= x 1)
      (eat--t-cur-right (1- x)))))

(defun eat--t-cur-vertical-abs (&optional n)
  "Move cursor to Nth line on display.

N default to 1.  If N is out of range, place cursor at the edge of
display."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; If N is out of range, bring it within the bounds of range.
    (setq n (min (max (or n 1) 1) (eat--t-disp-height disp)))
    ;; Depending on the current position of cursor, move downward or
    ;; upward.
    (cond ((< (eat--t-cur-y cursor) n)
           (eat--t-cur-down (- n (eat--t-cur-y cursor))))
          ((< n (eat--t-cur-y cursor))
           (eat--t-cur-up (- (eat--t-cur-y cursor) n))))))

(defun eat--t-scroll-up (&optional n as-side-effect)
  "Scroll up N lines, preserving cursor position.

N default to 1.  By default, don't change current line and current
column, but if AS-SIDE-EFFECT is given and non-nil, assume that
scrolling is triggered as a side effect of some other control function
and don't move the point relative to the text and change current line
accordingly."
  (let ((disp (eat--t-term-display eat--t-term))
        (scroll-begin (eat--t-term-scroll-begin eat--t-term))
        (scroll-end (eat--t-term-scroll-end eat--t-term)))
    ;; N shouldn't be more more than the number of lines in scroll
    ;; region.
    (setq n (min (max (or n 1) 0) (1+ (- scroll-end scroll-begin))))
    ;; Make sure that N is positive.
    (unless (zerop n)
      ;; Try to not point relative to the text.
      (save-excursion
        (goto-char (eat--t-disp-begin disp))
        ;; Move to the beginning of scroll region.
        (eat--t-goto-bol (1- scroll-begin))
        ;; If the first line on display isn't in scroll region or
        ;; if this is the alternative display, delete text.
        (if (or (eat--t-term-main-display eat--t-term)
                (> scroll-begin 1))
            (delete-region (point) (car (eat--t-bol n)))
          ;; Otherwise, send the text to the scrollback area by
          ;; advancing the display beginning marker.
          (eat--t-goto-bol n)
          ;; Make sure we're at the beginning of a line, because we
          ;; might be at `point-max'.
          (unless (or (= (point) (point-min))
                      (= (char-before) ?\n))
            (insert ?\n))
          (set-marker (eat--t-disp-begin disp) (point)))
        ;; Is the last line on display in scroll region?
        (when (< scroll-end (eat--t-disp-width disp))
          ;; No, it isn't.
          ;; Go to the end of scroll region (before deleting or moving
          ;; texts).
          (eat--t-goto-bol (- (1+ (- scroll-end scroll-begin)) n))
          ;; If there is anything after the scroll region, insert
          ;; newlines to keep that text unmoved.
          (when (< (point) (point-max))
            (eat--t-repeated-insert ?\n n))))
      ;; Recalculate point if needed.
      (let* ((cursor (eat--t-disp-cursor disp))
             (recalc-point
              (<= scroll-begin (eat--t-cur-y cursor) scroll-end)))
        ;; If recalc-point is non-nil, and AS-SIDE-EFFECT is non-nil,
        ;; update cursor position so that it is unmoved relative to
        ;; surrounding text and reconsider point recalculation.
        (when (and recalc-point as-side-effect)
          (setq recalc-point (< (- (eat--t-cur-y cursor) n)
                                scroll-begin))
          (setf (eat--t-cur-y cursor)
                (max (- (eat--t-cur-y cursor) n) scroll-begin)))
        (when recalc-point
          ;; Recalculate point.
          (let ((y (eat--t-cur-y cursor))
                (x (eat--t-cur-x cursor)))
            (eat--t-goto 1 1)
            (eat--t-goto y x)))))))

(defun eat--t-scroll-down (&optional n)
  "Scroll down N lines, preserving cursor position.

N defaults to 1."
  (let ((disp (eat--t-term-display eat--t-term))
        (scroll-begin (eat--t-term-scroll-begin eat--t-term))
        (scroll-end (eat--t-term-scroll-end eat--t-term)))
    ;; N shouldn't be more more than the number of lines in scroll
    ;; region.
    (setq n (min (max (or n 1) 0) (1+ (- scroll-end scroll-begin))))
    ;; Make sure that N is positive.
    (unless (zerop n)
      ;; Move to the beginning of scroll region.
      (goto-char (eat--t-disp-begin disp))
      (eat--t-goto-bol (1- scroll-begin))
      ;; Insert newlines to push text downwards.
      (eat--t-repeated-insert ?\n n)
      ;; Go to the end scroll region (after inserting newlines).
      (eat--t-goto-eol (- (1+ (- scroll-end scroll-begin)) (1+ n)))
      ;; Delete the text that was pushed out of scroll region.
      (when (< (point) (point-max))
        (delete-region (point) (car (eat--t-eol n))))
      ;; The cursor mustn't move, so we have to recalculate point.
      (let* ((cursor (eat--t-disp-cursor disp))
             (y (eat--t-cur-y cursor))
             (x (eat--t-cur-x cursor)))
        (eat--t-goto 1 1)
        (eat--t-goto y x)))))

(defun eat--t-goto (&optional y x)
  "Go to Xth column of Yth line of display.

Y and X default to 1.  Y and X are one-based.  If Y and/or X are out
of range, place cursor at the edge of display."
  ;; Important special case: if Y and X are both one, move to the
  ;; display beginning.
  (if (and (or (not y) (eql y 1))
           (or (not x) (eql x 1)))
      (let* ((disp (eat--t-term-display eat--t-term))
             (cursor (eat--t-disp-cursor disp)))
        (goto-char (eat--t-disp-begin disp))
        (1value (setf (eat--t-cur-y cursor) 1
                      (eat--t-cur-x cursor) 1)))
    ;; Move to column one, go to Yth line and move to Xth column.
    ;; REVIEW: We move relative to cursor position, which faster for
    ;; positions near the point (usually the case), but slower for
    ;; positions far away from the point.  There are only two cursor
    ;; positions whose exact position is known beforehand, the cursor
    ;; (whose position is (point)) and (1, 1) (the display beginning).
    ;; There are almost always some points which are at more distance
    ;; from current position than from the display beginning (the only
    ;; exception is when the cursor is at the display beginning).  So
    ;; first moving to the display beginning and then moving to those
    ;; point will be faster than moving from cursor (except a tiny
    ;; (perhaps negligible) overhead of `goto-char').  What we don't
    ;; have is a formula the calculate the distance between two
    ;; positions.
    (eat--t-cur-horizontal-abs 1)
    (eat--t-cur-vertical-abs y)
    (eat--t-cur-horizontal-abs x)))

(defun eat--t-enable-auto-margin ()
  "Enable automatic margin."
  ;; Set the automatic margin flag to t, the rest of code will take
  ;; care of the effects.
  (1value (setf (eat--t-term-auto-margin eat--t-term) t)))

(defun eat--t-disable-auto-margin ()
  "Disable automatic margin."
  ;; Set the automatic margin flag to nil, the rest of code will take
  ;; care of the effects.
  (1value (setf (eat--t-term-auto-margin eat--t-term) nil)))

(defun eat--t-set-charset (slot charset)
  "SLOT's character set to CHARSET."
  (setf (alist-get slot (cdr (eat--t-term-charset eat--t-term)))
        charset))

(defun eat--t-change-charset (charset)
  "Change character set to CHARSET.

CHARSET should be one of `g0', `g1', `g2' and `g3'."
  (cl-assert (memq charset '(g0 g1 g2 g3)))
  (setf (car (eat--t-term-charset eat--t-term)) charset))

(defun eat--t-move-before-to-safe ()
  "Move to a safe position before point.  Return how much moved.

If the current position is safe, do nothing and return 0.

Safe position is the position that's not on a multi-column wide
character or its the internal invisible spaces."
  (if (and (not (bobp))
           ;; Is the current position unsafe?
           (get-text-property (1- (point)) 'eat--t-invisible-space))
      (let ((start-pos (point)))
        ;; Move to the safe position.
        (goto-char (or (previous-single-property-change
                        (point) 'eat--t-invisible-space)
                       (point-min)))
        (cl-assert
         (1value (or (bobp)
                     (null (get-text-property
                            (1- (point)) 'eat--t-invisible-space)))))
        (- start-pos (point)))
    0))

(defun eat--t-make-pos-safe ()
  "If the position isn't safe, make it safe by replacing with spaces."
  (let ((moved (eat--t-move-before-to-safe)))
    (unless (zerop moved)
      (let ((width (get-text-property
                    (point) 'eat--t-char-width)))
        (cl-assert width)
        (delete-region (point) (+ (point) width))
        (eat--t-repeated-insert
         ?\s width (eat--t-face-face
                    (eat--t-term-face eat--t-term)))
        (backward-char (- width moved))))))

(defun eat--t-fix-partial-multi-col-char (&optional preserve-face)
  "Replace any partial multi-column character with spaces.

If PRESERVE-FACE is non-nil, preserve original face."
  (let ((face (if preserve-face
                  (get-char-property (point) 'face)
                (eat--t-face-face
                 (eat--t-term-face eat--t-term)))))
    (if (get-text-property (point) 'eat--t-invisible-space)
        (let ((start-pos (point))
              (count nil))
          (goto-char (or (next-single-property-change
                          (point) 'eat--t-invisible-space)
                         (point-max)))
          (setq count (- (1+ (point)) start-pos))
          ;; Make sure we really overwrote the character
          ;; partially.
          (when (< count (get-text-property
                          (point) 'eat--t-char-width))
            (delete-region start-pos (1+ (point)))
            (eat--t-repeated-insert ?\s count face))
          (goto-char start-pos))
      ;; Detect the case where we have deleted all the invisible
      ;; spaces before, but not the multi-column character itself.
      (when-let* (((not (eobp)))
                  (w (get-text-property (point) 'eat--t-char-width))
                  ((> w 1)))
        ;; `delete-char' also works, but it does more checks, so
        ;; hopefully this will be faster.
        (delete-region (point) (1+ (point)))
        (insert (propertize " " 'face face 'font-lock-face face))
        (backward-char)))))

(defconst eat--t-dec-line-drawing-chars
  (eval-and-compile
    (let ((alist '((?+ . ?→)
                   (?, . ?←)
                   (?- . ?↑)
                   (?. . ?↓)
                   (?0 . ?█)
                   (?\` . ?�)
                   (?a . ?▒)
                   (?b . ?␉)
                   (?c . ?␌)
                   (?d . ?␍)
                   (?e . ?␊)
                   (?f . ?°)
                   (?g . ?±)
                   (?h . ?░)
                   (?i . ?#)
                   (?j . ?┘)
                   (?k . ?┐)
                   (?l . ?┌)
                   (?m . ?└)
                   (?n . ?┼)
                   (?o . ?⎺)
                   (?p . ?⎻)
                   (?q . ?─)
                   (?r . ?⎼)
                   (?s . ?⎽)
                   (?t . ?├)
                   (?u . ?┤)
                   (?v . ?┴)
                   (?w . ?┬)
                   (?x . ?│)
                   (?y . ?≤)
                   (?z . ?≥)
                   (?{ . ?π)
                   (?| . ?≠)
                   (?} . ?£)
                   (?~ . ?•)))
          (table (make-hash-table :purecopy t)))
      (dolist (pair alist)
        (puthash (car pair) (cdr pair) table))
      table))
  "Hash table for DEC Line Drawing charset.

The key is the output character from client, and value of the
character to actually show.")

(defun eat--t-write (str &optional beg end)
  "Write STR from BEG to END on display."
  (setq beg (or beg 0))
  (setq end (or end (length str)))
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (scroll-end (eat--t-term-scroll-end eat--t-term))
         (charset
          (alist-get (car (eat--t-term-charset eat--t-term))
                     (cdr (eat--t-term-charset eat--t-term))))
         (face (eat--t-face-face (eat--t-term-face eat--t-term)))
         ;; Alist of indices and width of multi-column characters.
         (multi-col-char-indices nil)
         (inserted-till beg))
    (cl-assert charset)
    ;; Find all the multi-column wide characters in ST; hopefully it
    ;; won't slow down showing plain ASCII.
    (setq multi-col-char-indices
          (cl-loop for i from beg to (1- end)
                   when (/= (char-width (aref str i)) 1)
                   collect (cons i (char-width (aref str i)))))
    ;; If the position isn't safe, replace the multi-column
    ;; character with spaces to make it safe.
    (eat--t-make-pos-safe)
    ;; TODO: Comment.
    ;; REVIEW: This probably needs to be updated.

    ;; start, inserted-till, end are the indices of the string, not column width
    (while (< inserted-till end)
      ;; Insert STR, and record the width of STR inserted
      ;; successfully.
      (let ((ins-count
             ;; max, written, wrote and the return value (ins-count) are in column width, not string length
             (named-let write
                 ;; max: max remaining number of columns available for writing in this line
                 ((max (min (- (eat--t-disp-width disp)
                                     (1- (eat--t-cur-x cursor)))
                                  (+ (- end inserted-till)
                                     (cl-loop
                                      for p in multi-col-char-indices
                                      sum (1- (cdr p))))))
                  (written 0))
               (let* ((next-multi-col (car multi-col-char-indices))
                      ;; e: the end index of the string to write, before next multi-col-char
                      (e-without-considering-multi-col (+ max inserted-till))
                      (e (if next-multi-col
                             (min (car next-multi-col) e-without-considering-multi-col)
                           e-without-considering-multi-col))
                      (wrote (- e inserted-till)))
                 (cl-assert (>= wrote 0))
                 (let ((s (substring str inserted-till e)))
                   ;; Convert STR to Unicode according to the
                   ;; current character set.
                   (pcase-exhaustive charset
                     ;; For `us-ascii', the default, no conversion
                     ;; is necessary.
                     ('us-ascii)
                     ;; `dec-line-drawing' contains various
                     ;; characters useful for drawing line diagram,
                     ;; so it is a must.  This is also possible
                     ;; with `us-ascii', thanks to Unicode, but the
                     ;; character set `dec-line-drawing' is usually
                     ;; less expensive in terms of bytes needed to
                     ;; transfer than `us-ascii'.
                     ('dec-line-drawing
                      ;; remap the string according to dec-line-drawing charset.
                      (setq s (mapconcat
                               (lambda (c)
                                 (string (or (gethash c eat--t-dec-line-drawing-chars) c)))
                               s))))
                   ;; Add face.
                   (put-text-property 0 (length s) 'face face s)
                   (put-text-property
                    0 (length s) 'font-lock-face face s)
                   (insert s))
                 (setq inserted-till e)
                 (if (or (null next-multi-col)
                         (< (- max wrote) (cdr next-multi-col)))
                     ;; Either everything is done, or we reached
                     ;; the limit.
                     (+ written max)
                   ;; There are many characters which are too
                   ;; narrow for `char-width' to return 1.  XTerm,
                   ;; Kitty and St seems to ignore them, so we too.
                   (if (zerop (cdr next-multi-col))
                       (cl-incf inserted-till)
                     (insert
                      ;; Make sure the multi-column character
                      ;; occupies the same number of characters as
                      ;; its width.
                      (propertize
                       (make-string (1- (cdr next-multi-col)) ?\s)
                       'invisible t 'face face 'font-lock-face face
                       'eat--t-invisible-space t
                       'eat--t-char-width (cdr next-multi-col))
                      ;; Now insert the multi-column character.
                      (propertize
                       (substring str inserted-till
                                  (cl-incf inserted-till))
                       'face face 'font-lock-face face
                       'eat--t-char-width (cdr next-multi-col))))
                   (setf multi-col-char-indices
                         (cdr multi-col-char-indices))
                   (write (- max wrote (cdr next-multi-col))
                          (+ written wrote
                             (cdr next-multi-col))))))))
        (cl-incf (eat--t-cur-x cursor) ins-count)
        (if (eat--t-term-ins-mode eat--t-term)
            (delete-region
             (save-excursion
               (eat--t-col-motion (- (eat--t-disp-width disp)
                                     (1- (eat--t-cur-x cursor))))
               ;; Make sure the point is safe.
               (eat--t-move-before-to-safe)
               (point))
             (car (eat--t-eol)))
          (delete-region (point) (min (+ ins-count (point))
                                      (car (eat--t-eol))))
          ;; Replace any partially-overwritten character with
          ;; spaces.
          (eat--t-fix-partial-multi-col-char))
        (when (> (eat--t-cur-x cursor) (eat--t-disp-width disp))
          (if (not (eat--t-term-auto-margin eat--t-term))
              (eat--t-cur-left 1)
            (when (< inserted-till end)
              (when (= (eat--t-cur-y cursor) scroll-end)
                (eat--t-scroll-up 1 'as-side-effect))
              (if (= (eat--t-cur-y cursor) scroll-end)
                  (eat--t-carriage-return)
                (if (= (point) (point-max))
                    (insert #("\n" 0 1 (eat--t-wrap-line t)))
                  (put-text-property (point) (1+ (point))
                                     'eat--t-wrap-line t)
                  (forward-char))
                (1value (setf (eat--t-cur-x cursor) 1))
                (cl-incf (eat--t-cur-y cursor))))))))))

(defun eat--t-horizontal-tab (&optional n)
  "Go to the Nth next tabulation stop.

N default to 1."
  ;; N must be positive.
  (setq n (max (or n 1) 1))
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; Do some math calculate the distance of the Nth next tabulation
    ;; stop from cursor, and go there.
    (eat--t-cur-right (+ (- 8 (mod (1- (eat--t-cur-x cursor)) 8))
                         (* (1- n) 8)))))

(defun eat--t-horizontal-backtab (&optional n)
  "Go to the Nth previous tabulation stop.

N default to 1."
  ;; N must be positive.
  (setq n (max (or n 1) 1))
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; Do some math calculate the distance of the Nth next tabulation
    ;; stop from cursor, and go there.
    (eat--t-cur-left (+ (1+ (mod (- (eat--t-cur-x cursor) 2) 8))
                        (* (1- n) 8)))))

(defun eat--t-index ()
  "Go to the next line preserving column, scrolling if necessary."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (scroll-end (eat--t-term-scroll-end eat--t-term))
         ;; Are we inside scroll region?
         (in-scroll-region (<= (eat--t-cur-y cursor) scroll-end)))
    ;; If this is the last line (of the scroll region or the display),
    ;; scroll up, otherwise move cursor downward.
    (if (= (if in-scroll-region scroll-end (eat--t-disp-height disp))
           (eat--t-cur-y cursor))
        (eat--t-scroll-up 1)
      (eat--t-cur-down 1))))

(defun eat--t-carriage-return ()
  "Go to column one."
  (eat--t-cur-horizontal-abs 1))

(defun eat--t-line-feed ()
  "Go to the first column of the next line, scrolling if necessary."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (scroll-end (eat--t-term-scroll-end eat--t-term))
         ;; Are we inside scroll region?
         (in-scroll-region (<= (eat--t-cur-y cursor) scroll-end)))
    ;; If we are at the very end of the terminal, we might have some
    ;; optimizations.
    (if (= (point) (point-max))
        ;; If the cursor is above the last line of the scroll region
        ;; (or the display, if we are outside the scroll region), we
        ;; can simply insert a newline and update the cursor position.
        (if (/= (if in-scroll-region
                    scroll-end
                  (eat--t-disp-height disp))
                (eat--t-cur-y cursor))
            (progn
              (insert ?\n)
              (setf (eat--t-cur-x cursor) 1)
              (cl-incf (eat--t-cur-y cursor)))
          ;; This is the last line.  We need to scroll up.
          (eat--t-scroll-up 1 'as-side-effect)
          ;; If we're still at the last line (only happens when the
          ;; display has only a single line), go to column one of it.
          (if (= (if in-scroll-region
                     scroll-end
                   (eat--t-disp-height disp))
                 (eat--t-cur-y cursor))
              (eat--t-carriage-return)
            ;; If we are somehow moved from the end of terminal,
            ;; `eat--t-beg-of-next-line' is the best option.
            (if (/= (point) (point-max))
                (eat--t-beg-of-next-line 1)
              ;; We are still at the end!  We can can simply insert a
              ;; newline and update the cursor position.
              (insert ?\n)
              (setf (eat--t-cur-x cursor) 1)
              (cl-incf (eat--t-cur-y cursor)))))
      ;; We are not at the end of terminal.  But we still have a last
      ;; chance.  `eat--t-beg-of-next-line' is usually faster than
      ;; `eat--t-carriage-return' followed by `eat--t-index', so if
      ;; there is at least a single line (in the scroll region, if the
      ;; cursor in the scroll region, otherwise in the display)
      ;; underneath the cursor, we can use `eat--t-beg-of-next-line'.
      (if (/= (if in-scroll-region
                  scroll-end
                (eat--t-disp-height disp))
              (eat--t-cur-y cursor))
          (eat--t-beg-of-next-line 1)
        ;; We don't have any other option, so we must use the most
        ;; time-expensive option.
        (eat--t-carriage-return)
        (eat--t-index)))))

(defun eat--t-reverse-index ()
  "Go to the previous line preserving column, scrolling if needed."
  (let* ((cursor (eat--t-disp-cursor
                  (eat--t-term-display eat--t-term)))
         (scroll-begin (eat--t-term-scroll-begin eat--t-term))
         ;; Are we in the scroll region?
         (in-scroll-region (<= scroll-begin (eat--t-cur-y cursor))))
    ;; If this is the first line (of the scroll region or the
    ;; display), scroll down, otherwise move cursor upward.
    (if (= (if in-scroll-region scroll-begin 1)
           (eat--t-cur-y cursor))
        (eat--t-scroll-down 1)
      (eat--t-cur-up 1))))

(defun eat--t-bell ()
  "Ring the bell."
  ;; Call the UI's bell handler.
  (eat--bell eat--t-term))

(defun eat--t-form-feed ()
  "Insert a vertical tab."
  ;; Form feed is same as `eat--t-index'.
  (eat--t-index))

(defun eat--t-save-cur ()
  "Save current cursor position."
  (let ((disp (eat--t-term-display eat--t-term))
        (saved-face (eat--t-copy-face
                     (eat--t-term-face eat--t-term))))
    ;; Save cursor position.
    (setf (eat--t-disp-saved-cursor disp)
          (eat--t-copy-cur (eat--t-disp-cursor disp)))
    ;; Save SGR attributes.
    (setf (eat--t-term-saved-face eat--t-term) saved-face)
    ;; We use side-effects, so make sure the saved face doesn't share
    ;; structure with the current face.
    (setf (eat--t-face-face saved-face)
          (copy-tree (eat--t-face-face saved-face)))
    (setf (eat--t-face-underline-color saved-face)
          (copy-tree (eat--t-face-underline-color saved-face)))))

(defun eat--t-restore-cur ()
  "Restore previously save cursor position."
  (let ((saved (eat--t-disp-saved-cursor
                (eat--t-term-display eat--t-term))))
    ;; Restore cursor position.
    (eat--t-goto (eat--t-cur-y saved) (eat--t-cur-x saved))
    ;; Restore SGR attributes.
    (setf (eat--t-term-face eat--t-term)
          (copy-tree (eat--t-term-saved-face eat--t-term)))
    (setf (eat--t-face-underline-color (eat--t-term-face eat--t-term))
          (copy-tree (eat--t-face-underline-color
                      (eat--t-term-face eat--t-term))))))

(defun eat--t-erase-in-line (&optional n)
  "Erase part of current line, but don't move cursor.

N defaults to 0.  When N is 0, erase cursor to end of line.  When N is
1, erase beginning of line to cursor.  When N is 2, erase whole line."
  (let ((face (eat--t-term-face eat--t-term)))
    (pcase-exhaustive n
      ((or 0 'nil (pred (< 2)))
       ;; Delete cursor position (inclusive) to end of line.
       (delete-region (point) (car (eat--t-eol)))
       ;; If the SGR background attribute is set, we need to fill the
       ;; erased area with that background.
       (when (eat--t-face-bg face)
         (save-excursion
           (let* ((disp (eat--t-term-display eat--t-term))
                  (cursor (eat--t-disp-cursor disp)))
             (eat--t-repeated-insert
              ?\s (1+ (- (eat--t-disp-width disp)
                         (eat--t-cur-x cursor)))
              (and (eat--t-face-bg face)
                   (eat--t-face-face face)))))))
      (1
       ;; Delete beginning of line to cursor position (inclusive).
       (delete-region (car (eat--t-bol))
                      (if (or (= (point) (point-max))
                              (= (char-after) ?\n))
                          (point)
                        (1+ (point))))
       ;; Fill the region with spaces, use SGR background attribute
       ;; if set.
       (let ((cursor (eat--t-disp-cursor
                      (eat--t-term-display eat--t-term))))
         (eat--t-repeated-insert ?\s (eat--t-cur-x cursor)
                                 (and (eat--t-face-bg face)
                                      (eat--t-face-face face))))
       ;; We erased the character at the cursor position, so after
       ;; fill with spaces we are still off by one column; so move a
       ;; column backward.
       (backward-char))
      (2
       ;; Delete whole line.
       (delete-region (car (eat--t-bol)) (car (eat--t-eol)))
       (let* ((disp (eat--t-term-display eat--t-term))
              (cursor (eat--t-disp-cursor disp)))
         ;; Fill the region before cursor position with spaces, use
         ;; SGR background attribute if set.
         (eat--t-repeated-insert ?\s (1- (eat--t-cur-x cursor))
                                 (and (eat--t-face-bg face)
                                      (eat--t-face-face face)))
         ;; If the SGR background attribute is set, we need to fill
         ;; the erased area including and after cursor position with
         ;; that background.
         (when (eat--t-face-bg face)
           (save-excursion
             (eat--t-repeated-insert
              ?\s (1+ (- (eat--t-disp-width disp)
                         (eat--t-cur-x cursor)))
              (and (eat--t-face-bg face)
                   (eat--t-face-face face))))))))))

(defun eat--t-erase-in-disp (&optional n)
  "Erase part of display.

N defaults to 0.  When N is 0, erase cursor to end of display.  When N
is 1, erase beginning of display to cursor.  In both on the previous
cases, don't move cursor.  When N is 2, erase display and reset cursor
to (1, 1).  When N is 3, also erase the scrollback."
  (let ((face (eat--t-term-face eat--t-term)))
    (pcase-exhaustive n
      ((or 0 'nil (pred (< 3)))
       ;; Delete from cursor position (inclusive) to end of terminal.
       (delete-region (point) (point-max))
       ;; If the SGR background attribute is set, we need to fill the
       ;; erased area with that background.
       (when (eat--t-face-bg face)
         ;; `save-excursion' probably uses marker to save point, which
         ;; doesn't work in this case.  So we the store the point as a
         ;; integer.
         (let* ((pos (point))
                (disp (eat--t-term-display eat--t-term))
                (cursor (eat--t-disp-cursor disp)))
           ;; Fill current line.
           (eat--t-repeated-insert ?\s (1+ (- (eat--t-disp-width disp)
                                              (eat--t-cur-x cursor)))
                                   (eat--t-face-face face))
           ;; Fill the following lines.
           (dotimes (_ (- (eat--t-disp-height disp)
                          (eat--t-cur-y cursor)))
             (insert ?\n)
             (eat--t-repeated-insert ?\s (eat--t-disp-width disp)
                                     (eat--t-face-face face)))
           ;; Restore position.
           (goto-char pos))))
      (1
       (let* ((disp (eat--t-term-display eat--t-term))
              (cursor (eat--t-disp-cursor disp))
              (y (eat--t-cur-y cursor))
              (x (eat--t-cur-x cursor))
              ;; Should we erase including the cursor position?
              (incl-point (/= (point) (point-max))))
         ;; Delete the region to be erased.
         (delete-region (eat--t-disp-begin disp)
                        (if incl-point (1+ (point)) (point)))
         ;; If the SGR background attribute isn't set, insert
         ;; newlines, otherwise fill the erased area above the current
         ;; line with background color.
         (if (not (eat--t-face-bg face))
             (eat--t-repeated-insert ?\n (1- y))
           (dotimes (_ (1- y))
             (eat--t-repeated-insert ?\s (eat--t-disp-width disp)
                                     (eat--t-face-face face))
             (insert ?\n)))
         ;; Fill the current line to keep the cursor unmoved.  Use
         ;; background if the corresponding SGR attribute is set.
         (eat--t-repeated-insert ?\s x (and (eat--t-face-bg face)
                                            (eat--t-face-face face)))
         ;; We are off by one column; so move a column backward.
         (when incl-point
           (backward-char))))
      ((or 2 3)
       ;; Move to the display beginning.
       (eat--t-goto 1 1)
       ;; Delete everything in the display, and if N is 3, also delete
       ;; everything in the scrollback area.
       (delete-region (if (= n 2) (point) (point-min))
                      (point-max))
       ;; If the SGR background attribute is set, fill the display
       ;; with that background.
       (when (eat--t-face-bg face)
         ;; `save-excursion' probably uses marker to save point, which
         ;; doesn't work in this case.  So we the store the point as a
         ;; integer.
         (let ((pos (point))
               (disp (eat--t-term-display eat--t-term)))
           (dotimes (i (eat--t-disp-height disp))
             (unless (zerop i)
               (insert ?\n))
             (eat--t-repeated-insert ?\s (eat--t-disp-width disp)
                                     (eat--t-face-face face)))
           ;; Restore point.
           (goto-char pos)))))))

(defun eat--t-device-status-report (n)
  "Report device (terminal) status.

If N is 5, send OK sequence.  If N is 6, send the current Y and X
coordinate to client."
  (pcase n
    (5
     (eat--send-input eat--t-term "\e[0n"))
    (6
     (let ((cursor (eat--t-disp-cursor
                    (eat--t-term-display eat--t-term))))
       (eat--send-input eat--t-term
                       (format "\e[%i;%iR" (eat--t-cur-y cursor)
                               (eat--t-cur-x cursor)))))))

(defun eat--t-set-cursor-state (state)
  "Set cursor state to STATE.

STATE one of the `:invisible', `:block', `:blinking-block',
`:underline', `:blinking-underline', `:bar', `:blinking-bar'."
  (if (eq state :invisible)
      (when (eat--t-term-cur-visible-p eat--t-term)
        (setf (eat--t-term-cur-visible-p eat--t-term) nil)
        (eat--set-cursor eat--t-term :invisible))
    (unless (and (eat--t-term-cur-visible-p eat--t-term)
                 (eq (eat--t-term-cur-state eat--t-term) state))
      ;; Update state.
      (setf (eat--t-term-cur-state eat--t-term) state)
      (setf (eat--t-term-cur-visible-p eat--t-term) t)
      ;; Inform the UI.
      (eat--set-cursor eat--t-term state))))

(defun eat--t-set-cursor-style (style)
  "Set cursor state as described by STYLE."
  (when (<= 0 style 6)
    (let ((state (aref [ :block :block :block
                         :underline :underline
                         :bar :bar]
                       style)))
      (if (eat--t-term-cur-visible-p eat--t-term)
          (eat--t-set-cursor-state state)
        (setf (eat--t-term-cur-state eat--t-term) state)))))

(defun eat--t-show-cursor ()
  "Make the cursor visible."
  (when (not (eat--t-term-cur-visible-p eat--t-term))
    (eat--t-set-cursor-state (eat--t-term-cur-state eat--t-term))))

(defun eat--t-hide-cursor ()
  "Make the cursor invisible."
  (when (eat--t-term-cur-visible-p eat--t-term)
    (eat--t-set-cursor-state :invisible)))

(defun eat--t-enable-bracketed-yank ()
  "Enable bracketed yank mode."
  (setf (eat--t-term-bracketed-yank eat--t-term) t))

(defun eat--t-disable-bracketed-yank ()
  "Disable bracketed yank mode."
  (setf (eat--t-term-bracketed-yank eat--t-term) nil))

(defun eat--t-enable-alt-disp ()
  "Enable alternative display."
  ;; Make sure we not already in the alternative display.
  (unless (eat--t-term-main-display eat--t-term)
    ;; Store the current display, including scrollback.
    (let ((main-disp (eat--t-copy-disp
                      (eat--t-term-display eat--t-term))))
      (setf (eat--t-disp-begin main-disp)
            (- (eat--t-disp-begin main-disp) (point-min)))
      (setf (eat--t-disp-old-begin main-disp)
            (- (eat--t-disp-old-begin main-disp) (point-min)))
      (setf (eat--t-disp-cursor main-disp)
            (eat--t-copy-cur (eat--t-disp-cursor main-disp)))
      (setf (eat--t-disp-saved-cursor main-disp)
            (eat--t-copy-cur (eat--t-disp-saved-cursor main-disp)))
      (setf (eat--t-cur-position (eat--t-disp-cursor main-disp))
            (- (point) (point-min)))
      (setf (eat--t-term-main-display eat--t-term)
            (cons main-disp (buffer-string)))
      ;; Delete everything, and move to the beginning of terminal.
      (delete-region (point-min) (point-max))
      (eat--t-goto 1 1))))

(defun eat--t-disable-alt-disp (&optional dont-move-cursor)
  "Disable alternative display.

If DONT-MOVE-CURSOR is non-nil, don't move cursor from current
position."
  ;; Make sure we in the alternative display.
  (when (eat--t-term-main-display eat--t-term)
    (let ((main-disp (eat--t-term-main-display eat--t-term))
          (old-y (eat--t-cur-y
                  (eat--t-disp-cursor
                   (eat--t-term-display eat--t-term))))
          (old-x (eat--t-cur-x
                  (eat--t-disp-cursor
                   (eat--t-term-display eat--t-term))))
          (width (eat--t-disp-width
                  (eat--t-term-display eat--t-term)))
          (height (eat--t-disp-height
                   (eat--t-term-display eat--t-term))))
      ;; Delete everything.
      (delete-region (point-min) (point-max))
      ;; Restore the main display.
      (insert (cdr main-disp))
      (setf (eat--t-cur-position (eat--t-disp-cursor (car main-disp)))
            (copy-marker (+ (point-min)
                            (eat--t-cur-position
                             (eat--t-disp-cursor (car main-disp))))))
      (setf (eat--t-disp-old-begin (car main-disp))
            (copy-marker (+ (point-min)
                            (eat--t-disp-old-begin (car main-disp)))))
      (setf (eat--t-disp-begin (car main-disp))
            (copy-marker (+ (point-min)
                            (eat--t-disp-begin (car main-disp)))))
      (setf (eat--t-term-display eat--t-term) (car main-disp)
            (eat--t-term-main-display eat--t-term) nil)
      (goto-char (eat--t-cur-position
                  (eat--t-disp-cursor
                   (eat--t-term-display eat--t-term))))
      ;; Maybe the terminal was resized after enabling alternative
      ;; display, so we have to resize again.
      (eat--t-resize width height)
      ;; Restore cursor position if DONT-MOVE-CURSOR is non-nil.
      (when dont-move-cursor
        (eat--t-goto old-y old-x)))))

(defun eat--t-insert-char (n)
  "Insert N empty (space) characters, preserving cursor."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; Make sure N is positive.  If N is more than the number of
    ;; available columns available, set N to the maximum possible
    ;; value.
    (setq n (min (- (eat--t-disp-width disp)
                    (1- (eat--t-cur-x cursor)))
                 (max (or n 1) 1)))
    ;; Return if N is zero.
    (unless (zerop n)
      ;; If the position isn't safe, replace the multi-column
      ;; character with spaces to make it safe.
      (eat--t-make-pos-safe)
      (save-excursion
        (let ((face (eat--t-term-face eat--t-term)))
          ;; Insert N spaces, with SGR background if that attribute is
          ;; set.
          (eat--t-repeated-insert
           ?\s n (and (eat--t-face-bg face) (eat--t-face-face face))))
        ;; Remove the characters that went beyond the edge of
        ;; display.
        (eat--t-col-motion (- (eat--t-disp-width disp)
                              (+ (1- (eat--t-cur-x cursor)) n)))
        ;; Make sure we delete any multi-column character
        ;; completely.
        (eat--t-move-before-to-safe)
        (delete-region (point) (car (eat--t-eol)))))))

(defun eat--t-delete-char (n)
  "Delete N characters, preserving cursor."
  (let* ((disp (eat--t-term-display eat--t-term))
         (face (eat--t-term-face eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; Make sure N is positive.  If N is more than the number of
    ;; available columns available, set N to the maximum possible
    ;; value.
    (setq n (min (- (eat--t-disp-width disp)
                    (1- (eat--t-cur-x cursor)))
                 (max (or n 1) 1)))
    ;; Return if N is zero.
    (unless (zerop n)
      ;; If the position isn't safe, replace the multi-column
      ;; character with spaces to make it safe.
      (eat--t-make-pos-safe)
      (save-excursion
        (let ((m (point)))
          ;; Delete N character on current line.
          (eat--t-col-motion n)
          (delete-region m (point))
          ;; Replace any partially-overwritten character with spaces.
          (eat--t-fix-partial-multi-col-char)
          ;; If SGR background attribute is set, fill N characters at
          ;; the right edge of display with that background.
          (when (eat--t-face-bg face)
            (save-excursion
              (eat--t-goto-eol)
              (let ((empty (1+ (- (eat--t-disp-width disp)
                                  (eat--t-cur-x cursor)
                                  (- (point) m)))))
                ;; Reach the position from where to start filling.
                ;; Use spaces if needed.
                (when (> empty n)
                  (eat--t-repeated-insert ?\s (- empty n)))
                ;; Fill with background.
                (eat--t-repeated-insert
                 ?\s (min empty n) (eat--t-face-face face))))))))))

(defun eat--t-erase-char (n)
  "Make next N character cells empty, preserving cursor."
  (let* ((disp (eat--t-term-display eat--t-term))
         (face (eat--t-term-face eat--t-term))
         (cursor (eat--t-disp-cursor disp)))
    ;; Make sure N is positive.  If N is more than the number of
    ;; available columns available, set N to the maximum possible
    ;; value.
    (setq n (min (- (eat--t-disp-width disp)
                    (1- (eat--t-cur-x cursor)))
                 (max (or n 1) 1)))
    ;; Return if N is zero.
    (unless (zerop n)
      ;; If the position isn't safe, replace the multi-column
      ;; character with spaces to make it safe.
      (eat--t-make-pos-safe)
      (save-excursion
        (let ((m (point)))
          ;; Delete N character on current line.
          (eat--t-col-motion n)
          (delete-region m (point))
          ;; Replace any partially-overwritten character with spaces.
          (eat--t-fix-partial-multi-col-char)
          ;; Insert N spaces, with background if SGR background
          ;; attribute is set.
          (eat--t-repeated-insert
           ?\s n (and (eat--t-face-bg face)
                      (eat--t-face-face face))))))))

(defun eat--t-insert-line (n)
  "Insert N empty lines, preserving cursor."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (scroll-begin (eat--t-term-scroll-begin eat--t-term))
         (scroll-end (eat--t-term-scroll-end eat--t-term)))
    ;; N should be positive and shouldn't exceed the number of lines
    ;; below cursor position and inside current scroll region.
    (setq n (min (- (1+ (- scroll-end scroll-begin))
                    (1- (eat--t-cur-y cursor)))
                 (max (or n 1) 1)))
    ;; Make sure we are in the scroll region and N is positive, return
    ;; on failure.
    (when (and (<= scroll-begin (eat--t-cur-y cursor) scroll-end)
               (not (zerop n)))
      ;; This function doesn't move the cursor, but pushes all the
      ;; line below and including current line.  So to keep the cursor
      ;; unmoved, go to the beginning of line and insert enough spaces
      ;; to not move the cursor.
      (eat--t-goto-bol)
      (let ((face (eat--t-term-face eat--t-term)))
        (eat--t-repeated-insert ?\s (1- (eat--t-cur-x cursor))
                                (and (eat--t-face-bg face)
                                     (eat--t-face-face face)))
        (goto-char
         (prog1 (point)
           ;; Insert N lines.
           (if (not (eat--t-face-bg face))
               (eat--t-repeated-insert ?\n n)
             ;; SGR background attribute set, so fill the inserted
             ;; lines with background.
             (dotimes (i n)
               ;; Fill a line.
               (eat--t-repeated-insert
                ?\s (if (not (zerop i))
                        (eat--t-disp-width disp)
                      ;; The first inserted line is already filled
                      ;; partially, so calculate the number columns
                      ;; left to fill.
                      (1+ (- (eat--t-disp-width disp)
                             (eat--t-cur-x cursor))))
                (eat--t-face-face face))
               ;; New line.
               (insert ?\n)))
           ;; Delete the lines that were just pushed beyond the end of
           ;; scroll region.
           (eat--t-goto-eol (- (1+ (- scroll-end scroll-begin))
                               (+ (- (eat--t-cur-y cursor)
                                     (1- scroll-begin))
                                  n)))
           (delete-region (point) (car (eat--t-eol n)))))))))

(defun eat--t-delete-line (n)
  "Delete N lines, preserving cursor."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (x (eat--t-cur-x cursor))
         (scroll-begin (eat--t-term-scroll-begin eat--t-term))
         (scroll-end (eat--t-term-scroll-end eat--t-term)))
    ;; N should be positive and shouldn't exceed the number of
    ;; lines below cursor position and inside current scroll
    ;; region.
    (setq n (min (- (1+ (- scroll-end scroll-begin))
                    (1- (eat--t-cur-y cursor)))
                 (max (or n 1) 1)))
    ;; Make sure we are in the scroll region and N is positive, return
    ;; on failure.
    (when (and (<= scroll-begin (eat--t-cur-y cursor) scroll-end)
               (not (zerop n)))
      ;; Delete N lines (including the current one).
      (eat--t-goto-bol)
      (save-excursion
        (let ((m (point)))
          (eat--t-goto-bol n)
          (delete-region m (point))))
      (let ((face (eat--t-term-face eat--t-term)))
        ;; Keep the lines beyond end of scroll region unmoved.
        (when (or (< scroll-end (eat--t-disp-height disp))
                  (eat--t-face-bg face))
          (let* ((pos (point))
                 (move (- (1+ (- scroll-end scroll-begin))
                          (- (+ (eat--t-cur-y cursor) n)
                             (1- scroll-begin))))
                 (moved (eat--t-goto-eol move)))
            (when (or (/= (point) (point-max))
                      (eat--t-face-bg face))
              ;; Move to the end of scroll region.
              (eat--t-repeated-insert ?\n (- move moved))
              ;; Insert enough new lines, fill them when SGR
              ;; background attribute is set.
              (if (not (eat--t-face-bg face))
                  (eat--t-repeated-insert ?\n n)
                (dotimes (_ n)
                  (insert ?\n)
                  (eat--t-repeated-insert ?\s (eat--t-disp-width disp)
                                          (eat--t-face-face face)))))
            (goto-char pos))))
      ;; Go to column where cursor is to preserve cursor position, use
      ;; spaces if needed to reach the position.
      (eat--t-repeated-insert
       ?\s (- (1- x) (eat--t-col-motion (1- x)))))))

(defun eat--t-repeat-last-char (&optional n)
  "Repeat last character N times."
  ;; N must be at least one.
  (setq n (max (or n 1) 1))
  (let* ((disp (eat--t-term-display eat--t-term))
         (char
          ;; Get the character before cursor.
          (when (< (eat--t-disp-begin disp) (point))
            (if (get-text-property (1- (point)) 'eat--t-wrap-line)
                ;; The character before cursor is a newline to break
                ;; a long line, so use the character before that.
                (when (< (eat--t-disp-begin disp) (1- (point)))
                  (char-before (1- (point))))
              (char-before)))))
    ;; Insert `char' N times.  Make sure `char' is a non-nil and not
    ;; a newline.
    (when (and char (/= char ?\n))
      (eat--t-write (make-string n char)))))

(defun eat--t-change-scroll-region (&optional top bottom)
  "Change the scroll region from lines TOP to BOTTOM (inclusive).

TOP defaults to 1 and BOTTOM defaults to the height of the display."
  (let ((disp (eat--t-term-display eat--t-term)))
    (setq top (or top 1))
    (setq bottom (or bottom (eat--t-disp-height disp)))
    ;; According to DEC's documentation (found somewhere on the
    ;; internet, but can't remember where), TOP and BOTTOM must be
    ;; within display, and BOTTOM must be below TOP.  Otherwise the
    ;; control function is a nop.
    (when (< 0 top bottom (1+ (eat--t-disp-height disp)))
      (setf (eat--t-term-scroll-begin eat--t-term) top
            (eat--t-term-scroll-end eat--t-term) bottom)
      (eat--t-goto 1 1))))

(defun eat--t-insert-mode ()
  "Enable insert mode and disable replace mode."
  (setf (eat--t-term-ins-mode eat--t-term) t))

(defun eat--t-replace-mode ()
  "Enable replace mode and disable insert mode."
  (setf (eat--t-term-ins-mode eat--t-term) nil))

(defun eat--t-set-sgr-params (params)
  "Set SGR parameters PARAMS."
  (let ((face (eat--t-term-face eat--t-term)))
    ;; Set attributes.
    (while params
      (pcase (pop params)
        (`(,(or 0 'nil))
         (1value (setf (eat--t-face-fg face) nil))
         (1value (setf (eat--t-face-bg face) nil))
         (1value (setf (eat--t-face-intensity face) nil))
         (1value (setf (eat--t-face-italic face) nil))
         (1value (setf (eat--t-face-underline face) nil))
         (1value (setf (eat--t-face-underline-color face) nil))
         (1value (setf (eat--t-face-crossed face) nil))
         (1value (setf (eat--t-face-conceal face) nil))
         (1value (setf (eat--t-face-inverse face) nil))
         (setf (eat--t-face-font face)
               'eat-term-font-0))
        ('(1)
         (setf (eat--t-face-intensity face)
               'eat-term-bold))
        ('(2)
         (setf (eat--t-face-intensity face)
               'eat-term-faint))
        ('(3)
         (setf (eat--t-face-italic face)
               'eat-term-italic))
        ('(4)
         (1value (setf (eat--t-face-underline face) 'line)))
        ('(4 0)
         (1value (setf (eat--t-face-underline face) nil)))
        ('(4 1)
         (1value (setf (eat--t-face-underline face) 'line)))
        ('(4 2)
         (1value (setf (eat--t-face-underline face) 'line)))
        ('(4 3)
         (1value (setf (eat--t-face-underline face) 'wave)))
        ('(4 4)
         (1value (setf (eat--t-face-underline face) 'wave)))
        ('(4 5)
         (1value (setf (eat--t-face-underline face) 'wave)))
        ('(7)
         (1value (setf (eat--t-face-inverse face) t)))
        ('(8)
         (1value (setf (eat--t-face-conceal face) t)))
        ('(9)
         (1value (setf (eat--t-face-crossed face) t)))
        (`(,(and (pred (lambda (font) (<= 10 font 19)))
                 font))
         (setf (eat--t-face-font face)
               (eat--t-font-face (- font 10))))
        ('(21)
         (1value (setf (eat--t-face-underline face) 'line)))
        ('(22)
         (1value (setf (eat--t-face-intensity face) nil)))
        ('(23)
         (1value (setf (eat--t-face-italic face) nil)))
        ('(24)
         (1value (setf (eat--t-face-underline face) nil)))
        ('(27)
         (1value (setf (eat--t-face-inverse face) nil)))
        ('(28)
         (1value (setf (eat--t-face-conceal face) nil)))
        ('(29)
         (1value (setf (eat--t-face-crossed face) nil)))
        (`(,(and (pred (lambda (color) (<= 30 color 37)))
                 color))
         (setf (eat--t-face-fg face)
               (face-foreground
                (eat--t-color-face (- color 30))
                nil t)))
        ('(38)
         (pcase (pop params)
           ('(2)
            (setf (eat--t-face-fg face)
                  (let ((r (car (pop params)))
                        (g (car (pop params)))
                        (b (car (pop params))))
                    (when (and r (<= 0 r 255)
                               g (<= 0 g 255)
                               b (<= 0 b 255))
                      (format "#%02x%02x%02x" r g b)))))
           ('(5)
            (let ((color (car (pop params))))
              (setf (eat--t-face-fg face)
                    (when (and color (<= 0 color 255))
                      (face-foreground
                       (eat--t-color-face color)
                       nil t)))))))
        ('(39)
         (1value (setf (eat--t-face-fg face) nil)))
        (`(,(and (pred (lambda (color) (<= 40 color 47)))
                 color))
         (setf (eat--t-face-bg face)
               (face-foreground
                (eat--t-color-face (- color 40))
                nil t)))
        ('(48)
         (setf (eat--t-face-bg face)
               (pcase (pop params)
                 ('(2)
                  (let ((r (car (pop params)))
                        (g (car (pop params)))
                        (b (car (pop params))))
                    (when (and r (<= 0 r 255)
                               g (<= 0 g 255)
                               b (<= 0 b 255))
                      (format "#%02x%02x%02x" r g b))))
                 ('(5)
                  (let ((color (car (pop params))))
                    (when (and color (<= 0 color 255))
                      (face-foreground
                       (eat--t-color-face color)
                       nil t)))))))
        ('(49)
         (1value (setf (eat--t-face-bg face) nil)))
        ('(58)
         (setf (eat--t-face-underline-color face)
               (pcase (pop params)
                 ('(2)
                  (let ((r (car (pop params)))
                        (g (car (pop params)))
                        (b (car (pop params))))
                    (when (and r (<= 0 r 255)
                               g (<= 0 g 255)
                               b (<= 0 b 255))
                      (format "#%02x%02x%02x" r g b))))
                 ('(5)
                  (let ((color (car (pop params))))
                    (when (and color (<= 0 color 255))
                      (face-foreground
                       (eat--t-color-face color)
                       nil t)))))))
        ('(59)
         (1value (setf (eat--t-face-underline-color face) nil)))
        (`(,(and (pred (lambda (color) (<= 90 color 97)))
                 color))
         (setf (eat--t-face-fg face)
               (face-foreground
                (eat--t-color-face (- color 82))
                nil t)))
        (`(,(and (pred (lambda (color) (<= 100 color 107)))
                 color))
         (setf (eat--t-face-bg face)
               (face-foreground
                (eat--t-color-face (- color 92))
                nil t)))))
    ;; Update face according to the attributes.
    (setf (eat--t-face-face face)
          `(,@(and-let* ((fg (or (if (eat--t-face-conceal face)
                                     (eat--t-face-bg face)
                                   (eat--t-face-fg face))
                                 (cond
                                  ((eat--t-face-inverse face)
                                   (face-foreground 'default))
                                  ((eat--t-face-conceal face)
                                   (face-background 'default))))))
                (list (if (eat--t-face-inverse face)
                          :background
                        :foreground)
                      fg))
            ,@(and-let* ((bg (or (eat--t-face-bg face)
                                 (and (eat--t-face-inverse face)
                                      (face-background 'default)))))
                (list (if (eat--t-face-inverse face)
                          :foreground
                        :background)
                      bg))
            ,@(and-let* ((underline (eat--t-face-underline face)))
                (list
                 :underline
                 (list :color (eat--t-face-underline-color face)
                       :style underline)))
            ,@(and-let* ((crossed (eat--t-face-crossed face)))
                ;; REVIEW: How about colors?  No terminal supports
                ;; crossed attribute with colors, so we'll need to be
                ;; creative to add the feature.
                `(:strike-through t))
            :inherit
            (,@(and-let* ((intensity (eat--t-face-intensity face)))
                 (list intensity))
             ,@(and-let* ((italic (eat--t-face-italic face)))
                 (list italic))
             ,(eat--t-face-font face))))))

(defun eat--t-enable-keypad ()
  "Enable keypad."
  (1value (setf (eat--t-term-keypad-mode eat--t-term) t)))

(defun eat--t-disable-keypad ()
  "Disable keypad."
  (1value (setf (eat--t-term-keypad-mode eat--t-term) nil)))

(defun eat--t-enable-focus-event ()
  "Enable sending focus events."
  (1value (setf (eat--t-term-focus-event-mode eat--t-term) t)))

(defun eat--t-disable-focus-event ()
  "Disable sending focus events."
  (1value (setf (eat--t-term-focus-event-mode eat--t-term) nil)))

(defun eat--t-set-title (title)
  "Set the title of terminal to TITLE."
  (setf (eat--t-term-title eat--t-term) title))

(defun eat--t-send-device-attrs (n format)
  "Return device attributes.

FORMAT is the format of parameters in output.  N should be zero."
  (pcase-exhaustive format
    ('nil
     (when (= (or n 0) 0)
       (eat--send-input eat--t-term
                        "\e[?12;4c")))
    (?>
     (when (= (or n 0) 0)
       (eat--send-input eat--t-term
                        "\e[>0;0;0c")))))

(defun eat--t-report-foreground-color ()
  "Report the current default foreground color to the client."
  (eat--send-input eat--t-term
   (let ((rgb (or (color-values (face-foreground 'default))
                  ;; On terminals like TTYs the above returns nil.
                  ;; Terminals usually have a white foreground, so...
                  '(255 255 255))))
     (format "\e]10;rgb:%04x/%04x/%04x\e\\"
             (pop rgb) (pop rgb) (pop rgb)))))

(defun eat--t-report-background-color ()
  "Report the current default background color to the client."
  (eat--send-input eat--t-term
   (let ((rgb (or (color-values (face-background 'default))
                  ;; On terminals like TTYs the above returns nil.
                  ;; Terminals usually have a black background, so...
                  '(0 0 0))))
     (format "\e]11;rgb:%04x/%04x/%04x\e\\"
             (pop rgb) (pop rgb) (pop rgb)))))

(defun eat--t-manipulate-selection (targets data)
  "Set and send current selection.

TARGETS is a string containing zero or more characters from the set
`c', `p', `q', `s', `0', `1', `2', `3', `4', `5', `6', and `7'.  DATA
is the selection data encoded in base64."
  (when (string-empty-p targets)
    (setq targets "s0"))
  (if (string= data "?")
      ;; The client is requesting for clipboard content, let's try to
      ;; fulfill the request.
      (eat--send-input eat--t-term
       (let ((str nil)
             (n 0))
         ;; Remove invalid and duplicate targets from TARGETS before
         ;; processing it and sending it back.
         (setq targets
               (apply #'string
                      (cl-delete-duplicates
                       (cl-delete-if-not
                        (lambda (c) (or (<= ?0 c ?7)
                                        (memq c '(?c ?p ?q ?s))))
                        (string-to-list targets)))))
         (while (and (not str) (< n (length targets)))
           (setq
            str
            (pcase (aref targets n)
              ;; c, p, q and s targets are handled by the UI, and they
              ;; might refuse to give the clipboard content.
              (?c
               (funcall
                #'eat--manipulate-kill-ring
                eat--t-term :clipboard t))
              (?p
               (funcall
                #'eat--manipulate-kill-ring
                eat--t-term :primary t))
              (?q
               (funcall
                #'eat--manipulate-kill-ring
                eat--t-term :secondary t))
              (?s
               (funcall
                #'eat--manipulate-kill-ring
                eat--t-term :select t))
              ;; 0 to 9 targets are handled by us, and always work.
              ((and (pred (<= ?0))
                    (pred (>= ?7))
                    i)
               (aref (eat--t-term-cut-buffers eat--t-term)
                     (- i ?0)))))
           (cl-incf n))
         ;; No string to send, so send an empty string.
         (unless str (setq str ""))
         (format "\e]52;%s;%s\e\\" targets
                 (base64-encode-string (encode-coding-string
                                        str locale-coding-system)
                                       'no-line-break))))
    ;; The client is requesting to set clipboard content, let's try to
    ;; fulfill the request.
    (let ((str (ignore-errors
                 (decode-coding-string (base64-decode-string data)
                                       locale-coding-system))))
      (seq-doseq (target targets)
        (pcase target
          ;; c, p, q and s targets are handled by the UI, and they
          ;; might reject the new clipboard content.
          (?c
           (funcall #'eat--manipulate-kill-ring
                    eat--t-term :clipboard str))
          (?p
           (funcall #'eat--manipulate-kill-ring
                    eat--t-term :primary str))
          (?q
           (funcall #'eat--manipulate-kill-ring
                    eat--t-term :secondary str))
          (?s
           (funcall #'eat--manipulate-kill-ring
                    eat--t-term :select str))
          ;; 0 to 7 targets are handled by us, and always work.
          ((and (pred (<= ?0))
                (pred (>= ?7))
                i)
           (aset (eat--t-term-cut-buffers eat--t-term) (- i ?0)
                 str)))))))

(defun eat--t-ui-cmd (cmd)
  "Call UI's UIC handler to handle CMD."
  (eat--handle-uic eat--t-term cmd))

(defun eat--t-set-modes (params format)
  "Set modes according to PARAMS in format FORMAT."
  ;; Dispatch the request to appropriate function.
  (pcase format
    ('nil
     (while params
       (pcase (pop params)
         ('(4)
          (eat--t-insert-mode)))))
    (??
     (while params
       (pcase (pop params)
         ('(1)
          (eat--t-enable-keypad))
         ('(7)
          (eat--t-enable-auto-margin))
         ('(12))
         ('(25)
          (eat--t-show-cursor))
         ('(1004)
          (eat--t-enable-focus-event))
         ('(1048)
          (eat--t-save-cur))
         (`(,(or 1047 1049))
          (eat--t-enable-alt-disp))
         ('(2004)
          (eat--t-enable-bracketed-yank)))))))

(defun eat--t-reset-modes (params format)
  "Reset modes according to PARAMS in format FORMAT."
  ;; Dispatch the request to appropriate function.
  (pcase format
    ('nil
     (while params
       (pcase (pop params)
         ('(4)
          (eat--t-replace-mode)))))
    (??
     (while params
       (pcase (pop params)
         ('(1)
          (eat--t-disable-keypad))
         ('(7)
          (eat--t-disable-auto-margin))
         ('(12))
         ('(25)
          (eat--t-hide-cursor))
         ('(1004)
          (eat--t-disable-focus-event))
         ('(1047)
          (eat--t-disable-alt-disp 'dont-move-cursor))
         ('(1048)
          (eat--t-restore-cur))
         ('(1049)
          (eat--t-disable-alt-disp))
         ('(2004)
          (eat--t-disable-bracketed-yank)))))))

(defun eat--t-handle-output (output)
  "Parse and evaluate OUTPUT."
  (let ((index 0))
    (while (/= index (length output))
      (pcase-exhaustive (eat--t-term-parser-state eat--t-term)
        ('nil
         (let ((ins-beg index))
           (while (and (/= index (length output))
                       (not (memq (aref output index)
                                  '( ?\0 ?\a ?\b ?\t ?\n ?\v ?\f ?\r
                                     ?\C-n ?\C-o ?\e #x7f))))
             (cl-incf index))
           (when (/= ins-beg index)
             ;; Insert.
             (eat--t-write output ins-beg index))
           (when (/= index (length output))
             ;; Dispatch control sequence.
             (cl-incf index)
             (pcase (aref output (1- index))
               (?\a
                (eat--t-bell))
               (?\b
                (eat--t-cur-left 1))
               (?\t
                (eat--t-horizontal-tab 1))
               (?\n
                (eat--t-line-feed))
               (?\v
                (eat--t-index))
               (?\f
                (eat--t-form-feed))
               (?\r
                ;; Avoid going to line home just before a line feed,
                ;; we can just insert a new line if we are at the
                ;; end of display.
                (unless (and (/= index (length output))
                             (= (aref output index) ?\n))
                  (eat--t-carriage-return)))
               (?\C-n
                (eat--t-change-charset 'g1))
               (?\C-o
                (eat--t-change-charset 'g0))
               (?\e
                (1value (setf (eat--t-term-parser-state eat--t-term)
                              '(read-esc))))
               ;; Others are ignored.
               ))))
        ('(read-esc)
         (let ((type (aref output index)))
           (cl-incf index)
           (1value (setf (eat--t-term-parser-state eat--t-term) nil))
           ;; Dispatch control sequence.
           (pcase type
             ;; ESC (.
             (?\(
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-standard g0 "")))
             ;; ESC ).
             (?\)
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-standard g1 "")))
             ;; ESC *.
             (?*
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-standard g2 "")))
             ;; ESC +.
             (?+
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-standard g3 "")))
             ;; ESC -.
             (?-
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-vt300 g1 "")))
             ;; ESC ..
             (?.
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-vt300 g2 "")))
             ;; ESC /.
             (?/
              (setf (eat--t-term-parser-state eat--t-term)
                    '(read-charset-vt300 g3 "")))
             ;; ESC 7.
             (?7
              (eat--t-save-cur))
             ;; ESC 8.
             (?8
              (eat--t-restore-cur))
             ;; ESC D.
             (?D
              (eat--t-index))
             ;; ESC E.
             (?E
              (eat--t-line-feed))
             ;; ESC M.
             (?M
              (eat--t-reverse-index))
             ;; ESC P, or DCS.
             (?P
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            `(read-dcs-params (read-dcs-function)
                                              ,(list nil)))))
             ;; ESC X, or SOS.
             (?X
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            '(read-sos ""))))
             ;; ESC [, or CSI.
             (?\[
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            '(read-csi-format))))
             ;; ESC ], or OSC.
             (?\]
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            '(read-osc ""))))
             ;; ESC ^, or PM.
             (?^
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            '(read-pm ""))))
             ;; ESC _, or APC.
             (?_
              (1value (setf (eat--t-term-parser-state eat--t-term)
                            '(read-apc ""))))
             ;; ESC c.
             (?c
              (eat--t-reset))
             ;; ESC n.
             (?n
              (eat--t-change-charset 'g2))
             ;; ESC o.
             (?o
              (eat--t-change-charset 'g3)))))
        ('(read-csi-format)
         (let ((format nil))
           (pcase (aref output index)
             (??
              (setq format ??)
              (cl-incf index))
             (?>
              (setq format ?>)
              (cl-incf index))
             (?=
              (setq format ?=)
              (cl-incf index)))
           (setf (eat--t-term-parser-state eat--t-term)
                 `(read-csi-params ,format ,(list (list nil))))))
        (`(read-csi-params ,format ,params)
         ;; Interpretion of the parameter depends on `format' and
         ;; other things (including things we haven't gotten yet)
         ;; according to the standard.  We don't recognize any other
         ;; format of parameters, so we can skip any checks.
         (let ((loop t))
           (while loop
             (cond
              ((= index (length output))
               ;; Output exhausted.  We need to wait for more.
               (setf (eat--t-term-parser-state eat--t-term)
                     `(read-csi-params ,format ,params))
               (setq loop nil))
              ((not (<= ?0 (aref output index) ?\;))
               ;; End of parameters.
               ;; NOTE: All parameter and their parts are in reverse
               ;; order!
               (setf (eat--t-term-parser-state eat--t-term)
                     `(read-csi-function ,format ,params nil))
               (setq loop nil))
              (t
               (cond
                ((= (aref output index) ?:)
                 ;; New parameter substring.
                 (push nil (car params)))
                ((= (aref output index) ?\;)
                 ;; New parameter.
                 (push (list nil) params))
                (t                    ; (<= ?0 (aref output index) ?9)
                 ;; Number, save it.
                 (setf (caar params)
                       (+ (* (or (caar params) 0) 10)
                          (- (aref output index) #x30)))))
               (cl-incf index))))))
        (`(read-csi-function ,format ,params ,function)
         (let ((loop t))
           (while loop
             (cond
              ((= index (length output))
               (setf (eat--t-term-parser-state eat--t-term)
                     `(read-csi-function ,format ,params ,function))
               (setq loop nil)))
             (push (aref output index) function)
             (cl-incf index)
             (when (<= ?@ (car function) ?~)
               ;; Now we have enough information to execute it!
               (setq loop nil)
               (setf (eat--t-term-parser-state eat--t-term) nil)
               ;; NOTE: `function' and `params' are in reverse order!
               (pcase (list function format params)
                 ;; CSI <n> @.
                 (`((?@) nil ((,n)))
                  (eat--t-insert-char n))
                 ;; CSI <n> A.
                 ;; CSI <n> k.
                 (`((,(or ?A ?k)) nil ((,n)))
                  (eat--t-cur-up n))
                 ;; CSI <n> B.
                 ;; CSI <n> e.
                 (`((,(or ?B ?e)) nil ((,n)))
                  (eat--t-cur-down n))
                 ;; CSI <n> C.
                 ;; CSI <n> a.
                 (`((,(or ?C ?a)) nil ((,n)))
                  (eat--t-cur-right n))
                 ;; CSI <n> D.
                 ;; CSI <n> j.
                 (`((,(or ?D ?j)) nil ((,n)))
                  (eat--t-cur-left n))
                 ;; CSI <n> E.
                 (`((?E) nil ((,n)))
                  (eat--t-beg-of-next-line n))
                 ;; CSI <n> F.
                 (`((?F) nil ((,n)))
                  (eat--t-beg-of-prev-line n))
                 ;; CSI <n> G.
                 ;; CSI <n> `.
                 (`((,(or ?G ?`)) nil ((,n)))
                  (eat--t-cur-horizontal-abs n))
                 ;; CSI <n> ; <m> H
                 ;; CSI <n> ; <m> f
                 (`((,(or ?H ?f)) nil ,(and (pred listp) params))
                  (eat--t-goto (caadr params) (caar params)))
                 ;; CSI <n> I.
                 (`((?I) nil ((,n)))
                  (eat--t-horizontal-tab n))
                 ;; CSI <n> J.
                 (`((?J) nil ((,n)))
                  (eat--t-erase-in-disp n))
                 ;; CSI <n> K.
                 (`((?K) nil ((,n)))
                  (eat--t-erase-in-line n))
                 ;; CSI <n> L.
                 (`((?L) nil ((,n)))
                  (eat--t-insert-line n))
                 ;; CSI <n> M.
                 (`((?M) nil ((,n)))
                  (eat--t-delete-line n))
                 ;; CSI <n> P.
                 (`((?P) nil ((,n)))
                  (eat--t-delete-char n))
                 ;; CSI <n> S.
                 (`((?S) nil ((,n)))
                  (eat--t-scroll-up n))
                 ;; CSI <n> T.
                 (`((?T) nil ((,n)))
                  (eat--t-scroll-down n))
                 ;; CSI <n> X.
                 (`((?X) nil ((,n)))
                  (eat--t-erase-char n))
                 ;; CSI <n> Z.
                 (`((?Z) nil ((,n)))
                  (eat--t-horizontal-backtab n))
                 ;; CSI <n> b.
                 (`((?b) nil ((,n)))
                  (eat--t-repeat-last-char n))
                 ;; CSI <n> c.
                 ;; CSI > <n> c.
                 (`((?c) ,format ((,n)))
                  (eat--t-send-device-attrs n format))
                 ;; CSI <n> d.
                 (`((?d) nil ((,n)))
                  (eat--t-cur-vertical-abs n))
                 ;; CSI ... h.
                 ;; CSI ? ... h.
                 (`((?h) ,format ,(and (pred listp) params))
                  ;; Reverse `params' to get it into the correct
                  ;; order.
                  (setq params (nreverse params))
                  (let ((p params))
                    (while p
                      (setf (car p) (nreverse (car p)))
                      (setq p (cdr p))))
                  (eat--t-set-modes params format))
                 ;; CSI ... l.
                 ;; CSI ? ... l.
                 (`((?l) ,format ,(and (pred listp) params))
                  ;; Reverse `params' to get it into the correct
                  ;; order.
                  (setq params (nreverse params))
                  (let ((p params))
                    (while p
                      (setf (car p) (nreverse (car p)))
                      (setq p (cdr p))))
                  (eat--t-reset-modes params format))
                 ;; CSI ... m.
                 (`((?m) nil ,(and (pred listp) params))
                  ;; Reverse `params' to get it into the correct
                  ;; order.
                  (setq params (nreverse params))
                  (let ((p params))
                    (while p
                      (setf (car p) (nreverse (car p)))
                      (setq p (cdr p))))
                  (eat--t-set-sgr-params params))
                 ;; CSI 6 n.
                 (`((?n) nil ((,n)))
                  (eat--t-device-status-report n))
                 ;; CSI <n> SP q.
                 (`((?q ?\ ) nil ((,n)))
                  (eat--t-set-cursor-style n))
                 ;; CSI <n> ; <n> r.
                 (`((?r) nil ,(and (pred listp) params))
                  (eat--t-change-scroll-region (caadr params)
                                               (caar params)))
                 ;; CSI s.
                 (`((?s) nil ,_)
                  (eat--t-save-cur))
                 ;; CSI u.
                 (`((?u) nil ,_)
                  (eat--t-restore-cur)))))))
        (`(,(and (or 'read-sos 'read-osc 'read-pm 'read-apc) state)
           ,buf)
         ;; Find the end of string.
         (let ((match (string-match (if (eq state 'read-osc)
                                        (rx (or ?\a ?\\))
                                      (rx ?\\))
                                    output index)))
           (if (not match)
               (progn
                 ;; Not found, store the text to process it later when
                 ;; we get the end of string.
                 (setf (eat--t-term-parser-state eat--t-term)
                       `(,state ,(concat buf (substring output
                                                        index))))
                 (setq index (length output)))
             ;; Matched!  Get the string from the output and previous
             ;; runs.
             (let ((str (concat buf (substring output index
                                               match))))
               (setq index (match-end 0))
               ;; Is it really the end of string?
               (if (and (= (aref output match) ?\\)
                        (not (or (zerop (length str))
                                 (= (aref str (1- (length str)))
                                    ?\e))))
                   ;; No.  Push the '\' character to process later.
                   (setf (eat--t-term-parser-state eat--t-term)
                         `(,state ,(concat str "\\")))
                 ;; Yes!  It's the end!  We can parse it.
                 (when (= (aref output match) ?\\)
                   (setq str (substring str 0 (1- (length str)))))
                 (setf (eat--t-term-parser-state eat--t-term) nil)
                 ;; Dispatch control sequence.
                 (pcase state
                   ('read-osc
                    (pcase str
                      ;; OSC 0 ; <t> ST.
                      ;; OSC 2 ; <t> ST.
                      ((rx string-start (or ?0 ?2) ?\;
                           (let title (zero-or-more anything))
                           string-end)
                       (eat--t-set-title title))
                      ;; OSC 1 0 ; ? ST.
                      ("10;?"
                       (eat--t-report-foreground-color))
                      ;; OSC 1 1 ; ? ST.
                      ("11;?"
                       (eat--t-report-background-color))
                      ;; OSC 5 1 ; <s> ST.
                      ((rx string-start "51;"
                           (let cmd (zero-or-more anything))
                           string-end)
                       (eat--t-ui-cmd cmd))
                      ;; OSC 5 2 ; <t> ; <s> ST.
                      ((rx string-start "52;"
                           (let targets
                             (zero-or-more (not (any ?\;))))
                           ?\; (let data (zero-or-more anything))
                           string-end)
                       (eat--t-manipulate-selection
                        targets data))))))))))
        (`(read-dcs-params ,next-state ,params)
         ;; There is no standard format of device control strings, but
         ;; all DEC and XTerm DCS sequences (including those we
         ;; support) follow this particular format.
         (let ((loop t))
           (while loop
             (cond
              ((= index (length output))
               ;; Output exhausted.  We need to wait for more.
               (setf (eat--t-term-parser-state eat--t-term)
                     `(read-dcs-params ,next-state ,params))
               (setq loop nil))
              ((not (or (<= ?0 (aref output index) ?9)
                        (= (aref output index) ?\;)))
               ;; End of parameters.
               ;; NOTE: All parameter and their parts are in reverse
               ;; order!
               (setf (eat--t-term-parser-state eat--t-term)
                     `(,@next-state ,params))
               (setq loop nil))
              (t
               (if (= (aref output index) ?\;)
                   ;; New parameter.
                   (push nil params)
                 ;; Number, save it.
                 (setf (car params)
                       (+ (* (or (car params) 0) 10)
                          (- (aref output index) #x30))))
               (cl-incf index))))))
        (`(read-dcs-function ,_params)
         (cl-incf index)
         (pcase (aref output (1- index))
           (?\e
            (setf (eat--t-term-parser-state eat--t-term)
                  '(read-potential-st (read-dcs-fallback))))
           (_
            (setf (eat--t-term-parser-state eat--t-term)
                  '(read-dcs-fallback))
            (cl-decf index))))
        (`(read-potential-st ,else)
         (if (/= (aref output index) ?\\)
             (setf (eat--t-term-parser-state eat--t-term) else)
           (setf (eat--t-term-parser-state eat--t-term) nil)
           (cl-incf index)))
        (`(read-dcs-fallback)
         (let ((loop t))
           (while (and loop (/= index (length output)))
             (when (= (aref output index) ?\e)
               (setf (eat--t-term-parser-state eat--t-term)
                     '(read-potential-st (read-dcs-fallback)))
               (setq loop nil))
             (cl-incf index))))
        (`(read-charset-standard ,slot ,buf)
         ;; Find the end.
         (let ((match (string-match (rx (any ?0 ?2 ?4 ?5 ?6 ?7 ?9 ?<
                                             ?= ?> ?? ?A ?B ?C ?E ?H
                                             ?K ?Q ?R ?Y ?Z ?f))
                                    output index)))
           (if (not match)
               (progn
                 ;; Not found, store the text to process it later when
                 ;; we find the end.
                 (setf (eat--t-term-parser-state eat--t-term)
                       `(read-charset-standard
                         ,slot ,(concat buf (substring
                                             output index))))
                 (setq index (length output)))
             ;; Got the end!
             (let ((str (concat buf (substring output index
                                               (match-end 0)))))
               (setq index (match-end 0))
               (setf (eat--t-term-parser-state eat--t-term) nil)
               ;; Set the character set.
               (eat--t-set-charset
                slot
                (pcase str
                  ;; ESC ( 0.
                  ;; ESC ) 0.
                  ;; ESC * 0.
                  ;; ESC + 0.
                  ("0" 'dec-line-drawing)
                  ;; ESC ( B.
                  ;; ESC ) B.
                  ;; ESC * B.
                  ;; ESC + B.
                  ("B" 'us-ascii)))))))
        (`(read-charset-vt300 ,_slot ,_buf)
         (cl-incf index)
         (setf (eat--t-term-parser-state eat--t-term) nil)
         ;; Nothing.  This is here to just recognize the sequence.
         )))))

(defun eat--t-resize (width height)
  "Resize terminal to WIDTH x HEIGHT."
  (let* ((disp (eat--t-term-display eat--t-term))
         (cursor (eat--t-disp-cursor disp))
         (old-width (eat--t-disp-width disp))
         (old-height (eat--t-disp-height disp)))
    ;; Don't do anything if size hasn't changed, or the new size is
    ;; too small.
    (when (and (not (and (eq old-width width)
                         (eq old-height height)))
               (>= width 1)
               (>= height 1))
      ;; Update state.
      (setf (eat--t-disp-width disp) width)
      (setf (eat--t-disp-height disp) height)
      (setf (eat--t-term-scroll-begin eat--t-term) 1)
      (setf (eat--t-term-scroll-end eat--t-term)
            (eat--t-disp-height disp))
      (set-marker (eat--t-cur-position cursor) (point))
      (if (eat--t-term-main-display eat--t-term)
          ;; For alternative display, just delete the part of the
          ;; display that went out of the edges.  So if the terminal
          ;; was enlarged, we don't have anything to do.
          (when (or (< width old-width)
                    (< height old-height))
            ;; Go to the beginning of display.
            (goto-char (eat--t-disp-begin disp))
            (let ((l 0))
              (while (and (< l height) (not (eobp)))
                (eat--t-col-motion width)
                (delete-region (point) (car (eat--t-eol)))
                (unless (eobp)
                  (if (< (1+ l) height)
                      (forward-char)
                    (delete-region (point) (point-max))
                    (let ((y (eat--t-cur-y cursor))
                          (x (eat--t-cur-x cursor)))
                      (eat--t-goto 1 1)
                      (eat--t-goto y x))))
                (cl-incf l))))
        ;; REVIEW: This works, but it is very simple.  Most
        ;; terminals have more sophisticated mechanisms to do this.
        ;; It would be nice thing have them here.
        ;; Go to the beginning of display.
        (goto-char (eat--t-disp-begin disp))
        ;; Try to move to the end of previous line, maybe that's a
        ;; part of a too long line.
        (unless (bobp)
          (backward-char))
        ;; Join all long lines.
        (while (not (eobp))
          (eat--t-join-long-line))
        ;; Go to display beginning again and break long lines.
        (goto-char (eat--t-disp-begin disp))
        (while (not (eobp))
          (eat--t-break-long-line (eat--t-disp-width disp)))
        ;; Calculate the beginning position of display.
        (goto-char (point-max))
        ;; TODO: This part needs explanation.
        (let ((disp-begin (car (eat--t-bol (- (1- height))))))
          (when (< (eat--t-disp-begin disp) disp-begin)
            (goto-char (max (- (eat--t-disp-begin disp) 1)
                            (point-min)))
            (set-marker (eat--t-disp-begin disp) disp-begin)
            (while (< (point) (1- (eat--t-disp-begin disp)))
              (eat--t-join-long-line
               (1- (eat--t-disp-begin disp))))))
        ;; Update the cursor if needed.
        (when (< (eat--t-cur-position cursor)
                 (eat--t-disp-begin disp))
          (set-marker (eat--t-cur-position cursor)
                      (eat--t-disp-begin disp)))
        ;; Update the coordinates of cursor.
        (goto-char (eat--t-cur-position cursor))
        (setf (eat--t-cur-x cursor) (1+ (eat--t-current-col)))
        (goto-char (eat--t-disp-begin disp))
        (setf (eat--t-cur-y cursor)
              (let ((y 0))
                (while (< (point) (eat--t-cur-position cursor))
                  (condition-case nil
                      (search-forward
                       "\n" (eat--t-cur-position cursor))
                    (search-failed
                     (goto-char (eat--t-cur-position cursor))))
                  (cl-incf y))
                (when (or (= (point) (point-min))
                          (= (char-before) ?\n))
                  (cl-incf y))
                (max y 1)))))))

;;;###autoload
(defun eat-term-make (buffer position)
  "Make a Eat terminal at POSITION in BUFFER."
  (eat--t-make-term
   :buffer buffer
   :begin (copy-marker position t)
   :end (copy-marker position)
   :display (eat--t-make-disp
             :begin (copy-marker position)
             :old-begin (copy-marker position)
             :cursor (eat--t-make-cur
                      :position (copy-marker position)))))

(defun eat-term-p (object)
  "Return non-nil if OBJECT is a Eat terminal."
  (eat--t-term-p object))

(defun eat-term-live-p (object)
  "Return non-nil if OBJECT is a live Eat terminal."
  (and (eat-term-p object)
       (not (not (eat--t-term-buffer object)))))

(defmacro eat--t-ensure-live-term (object)
  "Signal error if OBJECT is not a live Eat terminal."
  `(unless (eat-term-live-p ,object)
     (error "%s is not a live Eat terminal"
            ,(upcase (symbol-name object)))))

(defmacro eat--t-with-env (terminal &rest body)
  "Setup the environment for TERMINAL and eval BODY in it."
  (declare (indent 1))
  `(let ((eat--t-term ,terminal))
     (eat--t-ensure-live-term ,terminal)
     (with-current-buffer (eat--t-term-buffer eat--t-term)
       (save-excursion
         (save-restriction
           (narrow-to-region (eat--t-term-begin eat--t-term)
                             (eat--t-term-end eat--t-term))
           (goto-char (eat--t-cur-position
                       (eat--t-disp-cursor
                        (eat--t-term-display eat--t-term))))
           (unwind-protect
               (progn ,@body)
             (set-marker (eat--t-cur-position
                          (eat--t-disp-cursor
                           (eat--t-term-display eat--t-term)))
                         (point))
             (set-marker (eat--t-term-begin eat--t-term) (point-min))
             (set-marker (eat--t-term-end eat--t-term)
                         (point-max))))))))

(defun eat-term-delete (terminal)
  "Delete TERMINAL and do any cleanup to do."
  (eat--t-ensure-live-term terminal)
  (let ((inhibit-quit t)
        (eat--t-term terminal))
    (with-current-buffer (eat--t-term-buffer eat--t-term)
      (save-excursion
        (save-restriction
          (narrow-to-region (eat--t-term-begin eat--t-term)
                            (eat--t-term-end eat--t-term))
          (eat--t-set-cursor-state :default)
          ;; Go to the beginning of display.
          (goto-char (eat--t-disp-begin
                      (eat--t-term-display eat--t-term)))
          ;; Join all long lines.
          (unless (bobp)
            (backward-char))
          (while (not (eobp))
            (eat--t-join-long-line)))))
    (setf (eat--t-term-buffer eat--t-term) nil)))

(defun eat-term-reset (terminal)
  "Reset TERMINAL."
  (let ((inhibit-quit t))
    (eat--t-with-env terminal
      (eat--t-reset))))

(defun eat-term-cursor-type (terminal)
  "Return the cursor state of TERMINAL.

The return value can be one of the following:

  `:invisible'          Invisible cursor.
  `:block'              Block (filled box) cursor (default).
  `:blinking-block'     Very visible block cursor.
  `:bar'                Vertical bar cursor.
  `:blinking-bar'       Very visible vertical bar cursor.
  `:underline'          Horizontal bar cursor.
  `:blinking-underline' Very visible horizontal bar cursor."
  (eat--t-ensure-live-term terminal)
  (if (eat--t-term-cur-visible-p terminal)
      (eat--t-term-cur-state terminal)
    :invisible))

(defun eat-term-beginning (terminal)
  "Return the beginning position of TERMINAL.

Don't use markers to store the position, call this function whenever
you need the position."
  (eat--t-ensure-live-term terminal)
  (eat--t-term-begin terminal))

(defun eat-term-end (terminal)
  "Return the end position of TERMINAL.

This is also the end position of TERMINAL's display.

Don't use markers to store the position, call this function whenever
you need the position."
  (eat--t-ensure-live-term terminal)
  (eat--t-term-end terminal))

(defun eat-term-display-beginning (terminal)
  "Return the beginning position of TERMINAL's display."
  (eat--t-ensure-live-term terminal)
  (eat--t-disp-begin (eat--t-term-display terminal)))

(defun eat-term-display-cursor (terminal)
  "Return the cursor's current position on TERMINAL's display."
  (eat--t-ensure-live-term terminal)
  (let* ((disp (eat--t-term-display terminal))
         (cursor (eat--t-disp-cursor disp)))
    ;; The cursor might be after the edge of the display.  But we
    ;; don't want the UI to show that, so show cursor at the edge.
    (if (> (eat--t-cur-x cursor) (eat--t-disp-width disp))
        (1- (eat--t-cur-position cursor))
      (eat--t-cur-position cursor))))

(defun eat-term-title (terminal)
  "Return the current title of TERMINAL."
  (eat--t-ensure-live-term terminal)
  (eat--t-term-title terminal))

(defun eat-term-size (terminal)
  "Return the size of TERMINAL as (WIDTH . HEIGHT)."
  (eat--t-ensure-live-term terminal)
  (let ((disp (eat--t-term-display terminal)))
    (cons (eat--t-disp-width disp) (eat--t-disp-height disp))))

(defun eat-term-process-output (terminal output)
  "Process OUTPUT from client and show it on TERMINAL's display."
  (let ((inhibit-quit t))
    (eat--t-with-env terminal
      (eat--t-handle-output output))))

(defun eat-term-redisplay (terminal)
  "Prepare TERMINAL for displaying."
  (let ((inhibit-quit t))
    (eat--t-with-env terminal
      (let ((disp (eat--t-term-display eat--t-term)))
        (when (< (eat--t-disp-old-begin disp)
                 (eat--t-disp-begin disp))
          ;; Join long lines.
          (let ((limit (copy-marker (1- (eat--t-disp-begin disp)))))
            (save-excursion
              (goto-char (max (1- (eat--t-disp-old-begin disp))
                              (point-min)))
              (while (< (point) limit)
                (eat--t-join-long-line limit))))
          ;; Truncate scrollback.
          (when eat-term-scrollback-size
            (delete-region
             (point-min)
             (max (point-min) (- (point) eat-term-scrollback-size))))
          (set-marker (eat--t-disp-old-begin disp)
                      (eat--t-disp-begin disp)))))))

(defun eat-term-resize (terminal width height)
  "Resize TERMINAL to WIDTH x HEIGHT."
  (let ((inhibit-quit t))
    (eat--t-with-env terminal
      (eat--t-resize width height))))

(defun eat-term-in-alternative-display-p (terminal)
  "Return non-nil when TERMINAL is in alternative display mode."
  (eat--t-ensure-live-term terminal)
  (eat--t-term-main-display terminal))

(defun eat-term-input-event (terminal n event &optional ref-pos)
  "Send EVENT as input N times to TERMINAL.

EVENT should be a event.  It can be any standard Emacs event, or a
event list of any of the following forms:

  (eat-focus-in)
    Terminal just gained focus.

  (eat-focus-out)
    Terminal just lost focus.

REF-POS is a mouse position list pointing to the start of terminal
display satisfying the predicate `posnp'."
  (eat--t-ensure-live-term terminal)
  (let ((disp (eat--t-term-display terminal)))
    (cl-flet ((send (str)
                (eat--send-input terminal str)))
      (dotimes (_ (or n 1))
        (pcase event
          ;; Arrow key, `insert', `delete', `deletechar', `home',
          ;; `end', `prior', `next' and their modifier variants.
          ((and (or 'up 'down 'right 'left
                    'C-up 'C-down 'C-right 'C-left
                    'M-up 'M-down 'M-right 'M-left
                    'S-up 'S-down 'S-right 'S-left
                    'C-M-up 'C-M-down 'C-M-right 'C-M-left
                    'C-S-up 'C-S-down 'C-S-right 'C-S-left
                    'M-S-up 'M-S-down 'M-S-right 'M-S-left
                    'C-M-S-up 'C-M-S-down 'C-M-S-right 'C-M-S-left
                    'insert 'C-insert 'M-insert 'S-insert 'C-M-insert
                    'C-S-insert 'M-S-insert 'C-M-S-insert
                    'delete 'C-delete 'M-delete 'S-delete 'C-M-delete
                    'C-S-delete 'M-S-delete 'C-M-S-delete
                    'deletechar 'C-deletechar 'M-deletechar
                    'S-deletechar 'C-M-deletechar 'C-S-deletechar
                    'M-S-deletechar 'C-M-S-deletechar
                    'home 'C-home 'M-home 'S-home 'C-M-home 'C-S-home
                    'M-S-home 'C-M-S-home
                    'end 'C-end 'M-end 'S-end 'C-M-end 'C-S-end
                    'M-S-end 'C-M-S-end
                    'prior 'C-prior 'M-prior 'S-prior 'C-M-prior
                    'C-S-prior 'M-S-prior 'C-M-S-prior
                    'next 'C-next 'M-next 'S-next 'C-M-next 'C-S-next
                    'M-S-next 'C-M-S-next)
                ev)
           (send
            (format
             "\e%s%c"
             (if (not (or (memq 'control (event-modifiers ev))
                          (memq 'meta (event-modifiers ev))
                          (memq 'shift (event-modifiers ev))))
                 (pcase (event-basic-type ev)
                   ('insert "[2")
                   ((or 'delete 'deletechar) "[3")
                   ('prior "[5")
                   ('next "[6")
                   (_ (if (eat--t-term-keypad-mode terminal)
                          "O"
                        "[")))
               (format
                "[%c;%c"
                (pcase (event-basic-type ev)
                  ('insert ?2)
                  ((or 'delete 'deletechar) ?3)
                  ('prior ?5)
                  ('next ?6)
                  (_ ?1))
                (pcase-exhaustive (event-modifiers ev)
                  ((and (pred (memq 'control))
                        (pred (memq 'meta))
                        (pred (memq 'shift)))
                   ?8)
                  ((and (pred (memq 'control))
                        (pred (memq 'meta)))
                   ?7)
                  ((and (pred (memq 'control))
                        (pred (memq 'shift)))
                   ?6)
                  ((and (pred (memq 'meta))
                        (pred (memq 'shift)))
                   ?4)
                  ((pred (memq 'control))
                   ?5)
                  ((pred (memq 'meta))
                   ?3)
                  ((pred (memq 'shift))
                   ?2))))
             (pcase (event-basic-type ev)
               ('up ?A)
               ('down ?B)
               ('right ?C)
               ('left ?D)
               ('home ?H)
               ('end ?F)
               (_ ?~)))))
          ((or 'backspace ?\C-?)
           (send "\C-?"))
          ('C-backspace
           (send "\C-h"))
          ((or 'M-backspace
               (pred (lambda (ev)
                       (and (equal (event-basic-type ev) ?\C-?)
                            (equal (event-modifiers ev) '(meta))))))
           (send "\e\C-?"))
          ('C-M-backspace
           (send "\e\C-h"))
          ('tab
           (send "\t"))
          ('backtab
           (send "\e[Z"))
          ;; Function keys.
          ((and (pred symbolp)
                fn-key
                (let (rx string-start "f"
                         (let fn-num (one-or-more (any (?0 . ?9))))
                         string-end)
                  (symbol-name fn-key))
                (let (and (pred (<= 1))
                          (pred (>= 63))
                          key)
                  (string-to-number fn-num)))
           (send
            (aref
             ["\eOP" "\eOQ" "\eOR" "\eOS" "\e[15~" "\e[17~" "\e[18~"
              "\e[19~" "\e[20~" "\e[21~" "\e[23~" "\e[24~" "\e[1;2P"
              "\e[1;2Q" "\e[1;2R" "\e[1;2S" "\e[15;2~" "\e[17;2~"
              "\e[18;2~" "\e[19;2~" "\e[20;2~" "\e[21;2~" "\e[23;2~"
              "\e[24;2~" "\e[1;5P" "\e[1;5Q" "\e[1;5R" "\e[1;5S"
              "\e[15;5~" "\e[17;5~" "\e[18;5~" "\e[19;5~" "\e[20;5~"
              "\e[21;5~" "\e[23;5~" "\e[24;5~" "\e[1;6P" "\e[1;6Q"
              "\e[1;6R" "\e[1;6S" "\e[15;6~" "\e[17;6~" "\e[18;6~"
              "\e[19;6~" "\e[20;6~" "\e[21;6~" "\e[23;6~" "\e[24;6~"
              "\e[1;3P" "\e[1;3Q" "\e[1;3R" "\e[1;3S" "\e[15;3~"
              "\e[17;3~" "\e[18;3~" "\e[19;3~" "\e[20;3~" "\e[21;3~"
              "\e[23;3~" "\e[24;3~" "\e[1;4P" "\e[1;4Q" "\e[1;4R"]
             (1- key))))
          ((and (or (pred numberp)
                    (pred symbolp))
                char)
           ;; Adapted from Term source.
           (when (symbolp char)
             ;; Convert `return' to C-m, etc.
             (let ((tmp (get char 'event-symbol-elements)))
               (when tmp
                 (setq char (car tmp)))
               (and (symbolp char)
                    (setq tmp (get char 'ascii-character))
                    (setq char tmp))))
           (when (numberp char)
             (let ((base (event-basic-type char))
                   (mods (event-modifiers char)))
               ;; Try to avoid event-convert-list if possible.
               (if (and (characterp char)
                        (not (memq 'meta mods))
                        (not (and (memq 'control mods)
                                  (memq 'shift mods))))
                   (send (format "%c" char))
                 (when (memq 'control mods)
                   (setq mods (delq 'shift mods)))
                 (let ((ch (pcase (event-convert-list
                                   (append (remq 'meta mods)
                                           (list base)))
                             (?\C-\s ?\C-@)
                             (?\C-/ ?\C-?)
                             (?\C-- ?\C-_)
                             (c c))))
                   (when (characterp ch)
                     (send (cond
                            ((and (memq 'meta mods)
                                  (memq ch '(?\[ ?O)))
                             "\e")
                            (t
                             (format
                              (if (memq 'meta mods) "\e%c" "%c")
                              ch))))))))))
          ;; Focus events.
          ('(eat-focus-in)
           (when (eat--t-term-focus-event-mode terminal)
             (send "\e[I")))
          ('(eat-focus-out)
           (when (eat--t-term-focus-event-mode terminal)
             (send "\e[O"))))))))

(defun eat-term-send-string (terminal string)
  "Send STRING to TERMINAL directly."
  (eat--t-ensure-live-term terminal)
  (eat--send-input terminal string))

(defun eat-term-send-string-as-yank (terminal args)
  "Send ARGS to TERMINAL, honoring bracketed yank mode.

Each argument in ARGS can be either string or character."
  (eat--t-ensure-live-term terminal)
  (eat--send-input terminal
           (let ((str (mapconcat (lambda (s)
                                   (if (stringp s) s (string s)))
                                 args "")))
             (if (eat--t-term-bracketed-yank terminal)
                 ;; REVIEW: What if `str' itself contains these escape
                 ;; sequences?  St doesn't care and just wraps the
                 ;; string with these magic escape sequences, while
                 ;; Kitty tries to be smart.
                 (format "\e[200~%s\e[201~" str)
               str))))

(defun eat-term-make-keymap (input-command categories exceptions)
  "Make a keymap binding INPUT-COMMAND to the events of CATEGORIES.

CATEGORIES is a list whose elements should be a one of the following
keywords:

  `:ascii'              All self-insertable characters, plus
                        `backspace', `DEL', `insert', `delete' and
                        `deletechar' keys, with all possible
                        modifiers.
  `:arrow'              Arrow keys with all possible modifiers.
  `:navigation'         Navigation keys: home, end, prior (or page up)
                        and next (or page down) with all possible
                        modifiers.
  `:function'           Function keys (f1 - f63).
EXCEPTIONS is a list of key sequences to not bind.  Don't use
\"M-...\" key sequences in EXCEPTIONS, use \"ESC ...\" instead."
  (let ((map (make-sparse-keymap)))
    (cl-flet ((bind (key)
                (unless (member key exceptions)
                  (define-key map key input-command))))
      (when (memq :ascii categories)
        ;; Bind ASCII and self-insertable characters except ESC.
        (bind [remap self-insert-command])
        (cl-loop
         for i from ?\C-@ to ?\C-?
         do (unless (= i meta-prefix-char)
              (bind (vector i))))
        ;; Bind `tab', `backspace', `delete', `deletechar', and all
        ;; modified variants.
        (dolist (key '( tab backtab backspace C-backspace
                        M-backspace C-M-backspace
                        insert C-insert M-insert S-insert C-M-insert
                        C-S-insert M-S-insert C-M-S-insert
                        delete C-delete M-delete S-delete C-M-delete
                        C-S-delete M-S-delete C-M-S-delete
                        deletechar C-deletechar M-deletechar
                        S-deletechar C-M-deletechar C-S-deletechar
                        M-S-deletechar C-M-S-deletechar))
          (bind (vector key)))
        ;; Bind these non-encodable keys.  They are translated.
        (dolist (key '(?\C-- ?\C-? ?\C-\s))
          (bind (vector key)))
        ;; Bind M-<ASCII> keys.
        (unless (member (vector meta-prefix-char) exceptions)
          (define-key map (vector meta-prefix-char)
                      (make-sparse-keymap))
          (cl-loop
           for i from ?\C-@ to ?\C-?
           do (unless (memq i '(?O ?\[))
                (bind (vector meta-prefix-char i))))
          (bind (vector meta-prefix-char meta-prefix-char))))
      (when (memq :arrow categories)
        (dolist (key '( up down right left
                        C-up C-down C-right C-left
                        M-up M-down M-right M-left
                        S-up S-down S-right S-left
                        C-M-up C-M-down C-M-right C-M-left
                        C-S-up C-S-down C-S-right C-S-left
                        M-S-up M-S-down M-S-right M-S-left
                        C-M-S-up C-M-S-down C-M-S-right C-M-S-left))
          (bind (vector key))))
      (when (memq :navigation categories)
        (dolist (key '( home C-home M-home S-home C-M-home C-S-home
                        M-S-home C-M-S-home
                        end C-end M-end S-end C-M-end C-S-end
                        M-S-end C-M-S-end
                        prior C-prior M-prior S-prior C-M-prior
                        C-S-prior M-S-prior C-M-S-prior
                        next C-next M-next S-next C-M-next C-S-next
                        M-S-next C-M-S-next))
          (bind (vector key))))
      (when (memq :function categories)
        (cl-loop
         for i from 1 to 63
         do (let ((key (intern (format "f%i" i))))
              (bind (vector key)))))
    map)))


(defun eat-term-filter-string (string)
  "Filter Eat's special text properties from STRING."
  (with-temp-buffer
    (insert string)
    ;; Join long lines.
    (goto-char (point-min))
    (while (not (eobp))
      (eat--t-join-long-line))
    ;; Remove the invisible spaces used with multi-column characters.
    (goto-char (point-min))
    (while (not (eobp))
      (let ((invisible-p (get-text-property
                          (point) 'eat--t-invisible-space))
            (next-change (or (next-single-property-change
                              (point) 'eat--t-invisible-space)
                             (point-max))))
        (when invisible-p
          (delete-region (point) next-change))
        (goto-char next-change)))
    (remove-text-properties (point-min) (point-max)
                            '( eat--t-char-width nil))
    (buffer-string)))


;;;; User Interface.

(defvar eat-terminal nil
  "The terminal emulator.")

(defvar-local eat--process nil
  "The subprocess associated with current Eat buffer.")

(defvar eat--synchronize-scroll-function nil
  "Function to synchronize scrolling between terminal and window.")


(defun eat-reset ()
  "Perform a terminal reset."
  (interactive)
  (when eat-terminal
    (let ((inhibit-read-only t))
      (eat-term-reset eat-terminal)
      (eat-term-redisplay eat-terminal))
    (run-hooks 'eat-update-hook)))

(defun eat--set-cursor (_ state)
  "Set cursor type according to STATE.

STATE can be one of the following:

  `:invisible'          Invisible cursor.
  `:block'              Block (filled box) cursor (default).
  `:blinking-block'     Very visible block cursor.
  `:bar'                Vertical bar cursor.
  `:blinking-bar'       Very visible vertical bar cursor.
  `:underline'          Horizontal bar cursor.
  `:blinking-underline' Very visible horizontal bar cursor.
  Any other value         Block cursor."
  (setq-local cursor-type
              (pcase state
                (:invisible eat-invisible-cursor-type)
                (:block eat-default-cursor-type)
                (:blinking-block eat-very-visible-cursor-type)
                (:bar eat-vertical-bar-cursor-type)
                (:blinking-bar eat-very-visible-vertical-bar-cursor-type)
                (:underline eat-horizontal-bar-cursor-type)
                (:blinking-underline
                 eat-very-visible-horizontal-bar-cursor-type)
                (_ eat-default-cursor-type))))

(defun eat--manipulate-kill-ring (_ selection data)
  "Manipulate `kill-ring'.

SELECTION can be one of `:clipboard', `:primary', `:secondary',
`:select'.  When DATA is a string, set the selection to that string,
when DATA is nil, unset the selection, and when DATA is t, return the
selection, or nil if none."
  (let ((inhibit-eol-conversion t)
        (select-enable-clipboard (eq selection :clipboard))
        (select-enable-primary (eq selection :primary)))
    (pcase-exhaustive data
      ('t
       (when eat-enable-yank-to-terminal
         (ignore-error error
           (current-kill 0 'do-not-move))))
      ('nil
       (when eat-enable-kill-from-terminal
         (kill-new "")))
      ((and (pred stringp) str)
       (when eat-enable-kill-from-terminal
         (kill-new str))))))

(defun eat--bell (_)
  "Ring the bell."
  (ding t))

(defvar eat--char-mode)

(defun eat--handle-message (name &rest args)
  "Handle message with handler name NAME and ARGS."
  (when-let* ((name (ignore-errors (decode-coding-string
                                    (base64-decode-string name)
                                    locale-coding-system)))
              (handler (assoc name eat-message-handler-alist)))
    (save-restriction
      (widen)
      (save-excursion
        (apply (cdr handler)
               (mapcar (lambda (arg)
                         (ignore-errors (decode-coding-string
                                         (base64-decode-string arg)
                                         locale-coding-system)))
                       args))))))

(defun eat--handle-uic (_ cmd)
  "Handle UI Command sequence CMD."
  (pcase cmd
    ;; In XTerm, OSC 51 is reserved for Emacs shell.  I have no idea
    ;; why, but Vterm uses this OSC to set the current directory and
    ;; remotely execute Emacs Lisp code.  Vterm uses the characters
    ;; 'A' and 'E' as the first character of second parameter of this
    ;; OSC.  We use 'e' as the second parameter, followed by one or
    ;; more parameters.
    ;; UIC e ; M ; ... ST.
    ((rx string-start "e;M;"
         (let msg (zero-or-more anything))
         string-end)
     (apply #'eat--handle-message (string-split msg ";")))))


;;;;; Input.


(defun eat-self-input (n &optional e)
  "Send E as input N times.

N defaults to 1 and E defaults to `last-command-event' and should be a
event."
  (interactive
   (list (prefix-numeric-value current-prefix-arg)
         (if (and (> (length (this-command-keys)) 1)
                  (eq (aref (this-command-keys)
                            (- (length (this-command-keys)) 2))
                      meta-prefix-char))
             ;; HACK: Capture meta modifier (ESC prefix) in terminal.
             (cond
              ((eq last-command-event meta-prefix-char)
               last-command-event)
              ((characterp last-command-event)
               (aref
                (kbd (format "M-%c" last-command-event))
                0))
              ((symbolp last-command-event)
               (aref
                (kbd (format "M-<%S>" last-command-event))
                0))
              (t
               last-command-event))
           last-command-event)))
  (when eat-terminal
    (funcall eat--synchronize-scroll-function
             (eat--synchronize-scroll-windows 'force-selected))
    (eat-term-input-event eat-terminal n e)))

(defun eat-quoted-input ()
  "Read a character and send it as INPUT."
  (declare (interactive-only "Use `eat-self-input' instead."))
  (interactive)
  ;; HACK: Quick hack to allow inputting `C-g'.  Any better way to do
  ;; this?
  (eat-self-input
   1 (let ((inhibit-quit t)
           ;; Don't trigger `quit' exiting this `let'.
           (quit-flag nil))
       (read-event))))

(defun eat-input-char (character count)
  "Input CHARACTER, COUNT times.

Interactively, ask for the character CHARACTER to input.  The numeric prefix
argument COUNT specifies how many times to insert CHARACTER."
  (declare (interactive-only "Use `eat-self-input' instead."))
  (interactive (list (read-char-by-name
                      "Insert character (Unicode name or hex): ")
                     (prefix-numeric-value current-prefix-arg)))
  (eat-self-input count character))

(defvar yank-transform-functions) ; In `simple'.

(defun eat-yank (&optional arg)
  "Same as `yank', but for Eat.

ARG is passed to `yank', which see."
  (interactive "*P")
  (when eat-terminal
    (funcall eat--synchronize-scroll-function
             (eat--synchronize-scroll-windows 'force-selected))
    (eat-term-send-string-as-yank
     eat-terminal
     (let ((yank-hook (bound-and-true-p yank-transform-functions)))
       (with-temp-buffer
         (setq-local yank-transform-functions yank-hook)
         (yank arg)
         (buffer-string))))))

(defun eat-yank-from-kill-ring (string &optional arg)
  "Same as `yank-from-kill-ring', but for Eat.

STRING and ARG are passed to `yank-pop', which see."
  (interactive
   (progn
     (unless (eval-when-compile (>= emacs-major-version 28))
       (error "`eat-yank-from-kill-ring' requires at least Emacs 28"))
     (list (read-from-kill-ring "Yank from kill-ring: ")
           current-prefix-arg)))
  (unless (eval-when-compile (>= emacs-major-version 28))
    (error "`eat-yank-from-kill-ring' requires at least Emacs 28"))
  (when eat-terminal
    (funcall eat--synchronize-scroll-function
             (eat--synchronize-scroll-windows 'force-selected))
    (eat-term-send-string-as-yank
     eat-terminal
     (let ((yank-hook (bound-and-true-p yank-transform-functions)))
       (with-temp-buffer
         (setq-local yank-transform-functions yank-hook)
         (yank-from-kill-ring string arg)
         (buffer-string))))))


(defun eat-xterm-paste (event)
  "Handle paste operation EVENT from XTerm."
  (interactive "e")
  (unless (eq (car-safe event) 'xterm-paste)
    (error "`eat-xterm-paste' must be bind to `xterm-paste' event"))
  (let ((pasted-text (nth 1 event)))
    (if (bound-and-true-p xterm-store-paste-on-kill-ring)
        ;; Put the text onto the kill ring and then insert it into the
        ;; buffer.
        (let ((interprogram-paste-function (lambda () pasted-text)))
          (eat-yank))
      ;; Insert the text without putting it onto the kill ring.
      (eat-term-send-string-as-yank eat-terminal pasted-text))))

(defun eat-send-password ()
  "Read password from minibuffer and send it to the terminal."
  (declare (interactive-only t))
  (interactive)
  (unless eat-terminal
    (user-error "Process not running"))
  (eat-term-send-string eat-terminal (read-passwd "Password: "))
  (eat-self-input 1 'return))


;; When changing these keymaps, be sure to update the manual, README
;; and commentary.
(defvar eat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [?\C-c ?\M-d] #'eat-char-mode)
    (define-key map [?\C-c ?\C-e] #'eat-emacs-mode)
    (define-key map [?\C-c ?\C-k] #'eat-kill-process)
    (define-key map [xterm-paste] #'ignore)
    map)
  "Keymap for Eat mode.")

(defvar eat-char-mode-map
  (let ((map (eat-term-make-keymap
              #'eat-self-input '(:ascii :arrow :navigation :function)
              '([?\e ?\C-m] [?\C-c]))))
    (define-key map [?\C-\M-m] #'eat-emacs-mode)
    (define-key map [?\C-c ?\C-e] #'eat-emacs-mode)
    (define-key map [xterm-paste] #'eat-xterm-paste)
    map)
  "Keymap for Eat char mode.")

(define-minor-mode eat--char-mode
  "Minor mode implementing Eat char mode."
  :init-value nil
  :lighter nil
  :keymap eat-char-mode-map)

(defun eat-emacs-mode ()
  "Switch to Emacs keybindings mode."
  (interactive)
  (eat--char-mode -1)
  (setq buffer-read-only t)
  (force-mode-line-update))

(defun eat-char-mode ()
  "Switch to char mode."
  (interactive)
  (unless eat-terminal
    (error "Process not running"))
  (setq buffer-read-only nil)
  (eat--char-mode +1)
  (force-mode-line-update))




;;;;; Major Mode.

(defun eat--synchronize-scroll-windows (&optional force-selected)
  "Return the list of windows whose scrolling should be synchronized.

When FORCE-SELECTED is non-nil, always include `buffer' and the
selected window in the list if the window is showing the current
buffer."
  `(,@(and (or force-selected
               eat--char-mode
               (= (eat-term-display-cursor eat-terminal) (point)))
           '(buffer))
    ,@(seq-filter
       (lambda (window)
         (or (and force-selected (eq window (selected-window)))
             (= (eat-term-display-cursor eat-terminal)
                (window-point window))))
       (get-buffer-window-list))))

(defun eat--synchronize-scroll (windows)
  "Synchronize scrolling and point between terminal and WINDOWS.

WINDOWS is a list of windows.  WINDOWS may also contain the special
symbol `buffer', in which case the point of current buffer is set."
  (dolist (window windows)
    (if (eq window 'buffer)
        (goto-char (eat-term-display-cursor eat-terminal))
      (with-selected-window window
        (set-window-point nil (eat-term-display-cursor eat-terminal))
        (recenter
         (- (how-many "\n" (eat-term-display-beginning eat-terminal)
                      (eat-term-display-cursor eat-terminal))
            (cdr (eat-term-size eat-terminal))
            (max 0 (- (floor (window-screen-lines))
                      (cdr (eat-term-size eat-terminal))))))))))

(defun eat--setup-glyphless-chars ()
  "Setup the display of glyphless characters."
  (setq-local glyphless-char-display
              (copy-sequence (default-value 'glyphless-char-display)))
  (set-char-table-extra-slot
   glyphless-char-display 0
   (if (display-graphic-p) 'empty-box 'thin-space)))

(defun eat--filter-buffer-substring (begin end &optional delete)
  "Filter buffer substring from BEGIN to END and return that.

When DELETE is given and non-nil, delete the text between BEGIN and
END if it's safe to do so."
  (let ((str (buffer-substring begin end)))
    (remove-text-properties 0 (length str)
                            '( read-only nil
                               rear-nonsticky nil
                               front-sticky nil
                               field nil)
                            str)
    (setq str (eat-term-filter-string str))
    (when (and delete
               (or (not eat-terminal)
                   (and (<= (eat-term-end eat-terminal) begin)
                        (<= (eat-term-end eat-terminal) end))
                   (and (<= begin (eat-term-beginning eat-terminal))
                        (<= end (eat-term-beginning eat-terminal)))))
      (delete-region begin end))
    str))

(define-derived-mode eat-mode fundamental-mode "Eat"
  "Major mode for Eat."
  :group 'eat-ui
  (mapc #'make-local-variable
        '(buffer-read-only
          buffer-undo-list
          filter-buffer-substring-function
          mode-line-process
          mode-line-buffer-identification
          glyphless-char-display
          cursor-type
          scroll-margin
          hscroll-margin
          eat-terminal
          eat--synchronize-scroll-function
          eat--pending-output-chunks
          eat--output-queue-first-chunk-time
          eat--process-output-queue-timer))
  ;; This is intended; input methods don't work on read-only buffers.
  (setq buffer-read-only nil)
  (setq scroll-margin 0)
  (setq hscroll-margin 0)
  (setq eat--synchronize-scroll-function #'eat--synchronize-scroll)
  (setq filter-buffer-substring-function
        #'eat--filter-buffer-substring)
  (setq bidi-paragraph-direction 'left-to-right)
  (setq mode-line-process
        '(""
          (:eval
           (when eat-terminal
             (if eat--char-mode
                 "[char]"
               "[emacs]")))
          ":%s"))
  (when eat-show-title-on-mode-line
    (setq mode-line-buffer-identification
          `(12 (""
                ,(nconc
                  (propertized-buffer-identification "%b")
                  '(" "
                    (:propertize
                     (:eval
                      (when-let*
                          ((eat-terminal)
                           (title (eat-term-title eat-terminal))
                           ((not (string-empty-p title))))
                        (format "(%s)" (string-replace "%" "%%"
                                                       title))))
                     help-echo "Title")))))))
  (eat-emacs-mode)
  ;; Make sure glyphless character don't display a huge box glyph,
  ;; that would break the display.
  (eat--setup-glyphless-chars))


;;;;; Process Handling.

(defvar eat--pending-output-chunks nil
  "The list of pending output chunks.

The output chunks are pushed, so last output appears first.")

(defvar eat--output-queue-first-chunk-time nil
  "Time when the first chunk in the current output queue was pushed.")

(defvar eat--process-output-queue-timer nil
  "Timer to process output queue.")

(defun eat-kill-process ()
  "Kill Eat process in current buffer."
  (interactive)
  (when-let* ((eat-terminal)
              (proc eat--process))
    (delete-process proc)))

(defun eat--send-string (process string)
  "Send to PROCESS the contents of STRING as input.

This is equivalent to `process-send-string', except that long input
strings are broken up into chunks of size `eat-input-chunk-size'.
Processes are given a chance to output between chunks.  This can help
prevent processes from hanging when you send them long inputs on some
OS's."
  (let ((i 0)
        (j eat-input-chunk-size)
        (l (length string)))
    (while (< i l)
      (process-send-string process (substring string i (min j l)))
      (accept-process-output)
      (cl-incf i eat-input-chunk-size)
      (cl-incf j eat-input-chunk-size))))

(defun eat--send-input (_ input)
  "Send INPUT to subprocess."
  (when-let* ((eat-terminal)
              (proc eat--process))
    (eat--send-string proc input)))

(defun eat--process-output-queue (buffer)
  "Process the output queue on BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-quit t)        ; Don't disturb!
            (sync-windows (eat--synchronize-scroll-windows))
            (eat--auto-line-mode-pending-toggles nil))
        (save-restriction
          (widen)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                ;; Don't let `undo' mess up with the terminal.
                (buffer-undo-list t))
            (when eat--process-output-queue-timer
              (cancel-timer eat--process-output-queue-timer))
            (setq eat--output-queue-first-chunk-time nil)
            (while eat--pending-output-chunks
              (let ((queue eat--pending-output-chunks)
                    (eat--output-queue-first-chunk-time t))
                (setq eat--pending-output-chunks nil)
                (dolist (output (nreverse queue))
                  (eat-term-process-output eat-terminal output))))
            (eat-term-redisplay eat-terminal)
            ;; Truncate output of previous dead processes.
            (when (and eat-term-scrollback-size
                       (< eat-term-scrollback-size
                          (- (point) (point-min))))
              (delete-region
               (point-min)
               (max (point-min)
                    (- (eat-term-display-beginning eat-terminal)
                       eat-term-scrollback-size))))
            (add-text-properties
             (eat-term-beginning eat-terminal)
             (eat-term-end eat-terminal)
             '(read-only t field eat-terminal)))
        (funcall eat--synchronize-scroll-function sync-windows))
      (run-hooks 'eat-update-hook)))))

(defun eat--filter (process output)
  "Handle OUTPUT from PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when eat--process-output-queue-timer
        (cancel-timer eat--process-output-queue-timer))
      (unless eat--output-queue-first-chunk-time
        (setq eat--output-queue-first-chunk-time (current-time)))
      (push output eat--pending-output-chunks)
      (unless (eq eat--output-queue-first-chunk-time t)
        (let ((time-left
               (- eat-maximum-latency
                  (float-time
                   (time-subtract
                    nil eat--output-queue-first-chunk-time)))))
          (if (<= time-left 0)
              (eat--process-output-queue (current-buffer))
            (setq eat--process-output-queue-timer
                  (run-with-timer
                   (min time-left eat-minimum-latency) nil
                   #'eat--process-output-queue
                   (current-buffer)))))))))

(defun eat--sentinel (process message)
  "Sentinel for Eat buffers.

PROCESS is the process and MESSAGE is the description of what happened
to it."
  (let ((buffer (process-buffer process)))
    (when (memq (process-status process) '(signal exit))
      (if (buffer-live-p buffer)
          (with-current-buffer buffer
            (let ((inhibit-read-only t)
                  ;; We're is going to write outside of the terminal,
                  ;; so we won't synchronize buffer scroll here as we
                  ;; will set the buffer point automatically by
                  ;; writing to the buffer.
                  (eat--synchronize-scroll-function #'ignore))
              (when eat--process-output-queue-timer
                (cancel-timer eat--process-output-queue-timer)
                (setq eat--process-output-queue-timer nil))
              (eat--process-output-queue buffer)
              (eat-emacs-mode)
              (remove-text-properties
               (eat-term-beginning eat-terminal)
               (eat-term-end eat-terminal)
               '(read-only nil field nil))
              (eat-term-delete eat-terminal)
              (setq eat-terminal nil)
              (eat--set-cursor nil :default)
              (goto-char (point-max))
              (insert "\nProcess " (process-name process) " "
                      message)
              (setq buffer-read-only nil))
            (run-hook-with-args 'eat-exit-hook process)
            (delete-process process))
        (set-process-buffer process nil)))))

(defun eat--adjust-process-window-size (process windows)
  "Resize process window and terminal.  Return new dimensions.

PROCESS is the process whose window to resize, and WINDOWS is the list
of window displaying PROCESS's buffer."
  (let ((size (funcall window-adjust-process-window-size-function
                       process windows)))
    (when size
      (let ((width (max (car size) 1))
            (height (max (cdr size) 1))
            (inhibit-read-only t)
            (sync-windows (eat--synchronize-scroll-windows)))
        (eat-term-resize eat-terminal width height)
        (eat-term-redisplay eat-terminal)
        (funcall eat--synchronize-scroll-function sync-windows))
      (when (eq major-mode #'eat-mode)
        (run-hooks 'eat-update-hook)))
    size))

(defun eat--kill-buffer (_process)
  "Kill current buffer."
  (kill-buffer (current-buffer)))

;; Adapted from Term.
(defun eat-exec (buffer name command startfile switches)
  "Start up a process in BUFFER for Eat mode.

Run COMMAND with SWITCHES.  Set NAME as the name of the process.
Blast any old process running in the buffer.  Don't set the buffer
mode.  You can use this to cheaply run a series of processes in the
same Eat buffer.  The hook `eat-exec-hook' is run after each exec."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (when-let* ((eat-terminal)
                  (proc eat--process))
        (remove-hook 'eat-exit-hook #'eat--kill-buffer t)
        (delete-process proc))
      ;; Ensure final newline.
      (goto-char (point-max))
      (unless (or (= (point-min) (point-max))
                  (= (char-before (point-max)) ?\n))
        (insert ?\n))
      (unless (= (point-min) (point-max))
        (insert "\n\n"))
      (setq eat-terminal (eat-term-make buffer (point)))
      (eat-char-mode)
      (when-let* ((window (get-buffer-window nil t)))
        (with-selected-window window
          (eat-term-resize eat-terminal (window-max-chars-per-line)
                           (floor (window-screen-lines)))))
      ;; Crank up a new process.
      (let* ((size (eat-term-size eat-terminal))
             (process-environment
              (nconc
               (list
                (concat "TERM=" eat-term-name)
                (concat "INSIDE_EMACS=" eat-term-inside-emacs))
               process-environment))
             (process-connection-type t)
             ;; We should suppress conversion of end-of-line format.
             (inhibit-eol-conversion t)
             (process
              (make-process
               :name name
               :buffer buffer
               :command `("/usr/bin/env" "sh" "-c"
                          ,(format "stty -nl echo rows %d columns \
%d sane 2>%s ; if [ $1 = .. ]; then shift; fi; exec \"$@\""
                                   (cdr size) (car size)
                                   null-device)
                          ".."
                          ,command ,@switches)
               :filter #'eat--filter
               :sentinel #'eat--sentinel
               :file-handler t)))
        (process-put process 'adjust-window-size-function
                     #'eat--adjust-process-window-size)
        (set-process-query-on-exit-flag
         process eat-query-before-killing-running-terminal)
        ;; Jump to the end, and set the process mark.
        (goto-char (point-max))
        (set-marker (process-mark process) (point))
        (setq eat--process process)
        (when eat-kill-buffer-on-exit
          (add-hook 'eat-exit-hook #'eat--kill-buffer 90 t))
        ;; Feed it the startfile.
        (when startfile
          ;; This is guaranteed to wait long enough
          ;; but has bad results if the shell does not prompt at all
          ;;          (while (= size (buffer-size))
          ;;            (sleep-for 1))
          ;; I hope 1 second is enough!
          (sleep-for 1)
          (goto-char (point-max))
          (insert-file-contents startfile)
          (process-send-string
           process (delete-and-extract-region (point) (point-max)))))
      (eat-term-redisplay eat-terminal))
    (run-hook-with-args 'eat-exec-hook eat--process)
    buffer))


;;;;; Entry Points.

(defun eat-make (name program &optional startfile &rest switches)
  "Make a Eat process NAME in a buffer, running PROGRAM.

The name of the buffer is made by surrounding NAME with `*'s.  If
there is already a running process in that buffer, it is not
restarted.  Optional third arg STARTFILE is the name of a file to send
the contents of to the process.  SWITCHES are the arguments to
PROGRAM."
  (let ((buffer (get-buffer-create (concat "*" name "*"))))
    ;; If no process, or nuked process, crank up a new one and put
    ;; buffer in Eat mode.  Otherwise, leave buffer and existing
    ;; process alone.
    (when (not (let ((proc (get-buffer-process buffer)))
                 (and proc (memq (process-status proc)
                                 '(run stop open listen connect)))))
      (with-current-buffer buffer
        (eat-mode))
      (eat-exec buffer name program startfile switches))
    buffer))

(defun eat-default-shell ()
  "Return a shell to run."
  (or (and (file-remote-p default-directory)
           (with-parsed-tramp-file-name default-directory nil
             (alist-get method eat-tramp-shells nil nil 'equal)))
      eat-shell))

(defun eat--1 (program arg display-buffer-fn)
  "Start a new Eat terminal emulator in a buffer.

PROGRAM and ARG is same as in `eat'.
DISPLAY-BUFFER-FN is the function to display the buffer."
  (let ((program (or program (funcall eat-default-shell-function)))
        (buffer
         (cond
          ((numberp arg)
           (get-buffer-create (format "%s<%d>" eat-buffer-name arg)))
          (arg
           (generate-new-buffer eat-buffer-name))
          (t
           (get-buffer-create eat-buffer-name)))))
    (with-current-buffer buffer
      (unless (eq major-mode #'eat-mode)
        (eat-mode))
      (funcall display-buffer-fn buffer)
      (unless (and eat-terminal
                   eat--process)
        (eat-exec buffer (buffer-name) "/usr/bin/env" nil
                  (list "sh" "-c" program)))
      buffer)))

;;;###autoload
(defun eat (&optional program arg)
  "Start a new Eat terminal emulator in a buffer.

Start a new Eat session, or switch to an already active session.
Return the buffer selected (or created).

With a non-numeric prefix ARG, create a new session.

With a numeric prefix ARG (like \\[universal-argument] 42 \\[eat]),
switch to the session with that number, or create it if it doesn't
already exist.

With double prefix argument ARG, ask for the program to run and run it
in a newly created session.

PROGRAM can be a shell command."
  (interactive
   (list (when (equal current-prefix-arg '(16))
           (read-shell-command "Run program: "
                               (funcall eat-default-shell-function)))
         current-prefix-arg))
  (eat--1 program arg #'pop-to-buffer-same-window))


;;;; Miscellaneous.


;;;; Footer.

(provide 'eat)
;;; eat.el ends here
