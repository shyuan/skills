# Rule docs attribution

Except for `go.md` (see below), the `*.md` rule checklists in this directory are
**unmodified, verbatim copies** of files from Alibaba's **open-code-review**
project (`internal/config/rules/rule_docs/`):

> Copyright 2026 Alibaba
> Licensed under the Apache License, Version 2.0.

A full copy of the Apache License 2.0 is bundled alongside these files as
[`LICENSE`](./LICENSE), as required by section 4(a) of that license. The copied
files have not been changed; `go.md` is the only original addition.

They are bundled here so the OpenCode reviewer committee can inject a
file-type-specific review checklist into each member's persona — mirroring how
open-code-review matches a path-based rule to every changed file before review.

Upstream: https://github.com/alibaba/open-code-review (Apache-2.0)

## Local additions (not from upstream)

- `go.md` — written for this skill. open-code-review supports `.go` files in its
  allowlist but ships no Go-specific rule doc (Go falls back to `default.md`
  upstream); this checklist fills that gap with Go-idiomatic focus areas
  (error wrapping, goroutine leaks, `context`, nil maps, `defer`, etc.).

