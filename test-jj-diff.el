;;; test-jj-diff.el --- Comprehensive Unit & Integration Tests for jj-diff -*- lexical-binding: t; -*-

(require 'ert)
(require 'jj-diff)

;;; 1. Diff Parser Tests

(ert-deftest jj-diff-test-parse-diff ()
  "Test parsing standard unified diff."
  (let ((diff-str (concat "diff --git a/foo.txt b/foo.txt\n"
                          "index 1111..2222 100644\n"
                          "--- a/foo.txt\n"
                          "+++ b/foo.txt\n"
                          "@@ -1,3 +1,4 @@\n"
                          "-old line 1\n"
                          "+new line 1\n"
                          " line 2\n"
                          " line 3\n"
                          "+line 4\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (should (= (length files) 1))
      (let ((file (car files)))
        (should (string= (jj-diff-file-old-path file) "foo.txt"))
        (should (string= (jj-diff-file-new-path file) "foo.txt"))
        (should-not (jj-diff-file-is-new file))
        (should-not (jj-diff-file-is-deleted file))
        (should (= (length (jj-diff-file-hunks file)) 1))
        (let ((hunk (car (jj-diff-file-hunks file))))
          (should (= (jj-diff-hunk-old-start hunk) 1))
          (should (= (jj-diff-hunk-old-count hunk) 3))
          (should (= (jj-diff-hunk-new-start hunk) 1))
          (should (= (jj-diff-hunk-new-count hunk) 4))
          (should (= (length (jj-diff-hunk-lines hunk)) 5)))))))

(ert-deftest jj-diff-test-parse-new-file ()
  "Test parsing diff for a newly created file."
  (let ((diff-str (concat "diff --git a/new.txt b/new.txt\n"
                          "new file mode 100644\n"
                          "--- /dev/null\n"
                          "+++ b/new.txt\n"
                          "@@ -0,0 +1,3 @@\n"
                          "+first line\n"
                          "+second line\n"
                          "+third line\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (should (= (length files) 1))
      (let ((file (car files)))
        (should (string= (jj-diff-file-new-path file) "new.txt"))
        (should (jj-diff-file-is-new file))
        (should-not (jj-diff-file-is-deleted file))
        (let ((hunk (car (jj-diff-file-hunks file))))
          (should (= (jj-diff-hunk-old-start hunk) 0))
          (should (= (jj-diff-hunk-old-count hunk) 0))
          (should (= (jj-diff-hunk-new-start hunk) 1))
          (should (= (jj-diff-hunk-new-count hunk) 3))
          (should (= (length (jj-diff-hunk-lines hunk)) 3)))))))

(ert-deftest jj-diff-test-parse-deleted-file ()
  "Test parsing diff for a deleted file."
  (let ((diff-str (concat "diff --git a/deleted.txt b/deleted.txt\n"
                          "deleted file mode 100644\n"
                          "--- a/deleted.txt\n"
                          "+++ /dev/null\n"
                          "@@ -1,2 +0,0 @@\n"
                          "-line 1\n"
                          "-line 2\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (should (= (length files) 1))
      (let ((file (car files)))
        (should (string= (jj-diff-file-old-path file) "deleted.txt"))
        (should (jj-diff-file-is-deleted file))
        (should-not (jj-diff-file-is-new file))
        (let ((hunk (car (jj-diff-file-hunks file))))
          (should (= (jj-diff-hunk-old-start hunk) 1))
          (should (= (jj-diff-hunk-old-count hunk) 2))
          (should (= (jj-diff-hunk-new-start hunk) 0))
          (should (= (jj-diff-hunk-new-count hunk) 0))
          (should (= (length (jj-diff-hunk-lines hunk)) 2)))))))

(ert-deftest jj-diff-test-parse-multi-hunk ()
  "Test parsing multiple hunks in a single file."
  (let ((diff-str (concat "diff --git a/multi.txt b/multi.txt\n"
                          "--- a/multi.txt\n"
                          "+++ b/multi.txt\n"
                          "@@ -1,3 +1,3 @@\n"
                          "-line 1\n"
                          "+line 1 mod\n"
                          " line 2\n"
                          " line 3\n"
                          "@@ -10,3 +10,4 @@\n"
                          " line 10\n"
                          "-line 11\n"
                          "+line 11 mod\n"
                          "+line 11.5\n"
                          " line 12\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (should (= (length files) 1))
      (let* ((file (car files))
             (hunks (jj-diff-file-hunks file)))
        (should (= (length hunks) 2))
        (should (= (jj-diff-hunk-old-start (nth 0 hunks)) 1))
        (should (= (jj-diff-hunk-old-start (nth 1 hunks)) 10))))))

(ert-deftest jj-diff-test-parse-multi-file ()
  "Test parsing diff containing multiple files."
  (let ((diff-str (concat "diff --git a/fileA.txt b/fileA.txt\n"
                          "--- a/fileA.txt\n"
                          "+++ b/fileA.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-a\n"
                          "+A\n"
                          "diff --git a/fileB.txt b/fileB.txt\n"
                          "--- a/fileB.txt\n"
                          "+++ b/fileB.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-b\n"
                          "+B\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (should (= (length files) 2))
      (should (string= (jj-diff-file-new-path (nth 0 files)) "fileA.txt"))
      (should (string= (jj-diff-file-new-path (nth 1 files)) "fileB.txt")))))

(ert-deftest jj-diff-test-parse-empty-diff ()
  "Test parsing empty diff output."
  (let ((files (jj-diff--parse-unified-diff "")))
    (should (null files))))

(ert-deftest jj-diff-test-line-numbers-calculation ()
  "Test that line numbers in new and old files are correctly calculated on diff lines."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -10,3 +10,4 @@\n"
                          " line 10\n"
                          "-line 11\n"
                          "+line 11 new\n"
                          "+line 12 new\n"
                          " line 13\n")))
    (let* ((files (jj-diff--parse-unified-diff diff-str))
           (lines (jj-diff-hunk-lines (car (jj-diff-file-hunks (car files))))))
      ;; line 10 (context): old 10, new 10
      (should (= (jj-diff-line-old-line-num (nth 0 lines)) 10))
      (should (= (jj-diff-line-new-line-num (nth 0 lines)) 10))
      ;; -line 11 (del): old 11, new 11
      (should (= (jj-diff-line-old-line-num (nth 1 lines)) 11))
      (should (= (jj-diff-line-new-line-num (nth 1 lines)) 11))
      ;; +line 11 new (add): old nil, new 11
      (should-not (jj-diff-line-old-line-num (nth 2 lines)))
      (should (= (jj-diff-line-new-line-num (nth 2 lines)) 11))
      ;; +line 12 new (add): old nil, new 12
      (should-not (jj-diff-line-old-line-num (nth 3 lines)))
      (should (= (jj-diff-line-new-line-num (nth 3 lines)) 12))
      ;; line 13 (context): old 12, new 13
      (should (= (jj-diff-line-old-line-num (nth 4 lines)) 12))
      (should (= (jj-diff-line-new-line-num (nth 4 lines)) 13)))))

;;; 2. Patch Generator Tests

(ert-deftest jj-diff-test-generate-selected-patch ()
  "Test generating patch with subset of marked lines."
  (let ((diff-str (concat "diff --git a/file1.txt b/file1.txt\n"
                          "--- a/file1.txt\n"
                          "+++ b/file1.txt\n"
                          "@@ -1,3 +1,5 @@\n"
                          "-line 1\n"
                          "+line 1 modified\n"
                          " line 2\n"
                          "-line 3\n"
                          "+line 3 changed\n"
                          "+line 4 added\n"
                          "+line 5 added\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (let* ((file (car files))
             (hunk (car (jj-diff-file-hunks file)))
             (lines (jj-diff-hunk-lines hunk)))
        ;; Mark ONLY line 3 deletion and line 3 addition
        (setf (jj-diff-line-marked (nth 3 lines)) t) ; -line 3
        (setf (jj-diff-line-marked (nth 4 lines)) t) ; +line 3 changed

        (let ((patch (jj-diff--generate-selected-patch files)))
          (should (string-match-p "diff --git a/file1.txt b/file1.txt" patch))
          (should (string-match-p "@@ -1,3 \\+1,3 @@" patch))
          (should (string-match-p "\n line 1\n" patch))
          (should (string-match-p "\n line 2\n" patch))
          (should (string-match-p "\n-line 3\n" patch))
          (should (string-match-p "\n\\+line 3 changed\n" patch))
          (should-not (string-match-p "line 1 modified" patch))
          (should-not (string-match-p "line 4 added" patch))
          (should-not (string-match-p "line 5 added" patch)))))))

(ert-deftest jj-diff-test-patch-new-file ()
  "Test generating patch for newly created file with subset of marked lines."
  (let ((diff-str (concat "diff --git a/newfile.txt b/newfile.txt\n"
                          "new file mode 100644\n"
                          "--- /dev/null\n"
                          "+++ b/newfile.txt\n"
                          "@@ -0,0 +1,3 @@\n"
                          "+line 1\n"
                          "+line 2\n"
                          "+line 3\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (let* ((file (car files))
             (hunk (car (jj-diff-file-hunks file)))
             (lines (jj-diff-hunk-lines hunk)))
        ;; Mark line 1 and line 3, leave line 2 unmarked
        (setf (jj-diff-line-marked (nth 0 lines)) t)
        (setf (jj-diff-line-marked (nth 2 lines)) t)

        (let ((patch (jj-diff--generate-selected-patch files)))
          (should (string-match-p "new file mode 100644" patch))
          (should (string-match-p "@@ -0,0 \\+1,2 @@" patch))
          (should (string-match-p "\\+line 1" patch))
          (should (string-match-p "\\+line 3" patch))
          (should-not (string-match-p "line 2" patch)))))))

(ert-deftest jj-diff-test-patch-deleted-file ()
  "Test generating patch for deleted file."
  (let ((diff-str (concat "diff --git a/old.txt b/old.txt\n"
                          "deleted file mode 100644\n"
                          "--- a/old.txt\n"
                          "+++ /dev/null\n"
                          "@@ -1,2 +0,0 @@\n"
                          "-line 1\n"
                          "-line 2\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (let* ((file (car files))
             (hunk (car (jj-diff-file-hunks file)))
             (lines (jj-diff-hunk-lines hunk)))
        ;; Mark all deleted lines
        (setf (jj-diff-line-marked (nth 0 lines)) t)
        (setf (jj-diff-line-marked (nth 1 lines)) t)

        (let ((patch (jj-diff--generate-selected-patch files)))
          (should (string-match-p "deleted file mode 100644" patch))
          (should (string-match-p "--- a/old.txt" patch))
          (should (string-match-p "\\+\\+\\+ /dev/null" patch))
          (should (string-match-p "@@ -1,2 \\+0,0 @@" patch)))))))

(ert-deftest jj-diff-test-patch-pure-deletion ()
  "Test generating patch where only deletion is marked."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -1,3 +1,2 @@\n"
                          " line 1\n"
                          "-line 2 to delete\n"
                          " line 3\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (let* ((file (car files))
             (hunk (car (jj-diff-file-hunks file)))
             (lines (jj-diff-hunk-lines hunk)))
        (setf (jj-diff-line-marked (nth 1 lines)) t)
        (let ((patch (jj-diff--generate-selected-patch files)))
          (should (string-match-p "@@ -1,3 \\+1,2 @@" patch))
          (should (string-match-p "-line 2 to delete" patch)))))))

(ert-deftest jj-diff-test-patch-empty-when-no-marks ()
  "Test generating patch when zero lines are marked returns empty string."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -1,1 +1,2 @@\n"
                          " line 1\n"
                          "+line 2\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      (let ((patch (jj-diff--generate-selected-patch files)))
        (should (string= (string-trim patch) ""))))))

(ert-deftest jj-diff-test-patch-multi-file-partial ()
  "Test generating patch when only 1 out of 2 files is marked."
  (let ((diff-str (concat "diff --git a/f1.txt b/f1.txt\n"
                          "--- a/f1.txt\n"
                          "+++ b/f1.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-old1\n"
                          "+new1\n"
                          "diff --git a/f2.txt b/f2.txt\n"
                          "--- a/f2.txt\n"
                          "+++ b/f2.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-old2\n"
                          "+new2\n")))
    (let ((files (jj-diff--parse-unified-diff diff-str)))
      ;; Mark only file 1
      (let* ((hunk1 (car (jj-diff-file-hunks (nth 0 files))))
             (lines1 (jj-diff-hunk-lines hunk1)))
        (setf (jj-diff-line-marked (nth 0 lines1)) t)
        (setf (jj-diff-line-marked (nth 1 lines1)) t))

      (let ((patch (jj-diff--generate-selected-patch files)))
        (should (string-match-p "diff --git a/f1.txt b/f1.txt" patch))
        (should-not (string-match-p "diff --git a/f2.txt b/f2.txt" patch))))))

;;; 3. Buffer Marking & Interaction Tests

(ert-deftest jj-diff-test-buffer-marking ()
  "Test marking interaction inside buffer."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -1,2 +1,3 @@\n"
                          " line 1\n"
                          "-line 2\n"
                          "+line 2 new\n"
                          "+line 3\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (should (= (jj-diff-count-marked-lines) 0))

      ;; Mark all
      (jj-diff-mark-all)
      (should (= (jj-diff-count-marked-lines) 3))

      ;; Unmark all
      (jj-diff-unmark-all)
      (should (= (jj-diff-count-marked-lines) 0))

      ;; Move to line containing "+line 2 new" and mark it
      (goto-char (point-min))
      (search-forward "+line 2 new")
      (jj-diff-mark)
      (should (= (jj-diff-count-marked-lines) 1)))))

