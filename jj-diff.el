;;; jj-diff.el --- Magit-like diff and hunk marking for Jujutsu -*- lexical-binding: t; -*-

;; Author: ccQpein
;; Keywords: vc, tools, jujutsu
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; `jj-diff.el` provides an interactive diff buffer (`jj-diff-mode`) for Jujutsu (jj)
;; repositories.  It allows viewing working copy changes, marking individual
;; lines, regions, hunks, or files, and non-interactively committing marked
;; changes using `jj split` without external dependencies beyond Emacs and jj.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;; Customization & Faces

(defgroup jj-diff nil
  "Interactive Jujutsu diff and split mode."
  :group 'tools
  :prefix "jj-diff-")

(defcustom jj-diff-executable "jj"
  "The Jujutsu executable name or path."
  :type 'string
  :group 'jj-diff)

(defcustom jj-diff-emacs-executable
  (expand-file-name invocation-name invocation-directory)
  "The Emacs executable used to run the split diff-editor backend."
  :type 'string
  :group 'jj-diff)

(defface jj-diff-file-header
  '((((class color) (background dark))
     :foreground "#7aa2f7" :weight bold :extend t)
    (((class color) (background light))
     :foreground "#2e5cc9" :weight bold :extend t)
    (t :weight bold))
  "Face used for file headers in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-hunk-header
  '((((class color) (background dark))
     :foreground "#bb9af7" :background "#24283b" :weight semi-bold :extend t)
    (((class color) (background light))
     :foreground "#8c4351" :background "#eef1f8" :weight semi-bold :extend t)
    (t :weight semi-bold))
  "Face used for hunk headers (@@ ... @@) in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-addition
  '((((class color) (background dark))
     :foreground "#9ece6a" :background "#1f2d26" :extend t)
    (((class color) (background light))
     :foreground "#1e873b" :background "#e6f4ea" :extend t)
    (t :foreground "green"))
  "Face used for added lines in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-deletion
  '((((class color) (background dark))
     :foreground "#f7768e" :background "#37222c" :extend t)
    (((class color) (background light))
     :foreground "#c92a2a" :background "#fce8e8" :extend t)
    (t :foreground "red"))
  "Face used for deleted lines in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-context
  '((t :inherit default))
  "Face used for context lines in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-marked
  '((((class color) (background dark))
     :background "#1e3a5f" :weight bold :extend t)
    (((class color) (background light))
     :background "#d0e2ff" :weight bold :extend t)
    (t :inverse-video t))
  "Face used for marked/selected lines in `jj-diff-mode`."
  :group 'jj-diff)

(put 'jj-diff-staged 'face-alias 'jj-diff-marked)

(defface jj-diff-marked-fringe
  '((((class color) (background dark))
     :foreground "#7aa2f7" :weight bold)
    (((class color) (background light))
     :foreground "#00539c" :weight bold)
    (t :weight bold))
  "Face used for the fringe indicator of marked lines."
  :group 'jj-diff)

(put 'jj-diff-staged-fringe 'face-alias 'jj-diff-marked-fringe)

(defface jj-diff-partial
  '((((class color) (background dark))
     :foreground "#e0af68" :weight bold)
    (((class color) (background light))
     :foreground "#b07d12" :weight bold)
    (t :weight bold))
  "Face used for partially marked indicators on headers in `jj-diff-mode`."
  :group 'jj-diff)

(defface jj-diff-meta-header
  '((((class color) (background dark))
     :foreground "#565f89" :slant italic)
    (((class color) (background light))
     :foreground "#6e7781" :slant italic)
    (t :slant italic))
  "Face used for diff metadata lines (index, diff --git, etc.)."
  :group 'jj-diff)

(defface jj-diff-status-bar
  '((((class color) (background dark))
     :background "#1a1b26" :foreground "#c0caf5" :weight bold :extend t)
    (((class color) (background light))
     :background "#e1e4e8" :foreground "#24292e" :weight bold :extend t)
    (t :weight bold))
  "Face used for status bar header in `jj-diff-mode`."
  :group 'jj-diff)

;;; Data Structures

(cl-defstruct (jj-diff-file (:constructor jj-diff-file-create))
  old-path
  new-path
  is-new
  is-deleted
  meta-lines
  hunks
  beg-pos
  end-pos
  header-overlay)

(cl-defstruct (jj-diff-hunk (:constructor jj-diff-hunk-create))
  file
  header
  old-start
  old-count
  new-start
  new-count
  lines
  beg-pos
  end-pos
  body-beg-pos
  body-end-pos
  fold-overlay
  header-overlay)

(cl-defstruct (jj-diff-line (:constructor jj-diff-line-create))
  hunk
  type      ; :context, :add, :del
  text      ; original text without newline
  marked    ; t or nil
  beg-pos
  end-pos
  overlay)

;;; Buffer-local Variables

(defvar-local jj-diff--repo-root nil
  "Root directory of the current Jujutsu repository.")

