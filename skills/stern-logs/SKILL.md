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
timeout, and the partial output may be discarded. Only drop `--no-follow` when the user explicitly
asked to watch a live stream, and then run it in the background with a bounded reason to stop.

The second half of the law: **bound the volume**. The defaults are `--since 48h` and `--tail -1`
(*every* line ever retained), multiplied by every matching pod. Always narrow at least one of
`--tail` / `--since`.

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

## Selecting what to read

The positional argument is a **regex on pod names**, unless it has the form `<resource>/<name>`,
which is an exact resource lookup:

```bash
stern .                       # every pod in the namespace (regex "." matches all)
stern 'web-\w'                # web-backend, web-frontend — but not web-123
stern deploy/nginx            # all pods belonging to that Deployment
stern svc/api --no-follow     # all pods behind that Service
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
| only crashed containers | `--container-state terminated` |
| skip init/ephemeral containers | `--init-containers=false`, `--ephemeral-containers=false` |

`--include` / `-i` and `--exclude` / `-e` filter **log lines** (regex, repeatable) — prefer them over
piping to `grep`, because they apply before the lines are formatted:

```bash
stern deploy/api --no-follow --tail 200 -i 'ERROR|panic' -e 'health.?check'
```

## Reading the result correctly

- **Empty output is not an error.** A query matching no pods exits 0 and prints nothing. Verify with
  `kubectl get pods -n <ns>` before concluding "there are no errors".
- **Lines from different pods interleave** in arrival order, not timestamp order. For a time-ordered
  reading either add `-t` and sort, or serialize the reads:
  ```bash
  stern deploy/api --no-follow --max-log-requests 1 --tail 100   # pod by pod, in order
  stern . -A --no-follow --since 5m --only-log-lines -t | sort   # timestamp-first, then sort
  ```
- `--max-log-requests` defaults to **5 with `--no-follow`** (throttles concurrency) and **50 without**
  (hard-errors when exceeded). Widening a query across a big namespace hits this — raise the limit
  explicitly rather than being surprised by a truncated picture.

## Machine-readable output

```bash
stern deploy/api --no-follow --tail 100 -o json      # one JSON object per line, stern's envelope
stern deploy/api --no-follow --tail 100 -o raw | jq  # just .Message — for apps that log JSON
```

`-o json` fields: `message`, `timestamp` (only with `--timestamps`), `nodeName`, `namespace`,
`podName`, `containerName`, `labels`, `annotations`.

To reshape JSON application logs into something readable, use `--template` — see
[references/templates.md](references/templates.md).

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
| no logs from a crash-looping pod | its container is `terminated`, not `running` → `--container-state terminated` |
| output missing pods | `--max-log-requests` limit reached |
| ANSI garbage in captured output | `--color never` |
| `--timestamps` prints nothing | value form matters: `-t`, or `--timestamps=short` with the `=` |
| running inside a Pod: forbidden | needs RBAC `get,watch,list` on `pods` and `pods/log` |

## Deeper references

- [references/recipes.md](references/recipes.md) — task-oriented cookbook (crash loops, rollouts,
  error hunting across namespaces, local file replay, running in a container/Pod).
- [references/flags.md](references/flags.md) — complete flag table, config file, shell completion.
- [references/templates.md](references/templates.md) — `--template` struct, all template functions,
  JSON-log formatting examples.
