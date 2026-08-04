# Attribution

This skill documents [stern](https://github.com/stern/stern), which is licensed under the
Apache License 2.0.

No stern source or documentation files are bundled verbatim. The flag tables, template-function
tables, and examples in `SKILL.md` and `references/` are **derived** from stern's `README.md` and
verified against the source tree (`cmd/cmd.go`, `stern/`) at version **v1.34.0**
(commit `3dd605b`, checked 2026-07-27); several short example commands are adapted from that README.

When stern releases a new version, re-verify:

- the flag table in stern's `README.md` (it is auto-generated from the flag set)
- `cmd/cmd.go` for validation rules (e.g. `--no-follow` vs `--tail=0`, `--condition` constraints)
  and for the `--max-log-requests` defaults
- `stern/tail_utils.go` for the `Log` struct fields exposed to templates and `-o json`
- `stern/resource_matcher.go` for supported `<resource>/<name>` kinds and aliases

Upstream license: https://github.com/stern/stern/blob/master/LICENSE
