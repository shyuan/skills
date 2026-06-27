# Rule docs attribution

The `*.md` rule checklists in this directory are derived from Alibaba's
**open-code-review** project (`internal/config/rules/rule_docs/`), licensed under
the Apache License 2.0.

They are bundled here so the OpenCode reviewer committee can inject a
file-type-specific review checklist into each member's persona — mirroring how
open-code-review matches a path-based rule to every changed file before review.

Upstream: https://github.com/alibaba/open-code-review (Apache-2.0)

## Local additions (not from upstream)

- `go.md` — written for this skill. open-code-review supports `.go` files in its
  allowlist but ships no Go-specific rule doc (Go falls back to `default.md`
  upstream); this checklist fills that gap with Go-idiomatic focus areas
  (error wrapping, goroutine leaks, `context`, nil maps, `defer`, etc.).

