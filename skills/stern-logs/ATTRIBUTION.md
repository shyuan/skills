# Attribution

This skill documents [stern](https://github.com/stern/stern), which is licensed under the
Apache License 2.0.

No stern source or documentation files are bundled verbatim. The flag tables, template-function
tables, and examples in `SKILL.md` and `references/` are **derived** from stern's `README.md` and
verified against the source at the **`v1.34.0` tag**; several short example commands are adapted
from that README.

## Verifying against a new release

**Check out the release tag, not the default branch.** The first version of this skill was written
against a working tree that sat five commits past `v1.34.0`, and documented two unreleased commits
as if they had shipped: `.Timestamp` / raw-`.Message` under `--timestamps` (#372) and dotted-key
nesting in `extractJSONParts` (#373). Neither exists in the released binary users install, and the
resulting errors were invisible to source reading — only running the real binary caught them.

```bash
git -C <stern checkout> describe --tags     # must print a bare tag, e.g. v1.34.0
git -C <stern checkout> checkout v1.35.0    # not master/main
```

Then re-verify:

- the flag table in stern's `README.md` (auto-generated from the flag set)
- `cmd/cmd.go` for validation rules (e.g. `--no-follow` vs `--tail=0`, `--condition` constraints)
  and the `--max-log-requests` defaults
- `stern/tail_utils.go` for the `Log` struct fields exposed to templates and `-o json`
- `stern/tail.go` for the `PodLogOptions` stern actually sends (e.g. whether `Previous` is set)
- `stern/resource_matcher.go` for supported `<resource>/<name>` kinds and aliases
- `stern/container_state.go` and `stern/target.go` for container-state matching

Finally, **run the installed binary**. `--stdin` exercises templates and line filtering with no
cluster:

```bash
printf '{"level":"error","msg":"boom","nested":{"k":"v"}}\n' \
  | stern --stdin --template='{{with $m := .Message | tryParseJSON}}{{$m.level}} {{$m.nested.k}}{{end}}{{"\n"}}'
```

Upstream license: https://github.com/stern/stern/blob/master/LICENSE