(defvar-local jj-diff--revision "@"
  "The revision being inspected / split.")

(defvar-local jj-diff--files nil
  "List of `jj-diff-file' structs currently displayed.")

(defvar-local jj-diff--all-lines nil
  "Flat list of all `jj-diff-line' structs in the buffer.")

(defvar-local jj-diff--source-buffer nil
  "The originating `jj-diff` buffer when in commit description buffer.")

;;; Jujutsu Command Helpers

(defun jj-diff--find-repo-root (&optional dir)
  "Find the Jujutsu repository root for DIR (or `default-directory`).
Traverses parent directories to locate the closest `.jj` directory,
or queries `jj root` from DIR."
  (let* ((search-dir (file-name-as-directory
                      (expand-file-name (or dir default-directory))))
         (dom-dir (locate-dominating-file search-dir ".jj")))
    (if dom-dir
        (directory-file-name (expand-file-name dom-dir))
      ;; Fallback to running jj root with default-directory set to search-dir
      (let ((default-directory search-dir))
        (with-temp-buffer
          (when (zerop (call-process jj-diff-executable nil t nil "root"))
            (string-trim (buffer-string))))))))

(defun jj-diff--run-command (args &optional dir)
  "Run `jj` with ARGS synchronously in DIR. Return stdout as a string or error."
  (let ((default-directory (or dir default-directory)))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process jj-diff-executable nil (list t t) nil args)))
        (if (zerop exit-code)
            (buffer-string)
          (error "jj command failed (%d):\njj %s\n\n%s"
                 exit-code
                 (mapconcat #'identity args " ")
                 (buffer-string)))))))

;;; Diff Parser

(defun jj-diff--parse-unified-diff (diff-text)
  "Parse raw unified DIFF-TEXT into a list of `jj-diff-file' structs."
  (let ((lines (split-string diff-text "\n" nil))
        (files nil)
        (current-file nil)
        (current-hunk nil))
    (dolist (line lines)
      (cond
       ;; Start of a file diff: "diff --git a/... b/..."
       ((string-match "^diff --git a/\\(.*\\) b/\\(.*\\)$" line)
        (setq current-hunk nil)
        (setq current-file (jj-diff-file-create
                            :old-path (match-string 1 line)
                            :new-path (match-string 2 line)
                            :meta-lines (list line)
                            :hunks nil))
        (push current-file files))

       ;; Check for new file / deleted file modes
       ((and current-file (string-match "^new file mode" line))
        (setf (jj-diff-file-is-new current-file) t)
        (push line (jj-diff-file-meta-lines current-file)))

       ((and current-file (string-match "^deleted file mode" line))
        (setf (jj-diff-file-is-deleted current-file) t)
        (push line (jj-diff-file-meta-lines current-file)))

       ;; Other header metadata lines: --- or +++ or index ...
       ((and current-file
             (not current-hunk)
             (or (string-prefix-p "index " line)
                 (string-prefix-p "--- " line)
                 (string-prefix-p "+++ " line)
                 (string-prefix-p "old mode" line)
                 (string-prefix-p "new mode" line)))
        (push line (jj-diff-file-meta-lines current-file)))

       ;; Start of a hunk: "@@ -old_start,old_count +new_start,new_count @@"
       ((string-match "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)$" line)
        (let* ((old-start (string-to-number (match-string 1 line)))
               (old-count (if (match-string 2 line)
                              (string-to-number (match-string 2 line))
                            1))
               (new-start (string-to-number (match-string 3 line)))
               (new-count (if (match-string 4 line)
                              (string-to-number (match-string 4 line))
                            1))
               (hunk (jj-diff-hunk-create
                      :file current-file
                      :header line
                      :old-start old-start
                      :old-count old-count
                      :new-start new-start
                      :new-count new-count
                      :lines nil)))
          (setq current-hunk hunk)
          (when current-file
            (setf (jj-diff-file-hunks current-file)
                  (append (jj-diff-file-hunks current-file) (list hunk))))))

       ;; Content lines inside a hunk
       ((and current-hunk
             (or (string-prefix-p "+" line)
                 (string-prefix-p "-" line)
                 (string-prefix-p " " line)
                 (string-prefix-p "\\" line)))
        (let* ((prefix (substring line 0 1))
               (type (cond
                      ((string= prefix "+") :add)
                      ((string= prefix "-") :del)
                      (t :context))))
          (let ((diff-line (jj-diff-line-create
                            :hunk current-hunk
                            :type type
                            :text line
                            :marked nil)))
            (setf (jj-diff-hunk-lines current-hunk)
                  (append (jj-diff-hunk-lines current-hunk) (list diff-line))))))))
    (nreverse files)))

;;; Buffer Rendering

