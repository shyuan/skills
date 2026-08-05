---
name: stern-logs
description: >-
  Read, filter and search Kubernetes pod logs with stern — the multi-pod,
  multi-container log tailer. Use whenever the task involves looking at logs
  from a Kubernetes cluster: debugging a failing deployment, checking why pods
  crash-loop, grepping errors across a namespace, following a rollout, or
  correlating logs across several pods. Trigger phrases: "check the logs",
  "tail the logs", "why is this pod failing", "grep the errors in namespace X",
  "看一下 log", "查 k8s 的 log", "stern", "kubectl logs but for many pods",
  "logs across all pods of deployment/service", "CrashLoopBackOff logs".
  Also covers stern's Go templates for reformatting JSON application logs and
  `--stdin` for replaying a local log file through those templates. NOT for
  writing application logging code, not for log aggregation backends
  (Loki/ELK/CloudWatch queries), and not a replacement for `kubectl get`/
  `describe` when the question is about pod state rather than log content.
---

# stern

`stern` tails logs from **many pods and many containers at once**, selected by a regex or a
Kubernetes resource, with automatic pickup of new pods and colorized per-pod output.

## Iron Law

```
In an agent/non-interactive context, every stern invocation carries --no-follow.
```

Without it stern **streams forever and never exits** — the tool call blocks until the harness
timeout, and the partial output may be discarded. The only exception: the user explicitly asked to
watch a live stream, and it runs as a background command with a stated stop condition.

The second half of the law: **bound the volume**. The defaults are `--since 48h` and `--tail -1`
(*every* line ever retained), multiplied by every matching pod. Always narrow at least one of
`--tail` / `--since`.

### Rationalization table

Every one of these will occur to you mid-task. All of them are wrong.

| The thought | Reality |
|---|---|
| "This namespace only has two pods, streaming is fine." | Pod count does not make stern exit. Two pods stream forever just as well as fifty. |
| "The user said 'watch'/'monitor'/'看一下現在的狀況', so they want live output." | They want an *answer*. `--no-follow --since 5m` gives it. Streaming into a blocked tool call gives them nothing. |
| "I'll add a timeout, that bounds it." | `timeout` exits 124 and can cut a line mid-write, so the harness may surface a failed command instead of your logs. Bound it with stern's own flags; keep `timeout` only as a belt-and-braces outer limit. |
| "It's idle, it will stop when there's nothing left." | `--no-follow` is the *only* thing that makes stern conclude "all logs shown". Idle means it waits, not exits. |
| "I'll pipe to `head`, so it ends." | It does end, but `head` keeps the *oldest* N lines it happened to see first — the opposite of the recent lines you wanted. `--tail N` selects from the end. |
| "The previous stern call worked without it." | It did not "work" — it hit the timeout, and you saw the partial output that survived. |
| "This is a follow-up to a live session, `--tail 0` is what they meant." | `--tail 0` means "only lines from now on", which by definition never terminates. It is also rejected together with `--no-follow`. |

The load-bearing test is not "is streaming reasonable here?" but **"who reads the output?"** If the
answer is you, in this tool call, then `--no-follow`.

## The default command shape

```bash
stern <query> -n <namespace> --no-follow --tail 50 --since 1h --color never --only-log-lines
```

| part | why |
|---|---|
| `--no-follow` | terminates; without it the call hangs |
| `--tail 50` | last N lines *per container* — raise deliberately, not by default |
| `--since 1h` | overrides the 48h default |
| `--color never` | no ANSI escapes to confuse parsing/diffing |
| `--only-log-lines` | drops the `+ pod ...` / `- pod ...` attach/detach status lines |

Keep the status lines (i.e. omit `--only-log-lines`) when you need to know *which pods were even
found* — that is often the actual answer.

If the task already has a familiar shape — a crash loop, hunting one error across a namespace,
getting output in chronological order, replaying a local log file — take the worked command from
[references/recipes.md](references/recipes.md) instead of composing flags from scratch.

## Selecting what to read

The positional argument is a **regex on pod names**, unless it has the form `<resource>/<name>`,
which is an exact resource lookup:

```bash
stern . --no-follow            # every pod in the namespace (regex "." matches all)
stern 'web-\w' --no-follow     # web-backend, web-frontend — but not web-123
stern deploy/nginx --no-follow # all pods belonging to that Deployment
stern svc/api --no-follow      # all pods behind that Service
```

Supported resources (with aliases): `pod`/`po`, `replicationcontroller`/`rc`, `service`/`svc`,
`daemonset`/`ds`, `deployment`/`deploy`, `replicaset`/`rs`, `statefulset`/`sts`, `job`.
Plural forms work too (`deployments/nginx`).

Narrow further with:

| need | flag |
|---|---|
| one container in multi-container pods | `-c <regex>` |
| drop a sidecar (istio, linkerd…) | `-E istio-proxy` |
| drop noisy pods | `--exclude-pod <regex>` |
| by label | `-l app=api` |
| by field | `--field-selector spec.nodeName=node-1` |
| by node | `--node node-1` |
| several namespaces | `-n a,b` (repeatable) / `-A` for all |
| only containers that have already exited (finished Jobs) | `--container-state terminated` |
| skip init/ephemeral containers | `--init-containers=false`, `--ephemeral-containers=false` |

That table is the working subset. When you need a flag that is not in it, an exact default, or the
config file that may silently be changing those defaults, read
[references/flags.md](references/flags.md) — guessing a flag name costs a failed invocation.

