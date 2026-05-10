# AGENTS.md

Operational notes for future AI agents working in this repo.

## Safe validation loop

- After nontrivial edits to `eat.el`, always run:
  - `emacs --batch -Q -L . -l eat.el --eval '(message "loaded eat.el")'`
- If that fails with parse errors, use one or more of these:
  - `emacs --batch -Q --eval '(with-temp-buffer (insert-file-contents "eat.el") (goto-char (point-min)) (condition-case err (check-parens) (error (princ (format "ERR at %s: %s" (point) err)))))'`
  - `emacs --batch -Q --eval '(with-temp-buffer (insert-file-contents "eat.el") (goto-char (point-min)) (condition-case err (while t (forward-sexp 1)) (scan-error (princ (format "scan-error at %d line %d: %S" (point) (line-number-at-pos) err))) (end-of-file (princ "ok"))))'`
- For line-oriented inspection near parse failures, `nl -ba eat.el | sed -n 'START,ENDp'` is useful.

## Testing workflow

- Main test command:
  - `make check`
- The ERT suite lives in `eat-tests.el` and is wired by `Makefile`.
- When deleting features, remove or update the corresponding tests in `eat-tests.el` in the same change.
- After feature removal, search test expectations for stale property/assertion names with `rg` before running tests.

## Editing strategy that worked well here

- Use `rg -n` first to map every reference before deleting a feature.
- For large feature removals, update all of these together:
  - implementation in `eat.el`
  - docs in `eat.texi`
  - tests in `eat-tests.el`
  - any user-facing notes in `README.orig.org`
- For repetitive cleanup across many occurrences, `uv run python - <<'PY' ... PY` is effective for scripted file rewrites.
- After scripted rewrites, immediately re-run the load check before doing more edits.

## Common places where stale references remain

- `eat.el` commentary block near the top
- mode-line UI strings in `eat-mode`
- UIC handlers and shell-integration helper functions
- test helper property parsers in `eat-tests.el`
- `README.orig.org` and `eat.texi`

## Repository-specific notes

- Use `uv run python`, not plain `python`.
- `Makefile` already provides the canonical batch test entrypoint.
- `README.md` is minimal; historical usage details are in `README.orig.org`.