(ert-deftest jj-diff-test-hunk-header-marking ()
  "Test pressing mark on a hunk header marks all change lines in that hunk."
  (let ((diff-str (concat "diff --git a/hunk_test.txt b/hunk_test.txt\n"
                          "--- a/hunk_test.txt\n"
                          "+++ b/hunk_test.txt\n"
                          "@@ -1,3 +1,4 @@\n"
                          "-line 1\n"
                          "+line 1 new\n"
                          " line 2\n"
                          "+line 3\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (let* ((file (car jj-diff--files))
             (hunk (car (jj-diff-file-hunks file))))
        ;; Move to hunk header
        (goto-char (jj-diff-hunk-beg-pos hunk))
        (jj-diff-mark)
        (should (= (jj-diff-count-marked-lines) 3))

        ;; Toggle again -> unmarks all
        (jj-diff-mark)
        (should (= (jj-diff-count-marked-lines) 0))))))

(ert-deftest jj-diff-test-file-header-marking ()
  "Test pressing mark on a file header marks all change lines across all hunks in that file."
  (let ((diff-str (concat "diff --git a/multi_hunk.txt b/multi_hunk.txt\n"
                          "--- a/multi_hunk.txt\n"
                          "+++ b/multi_hunk.txt\n"
                          "@@ -1,2 +1,2 @@\n"
                          "-hunk 1 old\n"
                          "+hunk 1 new\n"
                          "@@ -10,2 +10,2 @@\n"
                          "-hunk 2 old\n"
                          "+hunk 2 new\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (let ((file (car jj-diff--files)))
        ;; Move to file header
        (goto-char (jj-diff-file-beg-pos file))
        (jj-diff-mark)
        (should (= (jj-diff-count-marked-lines) 4))

        ;; Toggle again -> unmarks all in file
        (jj-diff-mark)
        (should (= (jj-diff-count-marked-lines) 0))))))

(ert-deftest jj-diff-test-header-overlays-marked-and-partial ()
  "Test file and hunk header overlays when fully marked vs partially marked."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -1,3 +1,3 @@\n"
                          "-line 1\n"
                          "+line 1 new\n"
                          "-line 2\n"
                          "+line 2 new\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (let* ((file (car jj-diff--files))
             (hunk (car (jj-diff-file-hunks file)))
             (file-ov (jj-diff-file-header-overlay file))
             (hunk-ov (jj-diff-hunk-header-overlay hunk)))
        ;; Initially none marked
        (should (overlayp file-ov))
        (should (overlayp hunk-ov))
        (should-not (overlay-get file-ov 'face))
        (should-not (overlay-get file-ov 'after-string))

        ;; Partially mark (1 out of 4 lines)
        (goto-char (point-min))
        (search-forward "+line 1 new")
        (jj-diff-mark)
        (should (= (jj-diff-count-marked-lines) 1))
        (should-not (overlay-get file-ov 'face))
        (should (string-match-p "1/4" (overlay-get file-ov 'after-string)))
        (should (string-match-p "1/4" (overlay-get hunk-ov 'after-string)))

        ;; Fully mark (all 4 lines in file)
        (jj-diff-mark-all)
        (should (eq (overlay-get file-ov 'face) 'jj-diff-marked))
        (should (string-match-p "✓ 4/4" (overlay-get file-ov 'after-string)))
        (should (eq (overlay-get hunk-ov 'face) 'jj-diff-marked))
        (should (string-match-p "✓ 4/4" (overlay-get hunk-ov 'after-string)))

        ;; Unmark all
        (jj-diff-unmark-all)
        (should-not (overlay-get file-ov 'face))
        (should-not (overlay-get file-ov 'after-string))))))

(ert-deftest jj-diff-test-region-marking ()
  "Test marking active region of lines."
  (let ((diff-str (concat "diff --git a/reg.txt b/reg.txt\n"
                          "--- a/reg.txt\n"
                          "+++ b/reg.txt\n"
                          "@@ -1,4 +1,4 @@\n"
                          "-line 1\n"
                          "+line 1 new\n"
                          "-line 2\n"
                          "+line 2 new\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)

      ;; Select region spanning "-line 1" and "+line 1 new"
      (goto-char (point-min))
      (search-forward "-line 1")
      (let ((rbeg (line-beginning-position)))
        (search-forward "+line 1 new")
        (let ((rend (line-end-position)))
          (set-mark rbeg)
          (goto-char rend)
          (activate-mark)
          (jj-diff-mark)
          (should (= (jj-diff-count-marked-lines) 2)))))))

;;; 4. Navigation & Folding Tests

(ert-deftest jj-diff-test-buffer-navigation ()
  "Test jumping between hunks and files with n/p/N/P."
  (let ((diff-str (concat "diff --git a/f1.txt b/f1.txt\n"
                          "--- a/f1.txt\n"
                          "+++ b/f1.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-a\n"
                          "+b\n"
                          "@@ -10,1 +10,1 @@\n"
                          "-c\n"
                          "+d\n"
                          "diff --git a/f2.txt b/f2.txt\n"
                          "--- a/f2.txt\n"
                          "+++ b/f2.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-e\n"
                          "+f\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)

      ;; Start at beginning
      (goto-char (point-min))
      (jj-diff-next-hunk)
      (let ((hunk1-pos (point)))
        (should (jj-diff--hunk-at-point))

        ;; Next hunk
        (jj-diff-next-hunk)
        (should (> (point) hunk1-pos))

        ;; Next file
        (jj-diff-next-file)
        (should (string= (jj-diff-file-new-path (jj-diff--file-at-point)) "f2.txt"))

        ;; Prev file
        (jj-diff-prev-file)
        (should (string= (jj-diff-file-new-path (jj-diff--file-at-point)) "f1.txt"))))))

(ert-deftest jj-diff-test-visit-file ()
  "Test jumping to file and line with RET (jj-diff-visit-file)."
  (let* ((temp-dir (make-temp-file "jj-diff-visit-test-" t))
         (src-file (expand-file-name "test_jump.txt" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file src-file
            (insert "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n"))
          (let ((diff-str (concat "diff --git a/test_jump.txt b/test_jump.txt\n"
                                  "--- a/test_jump.txt\n"
                                  "+++ b/test_jump.txt\n"
                                  "@@ -3,3 +3,4 @@\n"
                                  " line 3\n"
                                  "-line 4\n"
                                  "+line 4 modified\n"
                                  "+line 4.5 added\n"
                                  " line 5\n")))
            (let ((diff-buf (get-buffer-create "*jj-diff-test-visit*")))
              (unwind-protect
                  (with-current-buffer diff-buf
                    (jj-diff-mode)
                    (setq jj-diff--repo-root temp-dir)
                    (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
                    (jj-diff--render-buffer)

                    ;; 1. Jump from added line "+line 4.5 added" (should be line 5)
                    (goto-char (point-min))
                    (search-forward "+line 4.5 added")
                    (jj-diff-visit-file)
                    (should (string= (buffer-file-name) src-file))
                    (should (= (line-number-at-pos) 5))
                    (kill-buffer (current-buffer))

                    ;; 2. Jump from deleted line "-line 4" should signal user-error
                    (with-current-buffer diff-buf
                      (goto-char (point-min))
                      (search-forward "-line 4")
                      (should-error (jj-diff-visit-file) :type 'user-error)))
                (kill-buffer diff-buf)))))
      (delete-directory temp-dir t))))

(ert-deftest jj-diff-test-folding ()
  "Test hunk and file folding toggle."
  (let ((diff-str (concat "diff --git a/test.txt b/test.txt\n"
                          "--- a/test.txt\n"
                          "+++ b/test.txt\n"
                          "@@ -1,2 +1,3 @@\n"
                          " line 1\n"
                          "-line 2\n"
                          "+line 2 new\n"
                          "+line 3\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (let* ((file (car jj-diff--files))
             (hunk (car (jj-diff-file-hunks file))))
        ;; Move to hunk header and fold
        (goto-char (jj-diff-hunk-beg-pos hunk))
        (jj-diff-toggle-fold)
        (should (overlayp (jj-diff-hunk-fold-overlay hunk)))
        (should (eq (overlay-get (jj-diff-hunk-fold-overlay hunk) 'invisible) t))

        ;; Unfold
        (jj-diff-toggle-fold)
        (should (eq (overlay-get (jj-diff-hunk-fold-overlay hunk) 'invisible) nil))))))

(ert-deftest jj-diff-test-file-folding ()
  "Test cycling a file header through File (1) -> Hunks (2) -> Code (3) -> Hunks (2) -> File (1)."
  (let ((diff-str (concat "diff --git a/fold_file.txt b/fold_file.txt\n"
                          "--- a/fold_file.txt\n"
                          "+++ b/fold_file.txt\n"
                          "@@ -1,1 +1,1 @@\n"
                          "-1\n"
                          "+2\n"
                          "@@ -10,1 +10,1 @@\n"
                          "-3\n"
                          "+4\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      (let* ((file (car jj-diff--files))
             (hunks (jj-diff-file-hunks file)))
        ;; Initially level 3 (all code visible)
        (should (= (jj-diff--get-file-level file) 3))

        ;; Move to file header and press TAB -> narrows to Level 2 (hunks only)
        (goto-char (jj-diff-file-beg-pos file))
        (jj-diff-toggle-fold)
        (should (= (jj-diff--get-file-level file) 2))
        (should-not (overlay-get (jj-diff-file-fold-overlay file) 'invisible))
        (should (eq (overlay-get (jj-diff-hunk-fold-overlay (nth 0 hunks)) 'invisible) t))
        (should (eq (overlay-get (jj-diff-hunk-fold-overlay (nth 1 hunks)) 'invisible) t))

        ;; Press TAB again -> narrows to Level 1 (file header only)
        (jj-diff-toggle-fold)
        (should (= (jj-diff--get-file-level file) 1))
        (should (eq (overlay-get (jj-diff-file-fold-overlay file) 'invisible) t))

        ;; Press TAB again -> expands to Level 2 (hunks only)
        (jj-diff-toggle-fold)
        (should (= (jj-diff--get-file-level file) 2))
        (should-not (overlay-get (jj-diff-file-fold-overlay file) 'invisible))
        (should (eq (overlay-get (jj-diff-hunk-fold-overlay (nth 0 hunks)) 'invisible) t))

        ;; Press TAB again -> expands to Level 3 (all code)
        (jj-diff-toggle-fold)
        (should (= (jj-diff--get-file-level file) 3))
        (should-not (overlay-get (jj-diff-file-fold-overlay file) 'invisible))
        (should-not (overlay-get (jj-diff-hunk-fold-overlay (nth 0 hunks)) 'invisible))))))

(ert-deftest jj-diff-test-toggle-all-folds ()
  "Test global 3-level cycling: File (1) -> Hunks (2) -> Code (3) -> Hunks (2) -> File (1)."
  (let ((diff-str (concat "diff --git a/a.txt b/a.txt\n"
                          "--- a/a.txt\n"
                          "+++ b/a.txt\n"
                          "@@ -1,2 +1,2 @@\n"
                          "-a\n"
                          "+b\n"
                          "diff --git a/b.txt b/b.txt\n"
                          "--- a/b.txt\n"
                          "+++ b/b.txt\n"
                          "@@ -1,2 +1,2 @@\n"
                          "-c\n"
                          "+d\n")))
    (with-temp-buffer
      (jj-diff-mode)
      (setq jj-diff--files (jj-diff--parse-unified-diff diff-str))
      (jj-diff--render-buffer)
      ;; Initially Level 3 (all code visible)
      (should (= (jj-diff--get-global-level) 3))

      ;; 1. Press S-TAB -> narrows to Level 2 (hunk headers visible, code collapsed)
      (jj-diff-toggle-all-folds)
      (should (= (jj-diff--get-global-level) 2))

      ;; 2. Press S-TAB -> narrows to Level 1 (file headers only)
      (jj-diff-toggle-all-folds)
      (should (= (jj-diff--get-global-level) 1))

      ;; 3. Press S-TAB -> expands to Level 2 (hunk headers visible)
      (jj-diff-toggle-all-folds)
      (should (= (jj-diff--get-global-level) 2))

      ;; 4. Press S-TAB -> expands to Level 3 (all code visible)
      (jj-diff-toggle-all-folds)
      (should (= (jj-diff--get-global-level) 3)))))

;;; 5. Commit Description Buffer Validation Tests

(ert-deftest jj-diff-test-commit-validation ()
  "Test commit validations for empty mark set and empty messages."
  ;; 1. Zero marked lines error
  (with-temp-buffer
    (jj-diff-mode)
    (setq jj-diff--files (jj-diff--parse-unified-diff "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n"))
    (jj-diff--render-buffer)
    (should-error (jj-diff-commit) :type 'user-error)))

(ert-deftest jj-diff-test-copy-directory-contents ()
  "Test internal jj-diff--copy-directory-contents helper."
  (let* ((src (make-temp-file "jj-diff-src-" t))
         (dst (make-temp-file "jj-diff-dst-" t))
         (src-file (expand-file-name "test.txt" src))
         (dst-file (expand-file-name "test.txt" dst)))
    (unwind-protect
        (progn
          (with-temp-file src-file
            (insert "hello world"))
          (jj-diff--copy-directory-contents src dst)
          (should (file-exists-p dst-file))
          (should (string= (with-temp-buffer
                             (insert-file-contents dst-file)
                             (buffer-string))
                           "hello world")))
      (delete-directory src t)
      (delete-directory dst t))))

;;; 6. Root Discovery Tests

(ert-deftest jj-diff-test-root-discovery-from-nested-subdir ()
  "Test discovering jj root from deeply nested subdirectories."
  (let* ((temp-dir (make-temp-file "jj-diff-root-test-" t))
         (deep-dir (expand-file-name "a/b/c/d" temp-dir)))
    (unwind-protect
        (progn
          (should (zerop (call-process "jj" nil nil nil "git" "init" temp-dir)))
          (make-directory deep-dir t)
          (let ((found-root (jj-diff--find-repo-root deep-dir)))
            (should (string= (file-truename found-root) (file-truename temp-dir)))))
      (delete-directory temp-dir t))))

;;; 7. End-to-End Jujutsu Integration Tests

(ert-deftest jj-diff-test-e2e-split ()
  "Test end-to-end split execution on a real Jujutsu repository."
  (let* ((temp-dir (make-temp-file "jj-diff-test-repo-" t))
         (deep-sub-dir (expand-file-name "src/components" temp-dir))
         (file-path (expand-file-name "testfile.txt" temp-dir)))
    (unwind-protect
        (progn
          ;; 1. Initialize jj repo
          (should (zerop (call-process "jj" nil nil nil "git" "init" temp-dir)))
          (make-directory deep-sub-dir t)

          ;; 2. Write initial file and commit
          (with-temp-file file-path
            (insert "line 1\nline 2\nline 3\n"))
          (should (zerop (call-process "jj" nil nil nil "-R" temp-dir "commit" "-m" "initial commit")))

          ;; 3. Make working copy changes
          (with-temp-file file-path
            (insert "line 1 modified\nline 2\nline 3 changed\nline 4 added\n"))

          ;; 4. Open diff buffer FROM DEEP SUBDIRECTORY and mark only line 3 changes
          (let ((diff-buf (get-buffer-create "*jj-diff-test*"))
                (desc-buf (get-buffer-create "*jj-commit-description*")))
            (with-current-buffer diff-buf
              (jj-diff-mode)
              (setq default-directory (file-name-as-directory deep-sub-dir))
              (setq jj-diff--repo-root (jj-diff--find-repo-root deep-sub-dir))
              (setq jj-diff--revision "@")
              ;; Ensure root was properly discovered as parent repo
              (should (string= (file-truename jj-diff--repo-root) (file-truename temp-dir)))
              (jj-diff-refresh)
              (should (> (length jj-diff--files) 0))

              ;; Find and mark line 3 addition
              (goto-char (point-min))
              (search-forward "+line 3 changed")
              (jj-diff-mark)
              (should (= (jj-diff-count-marked-lines) 1))

              ;; Open commit description buffer
              (jj-diff-commit))

            ;; 5. In description buffer, write message and apply commit
            (with-current-buffer desc-buf
              (goto-char (point-min))
              (insert "Split commit for line 3\n")
              (jj-diff-commit-apply))

            ;; 6. Verify with jj log that parent commit @- has the commit description
            (with-temp-buffer
              (should (zerop (call-process "jj" nil t nil "-R" temp-dir "log" "-r" "@-" "-T" "description")))
              (should (string-match-p "Split commit for line 3" (buffer-string))))

            ;; 7. Verify diff of @- contains line 3 change
            (with-temp-buffer
              (should (zerop (call-process "jj" nil t nil "-R" temp-dir "diff" "-r" "@-")))
              (should (string-match-p "line 3 changed" (buffer-string)))
              (should-not (string-match-p "line 1 modified" (buffer-string)))
              (should-not (string-match-p "line 4 added" (buffer-string))))))
      ;; Cleanup
      (delete-directory temp-dir t))))

(ert-deftest jj-diff-test-e2e-split-multi-file ()
  "Test end-to-end split across multiple files."
  (let* ((temp-dir (make-temp-file "jj-diff-e2e-mf-" t))
         (file-a (expand-file-name "fileA.txt" temp-dir))
         (file-b (expand-file-name "fileB.txt" temp-dir)))
    (unwind-protect
        (progn
          (should (zerop (call-process "jj" nil nil nil "git" "init" temp-dir)))
          (with-temp-file file-a (insert "alpha\n"))
          (with-temp-file file-b (insert "beta\n"))
          (should (zerop (call-process "jj" nil nil nil "-R" temp-dir "commit" "-m" "base commit")))

          ;; Modify both files
          (with-temp-file file-a (insert "alpha modified\n"))
          (with-temp-file file-b (insert "beta modified\n"))

          (let ((diff-buf (get-buffer-create "*jj-diff-test-mf*"))
                (desc-buf (get-buffer-create "*jj-commit-description*")))
            (with-current-buffer diff-buf
              (jj-diff-mode)
              (setq default-directory (file-name-as-directory temp-dir))
              (setq jj-diff--repo-root temp-dir)
              (setq jj-diff--revision "@")
              (jj-diff-refresh)
              (should (= (length jj-diff--files) 2))

              ;; Mark changes only in fileA
              (goto-char (point-min))
              (search-forward "+alpha modified")
              (jj-diff-mark)
              (should (= (jj-diff-count-marked-lines) 1))
              (jj-diff-commit))

            (with-current-buffer desc-buf
              (goto-char (point-min))
              (insert "Commit only fileA\n")
              (jj-diff-commit-apply))

            ;; Check commit @- has fileA change but not fileB
            (with-temp-buffer
              (should (zerop (call-process "jj" nil t nil "-R" temp-dir "diff" "-r" "@-")))
              (should (string-match-p "alpha modified" (buffer-string)))
              (should-not (string-match-p "beta modified" (buffer-string))))))
      (delete-directory temp-dir t))))

(provide 'test-jj-diff)
;;; test-jj-diff.el ends here