`--include` / `-i` and `--exclude` / `-e` filter **log lines** (regex, repeatable) — prefer them over
piping to `grep`, because they apply before the lines are formatted:

```bash
stern deploy/api --no-follow --tail 200 -i 'ERROR|panic' -e 'health.?check'
```

## Reading the result correctly

- **Empty output is not an error.** A query matching no pods exits 0 and prints nothing. Verify with
  `kubectl get pods -n <ns>` before concluding "there are no errors".
- **Lines from different pods interleave** in arrival order, not timestamp order. Piping the default
  output to `sort` sorts by *pod name*, because that is what the default template leads with. Either
  serialize the reads, or put the timestamp first with a template:
  ```bash
  stern deploy/api --no-follow --max-log-requests 1 --tail 100   # pod by pod, in order

  set -o pipefail                                                # sort exits 0 on empty input too
  stern . -A --no-follow --since 10m --only-log-lines --color never -t \
    --template='{{.Message}}  @{{.PodName}}/{{.ContainerName}}{{"\n"}}' | sort
  ```
  That works because `-t` prefixes the timestamp **into** `.Message` — which is also why `-t` breaks
  `parseJSON` templates and `-o raw | jq`. There is no separate timestamp field.
- `--max-log-requests` **never silently drops pods.** With `--no-follow` (default 5) it is a
  concurrency limit: every matching container is still read, just fewer at a time, so the output is
  complete and only slower. Without `--no-follow` (default 50) exceeding it is a hard error that
  stops stern with a message naming the flag. Raise it to go faster or to watch more pods — never
  because you suspect missing output.

## Machine-readable output

```bash
# no pipe: stern's own exit status is the answer
stern deploy/api --no-follow --tail 100 -o json --only-log-lines

# piped: pipefail belongs in the command, not in a footnote
set -o pipefail
stern deploy/api --no-follow --tail 100 -o raw --only-log-lines | jq
```

Two things make a failed query look like a clean empty one, and both are in that snippet:

- **`--only-log-lines`, not a redirect.** The `+ pod › container` attach lines go to stderr, so
  `2>&1 | jq` feeds `jq` a non-JSON line and the pipeline aborts to nothing; `2>/dev/null` avoids
  that but throws away stern's real errors (RBAC `forbidden`, a bad `--context`) along with the
  noise. `--only-log-lines` stops the status lines being printed at all and leaves errors on stderr.
- **`set -o pipefail`.** `jq` exits 0 on empty input, so without it the pipeline reports success even
  when stern failed. It is portable — prefer it. Where you cannot set it, check the *first* command's
  status rather than `$?`: `${PIPESTATUS[0]}` in bash, `${pipestatus[1]}` in zsh (lowercase, and
  1-indexed). Using the bash spelling under zsh expands to an empty string, which reads as "did not
  fail" — the exact failure this bullet exists to prevent, on the shell macOS defaults to.

For the `-o json` field names, the other predefined outputs, and `--template` for reshaping JSON
application logs into something readable, see [references/templates.md](references/templates.md).

## Preflight

1. `command -v stern` — if missing, `brew install stern` (macOS/Linux) or
   `kubectl krew install stern`; `kubectl logs` is the fallback for a single pod.
2. Know which cluster you are about to read: `kubectl config current-context`. Confirm with the user
   before pulling logs from an unfamiliar or production-looking context, and remember that log
   content may contain secrets — quote selectively rather than dumping it wholesale.
3. stern honours `$KUBECONFIG`; `--kubeconfig` and `--context` override it.

## Gotchas

| symptom | cause / fix |
|---|---|
| command hangs | missing `--no-follow` |
| `Error: --no-follow cannot be used with --tail=0` | `--tail=0` means "only *new* lines", which contradicts exiting; use `--tail 1` or drop `--no-follow` |
| `--condition` rejected | it is only supported with `--tail=0` or `--no-follow` |
| flood of output | `--since 48h` + `--tail -1` defaults across many pods |
| no logs from a crash-looping pod | not a state-filter problem: the default `--container-state all` already covers it, and stern falls back to the last terminated instance's logs. Check `--since`/`--tail` first. `--container-state terminated` would *exclude* it — CrashLoopBackOff is `waiting` |
| a container is skipped entirely | it has no container ID yet (never started — image pull failure, etc.); its logs do not exist, use `kubectl describe pod` |
| ANSI garbage in captured output | `--color never` |
| `--timestamps short` gives the long format | the `=` cannot be omitted. `--timestamps short` silently ignores the value and falls back to the full format — no error. Write `--timestamps=short`, or bare `-t` |
| `parseJSON` template suddenly hits its `else` branch | `-t` is on: it prefixes the timestamp into `.Message`. Drop `-t` when parsing JSON |
| empty result from `stern … \| anything` | either `2>&1` merged the stderr status lines into the pipe and the consumer aborted, or stern failed and the consumer returned 0 anyway — `jq`, `sort`, `grep -c`, `wc` all exit 0 on empty input. Use `--only-log-lines` and `set -o pipefail` on every stern pipeline; never `2>/dev/null`, which hides the error that explains it |
| running inside a Pod: forbidden | needs RBAC `get,watch,list` on `pods` and `pods/log` |

Each reference is linked above from the point where it becomes the right thing to read:
[recipes.md](references/recipes.md) for worked commands, [flags.md](references/flags.md) for the
complete flag set and config file, [templates.md](references/templates.md) for output formatting.