(defun jj-diff--render-buffer ()
  "Render `jj-diff--files` in the current buffer with faces and interactive overlays."
  (let ((inhibit-read-only t)
        (orig-point (point))
        (all-lines nil))
    (erase-buffer)
    ;; Remove all existing overlays
    (remove-overlays (point-min) (point-max))

    ;; Header info
    (insert (propertize (format " Jujutsu Working Copy Diff (%s)\n" jj-diff--revision)
                        'face 'jj-diff-status-bar))
    (insert (propertize (format " Repository: %s\n" jj-diff--repo-root)
                        'face 'jj-diff-meta-header))
    (insert (propertize " [m/s] Mark  [u] Unmark  [M/S] Mark All  [U] Unmark All  [TAB] Fold  [S-TAB] Fold All  [c] Commit  [g] Refresh  [q] Quit\n\n"
                        'face 'jj-diff-meta-header))

    (if (null jj-diff--files)
        (insert (propertize " No working copy changes.\n" 'face 'italic))
      (dolist (file jj-diff--files)
        (setf (jj-diff-file-beg-pos file) (point))
        ;; File header
        (let ((file-header-start (point)))
          (insert (format "modified %s\n" (jj-diff-file-new-path file)))
          (put-text-property file-header-start (point) 'face 'jj-diff-file-header)
          (put-text-property file-header-start (point) 'jj-diff-file file)
          (let ((ov (make-overlay file-header-start (1- (point)))))
            (overlay-put ov 'jj-diff-file file)
            (setf (jj-diff-file-header-overlay file) ov)))

        ;; Hunks
        (dolist (hunk (jj-diff-file-hunks file))
          (setf (jj-diff-hunk-beg-pos hunk) (point))
          ;; Hunk header
          (let ((hunk-header-start (point)))
            (insert (format "%s\n" (jj-diff-hunk-header hunk)))
            (put-text-property hunk-header-start (point) 'face 'jj-diff-hunk-header)
            (put-text-property hunk-header-start (point) 'jj-diff-hunk hunk)
            (put-text-property hunk-header-start (point) 'jj-diff-file file)
            (let ((ov (make-overlay hunk-header-start (1- (point)))))
              (overlay-put ov 'jj-diff-hunk hunk)
              (setf (jj-diff-hunk-header-overlay hunk) ov)))

          ;; Lines
          (setf (jj-diff-hunk-body-beg-pos hunk) (point))
          (dolist (line (jj-diff-hunk-lines hunk))
            (let ((line-start (point)))
              (insert (format "%s\n" (jj-diff-line-text line)))
              (let ((line-end (point)))
                (setf (jj-diff-line-beg-pos line) line-start)
                (setf (jj-diff-line-end-pos line) line-end)
                (put-text-property line-start line-end 'jj-diff-line line)
                (put-text-property line-start line-end 'jj-diff-hunk hunk)
                (put-text-property line-start line-end 'jj-diff-file file)

                ;; Base face
                (let ((base-face (cl-case (jj-diff-line-type line)
                                   (:add 'jj-diff-addition)
                                   (:del 'jj-diff-deletion)
                                   (t 'jj-diff-context))))
                  (put-text-property line-start line-end 'face base-face))

                ;; Create overlay for marking highlights
                (let ((ov (make-overlay line-start line-end)))
                  (overlay-put ov 'jj-diff-line line)
                  (setf (jj-diff-line-overlay line) ov)
                  (jj-diff--update-line-overlay line))

                (push line all-lines))))
          (setf (jj-diff-hunk-body-end-pos hunk) (point))
          (setf (jj-diff-hunk-end-pos hunk) (point))
          (jj-diff--update-hunk-header-overlay hunk))
        (insert "\n")
        (setf (jj-diff-file-end-pos file) (point))
        (jj-diff--update-file-header-overlay file)))

    (setq jj-diff--all-lines (nreverse all-lines))
    (goto-char (min orig-point (point-max)))))

(defun jj-diff--update-line-overlay (line)
  "Update the visual overlay of LINE according to its marked status."
  (let ((ov (jj-diff-line-overlay line))
        (marked (jj-diff-line-marked line))
        (type (jj-diff-line-type line)))
    (when (and ov (overlayp ov))
      (if (and marked (memq type '(:add :del)))
          (progn
            (overlay-put ov 'face 'jj-diff-marked)
            (overlay-put ov 'before-string
                         (propertize (if (eq type ':add) "+" "-")
                                     'face 'jj-diff-marked-fringe
                                     'display '(left-fringe right-triangle jj-diff-marked-fringe))))
        (overlay-put ov 'face nil)
        (overlay-put ov 'before-string nil)))))

(defun jj-diff--update-hunk-header-overlay (hunk)
  "Update the header overlay of HUNK to reflect its marked status."
  (let ((ov (jj-diff-hunk-header-overlay hunk)))
    (when (and ov (overlayp ov))
      (let* ((lines (cl-remove-if-not (lambda (l) (memq (jj-diff-line-type l) '(:add :del)))
                                      (jj-diff-hunk-lines hunk)))
             (total (length lines))
             (marked (cl-count-if #'jj-diff-line-marked lines)))
        (cond
         ((and (> total 0) (= marked total))
          (overlay-put ov 'face 'jj-diff-marked)
          (overlay-put ov 'after-string
                       (propertize (format " [✓ %d/%d]" marked total)
                                   'face 'jj-diff-marked-fringe)))
         ((> marked 0)
          (overlay-put ov 'face nil)
          (overlay-put ov 'after-string
                       (propertize (format " [● %d/%d]" marked total)
                                   'face 'jj-diff-partial)))
         (t
          (overlay-put ov 'face nil)
          (overlay-put ov 'after-string nil)))))))

(defun jj-diff--update-file-header-overlay (file)
  "Update the header overlay of FILE to reflect its marked status."
  (let ((ov (jj-diff-file-header-overlay file)))
    (when (and ov (overlayp ov))
      (let* ((lines (cl-loop for h in (jj-diff-file-hunks file)
                             append (cl-remove-if-not (lambda (l) (memq (jj-diff-line-type l) '(:add :del)))
                                                      (jj-diff-hunk-lines h))))
             (total (length lines))
             (marked (cl-count-if #'jj-diff-line-marked lines)))
        (cond
         ((and (> total 0) (= marked total))
          (overlay-put ov 'face 'jj-diff-marked)
          (overlay-put ov 'after-string
                       (propertize (format " [✓ %d/%d]" marked total)
                                   'face 'jj-diff-marked-fringe)))
         ((> marked 0)
          (overlay-put ov 'face nil)
          (overlay-put ov 'after-string
                       (propertize (format " [● %d/%d]" marked total)
                                   'face 'jj-diff-partial)))
         (t
          (overlay-put ov 'face nil)
          (overlay-put ov 'after-string nil)))))))

;;; Marking Mechanics

(defun jj-diff--line-at-point ()
  "Return the `jj-diff-line' struct at point, or nil."
  (get-text-property (point) 'jj-diff-line))

(defun jj-diff--hunk-at-point ()
  "Return the `jj-diff-hunk' struct at point, or nil."
  (get-text-property (point) 'jj-diff-hunk))

(defun jj-diff--file-at-point ()
  "Return the `jj-diff-file' struct at point, or nil."
  (get-text-property (point) 'jj-diff-file))

(defun jj-diff--set-line-marked (line marked)
  "Set MARKED status for LINE and update its visual overlay."
  (when (memq (jj-diff-line-type line) '(:add :del))
    (setf (jj-diff-line-marked line) marked)
    (jj-diff--update-line-overlay line)
    (let ((hunk (jj-diff-line-hunk line)))
      (when hunk
        (jj-diff--update-hunk-header-overlay hunk)
        (let ((file (jj-diff-hunk-file hunk)))
          (when file
            (jj-diff--update-file-header-overlay file)))))))

(defun jj-diff-mark (&optional arg)
  "Mark current line, active region, hunk, or file.
With prefix ARG, unmark instead."
  (interactive "P")
  (let ((target-state (not arg)))
    (cond
     ;; Active Region
     ((use-region-p)
      (let ((rbeg (region-beginning))
            (rend (region-end)))
        (dolist (line jj-diff--all-lines)
          (when (and (< (jj-diff-line-beg-pos line) rend)
                     (> (jj-diff-line-end-pos line) rbeg))
            (jj-diff--set-line-marked line target-state)))
        (deactivate-mark)))

     ;; Point on a specific change line
     ((jj-diff--line-at-point)
      (let ((line (jj-diff--line-at-point)))
        (if (memq (jj-diff-line-type line) '(:add :del))
            (progn
              (jj-diff--set-line-marked line (not (jj-diff-line-marked line)))
              (forward-line 1))
          ;; On context line: toggle entire hunk
          (let ((hunk (jj-diff--hunk-at-point)))
            (when hunk
              (let* ((lines (cl-remove-if-not (lambda (l) (memq (jj-diff-line-type l) '(:add :del)))
                                              (jj-diff-hunk-lines hunk)))
                     (all-marked (cl-every #'jj-diff-line-marked lines)))
                (dolist (l lines)
                  (jj-diff--set-line-marked l (not all-marked)))))))))

     ;; Point on Hunk Header
     ((jj-diff--hunk-at-point)
      (let* ((hunk (jj-diff--hunk-at-point))
             (lines (cl-remove-if-not (lambda (l) (memq (jj-diff-line-type l) '(:add :del)))
                                     (jj-diff-hunk-lines hunk)))
             (all-marked (cl-every #'jj-diff-line-marked lines)))
        (dolist (l lines)
          (jj-diff--set-line-marked l (not all-marked)))))

     ;; Point on File Header
     ((jj-diff--file-at-point)
      (let* ((file (jj-diff--file-at-point))
             (lines (cl-loop for h in (jj-diff-file-hunks file)
                             append (cl-remove-if-not (lambda (l) (memq (jj-diff-line-type l) '(:add :del)))
                                                      (jj-diff-hunk-lines h))))
             (all-marked (cl-every #'jj-diff-line-marked lines)))
        (dolist (l lines)
          (jj-diff--set-line-marked l (not all-marked))))))))

(defalias 'jj-diff-stage #'jj-diff-mark)

(defun jj-diff-unmark ()
  "Unmark current line, active region, hunk, or file."
  (interactive)
  (jj-diff-mark '(4)))

(defalias 'jj-diff-unstage #'jj-diff-unmark)

(defun jj-diff-mark-all ()
  "Mark all change lines in the buffer."
  (interactive)
  (dolist (line jj-diff--all-lines)
    (when (memq (jj-diff-line-type line) '(:add :del))
      (setf (jj-diff-line-marked line) t)
      (jj-diff--update-line-overlay line)))
  (dolist (file jj-diff--files)
    (dolist (hunk (jj-diff-file-hunks file))
      (jj-diff--update-hunk-header-overlay hunk))
    (jj-diff--update-file-header-overlay file))
  (message "Marked all changes."))

(defalias 'jj-diff-stage-all #'jj-diff-mark-all)

(defun jj-diff-unmark-all ()
  "Unmark all change lines in the buffer."
  (interactive)
  (dolist (line jj-diff--all-lines)
    (when (memq (jj-diff-line-type line) '(:add :del))
      (setf (jj-diff-line-marked line) nil)
      (jj-diff--update-line-overlay line)))
  (dolist (file jj-diff--files)
    (dolist (hunk (jj-diff-file-hunks file))
      (jj-diff--update-hunk-header-overlay hunk))
    (jj-diff--update-file-header-overlay file))
  (message "Unmarked all changes."))

(defalias 'jj-diff-unstage-all #'jj-diff-unmark-all)

(defun jj-diff-next-hunk ()
  "Move point to next diff hunk."
  (interactive)
  (let ((pos (point))
        (target nil))
    (dolist (file jj-diff--files)
      (dolist (hunk (jj-diff-file-hunks file))
        (when (and (> (jj-diff-hunk-beg-pos hunk) pos)
                   (or (null target) (< (jj-diff-hunk-beg-pos hunk) target)))
          (setq target (jj-diff-hunk-beg-pos hunk)))))
    (if target
        (goto-char target)
      (message "No next hunk."))))

(defun jj-diff-prev-hunk ()
  "Move point to previous diff hunk."
  (interactive)
  (let ((pos (point))
        (target nil))
    (dolist (file jj-diff--files)
      (dolist (hunk (jj-diff-file-hunks file))
        (when (and (< (jj-diff-hunk-beg-pos hunk) pos)
                   (or (null target) (> (jj-diff-hunk-beg-pos hunk) target)))
          (setq target (jj-diff-hunk-beg-pos hunk)))))
    (if target
        (goto-char target)
      (message "No previous hunk."))))

(defun jj-diff-next-file ()
  "Move point to next file diff."
  (interactive)
  (let ((pos (point))
        (target nil))
    (dolist (file jj-diff--files)
      (when (and (> (jj-diff-file-beg-pos file) pos)
                 (or (null target) (< (jj-diff-file-beg-pos file) target)))
        (setq target (jj-diff-file-beg-pos file))))
    (if target
        (goto-char target)
      (message "No next file."))))

(defun jj-diff-prev-file ()
  "Move point to previous file diff."
  (interactive)
  (let ((pos (point))
        (target nil))
    (dolist (file jj-diff--files)
      (when (and (< (jj-diff-file-beg-pos file) pos)
                 (or (null target) (> (jj-diff-file-beg-pos file) target)))
        (setq target (jj-diff-file-beg-pos file))))
    (if target
        (goto-char target)
      (message "No previous file."))))

(defun jj-diff-count-marked-lines ()
  "Return count of currently marked lines."
  (cl-count-if (lambda (l)
                 (and (jj-diff-line-marked l)
                      (memq (jj-diff-line-type l) '(:add :del))))
               jj-diff--all-lines))

(defalias 'jj-diff-count-staged-lines #'jj-diff-count-marked-lines)

(defun jj-diff--toggle-hunk-fold (hunk &optional force-state)
  "Toggle fold visibility for HUNK.
If FORCE-STATE is non-nil, set invisible to FORCE-STATE (t to hide, nil to show)."
  (let ((ov (jj-diff-hunk-fold-overlay hunk))
        (beg (jj-diff-hunk-body-beg-pos hunk))
        (end (jj-diff-hunk-body-end-pos hunk)))
    (when (and beg end (> end beg))
      (unless (and ov (overlayp ov))
        (setq ov (make-overlay beg end))
        (overlay-put ov 'isearch-open-invisible #'ignore)
        (setf (jj-diff-hunk-fold-overlay hunk) ov))
      (let* ((cur-inv (overlay-get ov 'invisible))
             (new-inv (if (null force-state)
                          (not cur-inv)
                        (eq force-state t))))
        (overlay-put ov 'invisible new-inv)))))

(defun jj-diff-toggle-fold ()
  "Toggle visibility of current hunk or file at point."
  (interactive)
  (cond
   ;; File header
   ((jj-diff--file-at-point)
    (let* ((file (jj-diff--file-at-point))
           (hunks (jj-diff-file-hunks file)))
      (when hunks
        ;; If any hunk is visible, hide all; otherwise show all
        (let* ((any-visible (cl-some (lambda (h)
                                       (let ((ov (jj-diff-hunk-fold-overlay h)))
                                         (not (and ov (overlay-get ov 'invisible)))))
                                     hunks))
               (target-hide any-visible))
          (dolist (h hunks)
            (jj-diff--toggle-hunk-fold h target-hide))))))

   ;; Hunk header or inside hunk
   ((jj-diff--hunk-at-point)
    (jj-diff--toggle-hunk-fold (jj-diff--hunk-at-point)))))

(defun jj-diff-toggle-all-folds ()
  "Toggle visibility of all hunks in the buffer.
If any hunk is visible, collapse all hunks; otherwise expand all hunks."
  (interactive)
  (let* ((all-hunks (cl-loop for f in jj-diff--files
                             append (copy-sequence (jj-diff-file-hunks f))))
         (any-visible (cl-some (lambda (h)
                                 (let ((ov (jj-diff-hunk-fold-overlay h)))
                                   (not (and ov (overlay-get ov 'invisible)))))
                               all-hunks))
         (target-hide any-visible))
    (dolist (h all-hunks)
      (jj-diff--toggle-hunk-fold h target-hide))
    (message (if target-hide "Collapsed all hunks." "Expanded all hunks."))))

;;; Selected Patch Generator

(defun jj-diff--generate-selected-patch (files)
  "Generate a unified diff patch string containing ONLY the marked lines from FILES."
  (with-temp-buffer
    (dolist (file files)
      (let ((file-hunk-patches nil))
        (dolist (hunk (jj-diff-file-hunks file))
          (let ((selected-lines nil)
                (has-marked-change nil)
                (old-count (jj-diff-hunk-old-count hunk))
                (new-count 0))
            (dolist (line (jj-diff-hunk-lines hunk))
              (let ((type (jj-diff-line-type line))
                    (marked (jj-diff-line-marked line))
                    (text (jj-diff-line-text line)))
                (cond
                 ;; Context line: always included as context
                 ((eq type ':context)
                  (push (if (string-prefix-p " " text) text (concat " " text)) selected-lines)
                  (cl-incf new-count))

                 ;; Marked addition: included as '+'
                 ((and (eq type ':add) marked)
                  (push (if (string-prefix-p "+" text) text (concat "+" text)) selected-lines)
                  (cl-incf new-count)
                  (setq has-marked-change t))

                 ;; Unmarked addition: omitted
                 ((and (eq type ':add) (not marked))
                  ;; Do nothing
                  nil)

                 ;; Marked deletion: included as '-'
                 ((and (eq type ':del) marked)
                  (push (if (string-prefix-p "-" text) text (concat "-" text)) selected-lines)
                  (setq has-marked-change t))

                 ;; Unmarked deletion: kept as context ' '
                 ((and (eq type ':del) (not marked))
                  (let ((content (if (string-prefix-p "-" text)
                                     (substring text 1)
                                   text)))
                    (push (concat " " content) selected-lines)
                    (cl-incf new-count))))))

            ;; If this hunk contains at least one marked change, generate hunk header and content
            (when has-marked-change
              (let* ((old-start (jj-diff-hunk-old-start hunk))
                     (new-start (jj-diff-hunk-new-start hunk))
                     (hunk-hdr (format "@@ -%d,%d +%d,%d @@"
                                       old-start old-count
                                       new-start new-count))
                     (hunk-body (mapconcat #'identity (nreverse selected-lines) "\n")))
                (push (concat hunk-hdr "\n" hunk-body "\n") file-hunk-patches)))))

        ;; If file had marked changes, output file headers + hunk patches
        (when file-hunk-patches
          (let ((old-path (jj-diff-file-old-path file))
                (new-path (jj-diff-file-new-path file)))
            (insert (format "diff --git a/%s b/%s\n" old-path new-path))
            (if (jj-diff-file-is-new file)
                (progn
                  (insert "new file mode 100644\n")
                  (insert "--- /dev/null\n")
                  (insert (format "+++ b/%s\n" new-path)))
              (if (jj-diff-file-is-deleted file)
                  (progn
                    (insert "deleted file mode 100644\n")
                    (insert (format "--- a/%s\n" old-path))
                    (insert "+++ /dev/null\n"))
                (insert (format "--- a/%s\n" old-path))
                (insert (format "+++ b/%s\n" new-path))))
            (dolist (hp (nreverse file-hunk-patches))
              (insert hp))))))
    (buffer-string)))

;;; Batch Applier (Emacs Lisp backend for `jj split --tool`)

(defun jj-diff--copy-directory-contents (src dst)
  "Copy all contents of SRC directory to DST directory, overwriting."
  (unless (file-directory-p dst)
    (make-directory dst t))
  ;; Remove existing contents in DST
  (dolist (file (directory-files dst t "^[^.]"))
    (if (file-directory-p file)
        (delete-directory file t)
      (delete-file file)))
  ;; Copy all files from SRC to DST
  (dolist (file (directory-files src t "^[^.]"))
    (let ((target (expand-file-name (file-name-nondirectory file) dst)))
      (if (file-directory-p file)
          (copy-directory file target nil t t)
        (copy-file file target t t t))))
  ;; Make all files in DST writable
  (dolist (file (directory-files-recursively dst ".*" t))
    (unless (file-directory-p file)
      (set-file-modes file #o644))))

(defun jj-diff--batch-apply (left right patch-file)
  "Batch entry point executed by Emacs when invoked as `jj split --tool` diff-editor.
LEFT is the baseline tree directory.
RIGHT is the target split directory.
PATCH-FILE is the path to the selected unified diff patch."
  (condition-case err
      (progn
        (jj-diff--copy-directory-contents left right)
        (let ((default-directory (file-name-as-directory right)))
          (let ((exit-code (call-process "git" nil nil nil
                                         "apply"
                                         "--unsafe-paths"
                                         "--whitespace=nowarn"
                                         (expand-file-name patch-file))))
            (if (zerop exit-code)
                (kill-emacs 0)
              (message "jj-diff: git apply failed with code %d" exit-code)
              (kill-emacs 1)))))
    (error
     (message "jj-diff error in batch apply: %s" (error-message-string err))
     (kill-emacs 1))))

;;; Commit Description Mode & Execution

(defvar jj-describe-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'jj-diff-commit-apply)
    (define-key map (kbd "C-c C-k") #'jj-diff-commit-cancel)
    map)
  "Keymap for `jj-describe-mode`.")

(define-derived-mode jj-describe-mode text-mode "JJ-Describe"
  "Major mode for editing Jujutsu commit descriptions."
  (setq-local header-line-format
              (propertize " Press C-c C-c to commit marked changes, C-c C-k to cancel."
                          'face 'jj-diff-status-bar)))

(defun jj-diff-commit ()
  "Open description buffer for marked changes."
  (interactive)
  (let ((marked-count (jj-diff-count-marked-lines)))
    (if (zerop marked-count)
        (user-error "No changes marked. Mark lines/hunks with 'm' before committing")
      (let ((source-buf (current-buffer))
            (desc-buf (get-buffer-create "*jj-commit-description*")))
        (with-current-buffer desc-buf
          (jj-describe-mode)
          (erase-buffer)
          (setq jj-diff--source-buffer source-buf)
          (insert "\n")
          (insert "# ------------------------------------------------------------\n")
          (insert (format "# Commit %d marked change line(s) via `jj split`\n" marked-count))
          (insert "# Lines starting with '#' will be ignored.\n")
          (insert "# Type message above and press C-c C-c to commit.\n")
          (goto-char (point-min)))
        (pop-to-buffer desc-buf)))))

(defun jj-diff-commit-cancel ()
  "Cancel commit description and close buffer."
  (interactive)
  (let ((desc-buf (current-buffer)))
    (quit-window t (get-buffer-window desc-buf))
    (message "Commit canceled.")))

(defun jj-diff-commit-apply ()
  "Execute `jj split` non-interactively using the selected patch and message."
  (interactive)
  (let* ((desc-raw (buffer-substring-no-properties (point-min) (point-max)))
         (desc-lines (cl-remove-if (lambda (l) (string-prefix-p "#" (string-trim l)))
                                  (split-string desc-raw "\n")))
         (message-text (string-trim (mapconcat #'identity desc-lines "\n")))
         (source-buf jj-diff--source-buffer))
    (when (string-empty-p message-text)
      (user-error "Commit message cannot be empty"))
    (unless (and source-buf (buffer-live-p source-buf))
      (user-error "Source jj-diff buffer is no longer available"))

    (let ((repo-root (with-current-buffer source-buf jj-diff--repo-root))
          (files (with-current-buffer source-buf jj-diff--files))
          (revision (with-current-buffer source-buf jj-diff--revision))
          (patch-file (make-temp-file "jj-diff-patch-" nil ".diff"))
          (this-el-file (or (locate-library "jj-diff")
                            (buffer-file-name (get-file-buffer "jj-diff.el"))
                            (expand-file-name "jj-diff.el" repo-root))))

      ;; 1. Generate patch string and write to temporary file
      (let ((patch-str (with-current-buffer source-buf
                         (jj-diff--generate-selected-patch files))))
        (when (string-empty-p (string-trim patch-str))
          (delete-file patch-file)
          (user-error "Generated patch is empty; no changes marked"))
        (with-temp-file patch-file
          (insert patch-str)))

      ;; 2. Run jj split non-interactively
      (message "Running `jj split`...")
      (let* ((emacs-bin jj-diff-emacs-executable)
             (eval-form (format "(progn (require 'jj-diff) (jj-diff--batch-apply \"$left\" \"$right\" %S))"
                                patch-file))
             (edit-args-val (format "[\"--batch\", \"-Q\", \"-l\", %S, \"--eval\", %S]"
                                    this-el-file
                                    eval-form))
             (args (list "-R" repo-root
                         "split"
                         "-r" revision
                         "--tool" "jj-emacs-split"
                         "--config" "ui.diff-instructions=false"
                         "--config" (format "merge-tools.jj-emacs-split.program=%S" emacs-bin)
                         "--config" (format "merge-tools.jj-emacs-split.edit-args=%s" edit-args-val)
                         "-m" message-text)))
        (with-temp-buffer
          (let ((exit-code (apply #'call-process jj-diff-executable nil (list t t) nil args)))
            (delete-file patch-file)
            (if (zerop exit-code)
                (progn
                  (quit-window t (selected-window))
                  (with-current-buffer source-buf
                    (jj-diff-refresh))
                  (message "Successfully committed marked changes."))
              (let ((err-out (buffer-string)))
                (error "jj split failed:\n%s" err-out)))))))))

;;; Keymap & Major Mode

(defvar jj-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'jj-diff-toggle-fold)
    (define-key map (kbd "<tab>") #'jj-diff-toggle-fold)
    (define-key map (kbd "RET") #'jj-diff-toggle-fold)
    (define-key map (kbd "<backtab>") #'jj-diff-toggle-all-folds)
    (define-key map (kbd "S-TAB") #'jj-diff-toggle-all-folds)
    (define-key map (kbd "<S-tab>") #'jj-diff-toggle-all-folds)
    (define-key map (kbd "<S-iso-lefttab>") #'jj-diff-toggle-all-folds)
    (define-key map (kbd "M-TAB") #'jj-diff-toggle-all-folds)
    (define-key map (kbd "m") #'jj-diff-mark)
    (define-key map (kbd "s") #'jj-diff-mark)
    (define-key map (kbd "u") #'jj-diff-unmark)
    (define-key map (kbd "M") #'jj-diff-mark-all)
    (define-key map (kbd "S") #'jj-diff-mark-all)
    (define-key map (kbd "U") #'jj-diff-unmark-all)
    (define-key map (kbd "n") #'jj-diff-next-hunk)
    (define-key map (kbd "p") #'jj-diff-prev-hunk)
    (define-key map (kbd "N") #'jj-diff-next-file)
    (define-key map (kbd "P") #'jj-diff-prev-file)
    (define-key map (kbd "c") #'jj-diff-commit)
    (define-key map (kbd "g") #'jj-diff-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for `jj-diff-mode`.")

(define-derived-mode jj-diff-mode special-mode "JJ-Diff"
  "Major mode for viewing Jujutsu diffs and marking changes for split commits.

\\{jj-diff-mode-map}"
  (setq buffer-read-only t)
  (setq-local truncate-lines t))

;;; User-Facing Entry Points

(defun jj-diff-refresh ()
  "Refresh the current `jj-diff` buffer."
  (interactive)
  (unless jj-diff--repo-root
    (setq jj-diff--repo-root (jj-diff--find-repo-root)))
  (unless jj-diff--repo-root
    (user-error "Not in a Jujutsu repository"))
  (let* ((raw-diff (jj-diff--run-command (list "-R" jj-diff--repo-root
                                              "diff"
                                              "-r" (or jj-diff--revision "@")
                                              "--git")
                                         jj-diff--repo-root))
         (files (jj-diff--parse-unified-diff raw-diff)))
    (setq jj-diff--files files)
    (jj-diff--render-buffer)))

;;;###autoload
(defun jj-diff (&optional revision dir)
  "Open the interactive Jujutsu diff buffer for REVISION in DIR.
REVISION defaults to \"@\" (current working copy).
Finds the closest Jujutsu repository root containing DIR (or `default-directory`)."
  (interactive (list (if current-prefix-arg
                         (read-string "Revision (default @): " nil nil "@")
                       "@")
                     default-directory))
  (let* ((root (jj-diff--find-repo-root dir)))
    (unless root
      (user-error "Not in a Jujutsu repository: %s" (or dir default-directory)))
    (let* ((repo-name (file-name-nondirectory (directory-file-name root)))
           (buf-name (format "*jj-diff: %s*" repo-name))
           (buf (get-buffer-create buf-name)))
      (with-current-buffer buf
        (jj-diff-mode)
        (setq default-directory (file-name-as-directory root))
        (setq jj-diff--repo-root root)
        (setq jj-diff--revision (or revision "@"))
        (jj-diff-refresh))
      (pop-to-buffer buf))))

(provide 'jj-diff)

;;; jj-diff.el ends here
