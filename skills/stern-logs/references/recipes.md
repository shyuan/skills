# stern recipes

Task-oriented commands. Every one of them terminates. Adjust `-n`/`--context` as needed.

## Debugging

### Why is this deployment failing?

```bash
# 1. what pods exist and in what state (stern only reads logs, not state)
kubectl get pods -n prod -l app=api

# 2. recent logs from every pod of the deployment, errors first pass
stern deploy/api -n prod --no-follow --tail 100 --since 30m --color never

# 3. narrow to error-ish lines across all of them
stern deploy/api -n prod --no-follow --tail 500 -i 'ERROR|FATAL|panic|Exception' --color never
```

### CrashLoopBackOff — the logs of the container that already died

**Do not add a state filter here.** A plain bounded run already gets them:

```bash
stern deploy/api -n prod --no-follow --tail 50 --color never
```

This works **only while the container is still between restarts** — no instance running, backing off.
In that window stern requests logs exactly as `kubectl logs` without `--previous` does, and the API
serves the last terminated instance, so what you get is the run that crashed. Once the container
comes up and stays up, that same command returns the *new* instance instead, and the crashed run is
reachable only via `kubectl logs --previous` (see the last section).

`--container-state` defaults to `all`, so it only ever *restricts* — and `--container-state
terminated` is the wrong restriction here, because a pod in CrashLoopBackOff is `waiting` (backing
off before the next restart), not `terminated`. It would filter out the very pod being debugged.

If the run above prints nothing, the cause is one of:

| cause | check |
|---|---|
| the window is too narrow | widen `--since` / `--tail`; a container that died an hour ago is outside `--since 5m` |
| the container never started | no container ID exists, so there are no logs at all — `kubectl describe pod` (image pull, mount, admission) |
| it crashed before writing anything | `kubectl describe pod` for exit code and reason (137 = OOMKilled) |

Use `--container-state terminated` for a different job: isolating containers that have genuinely
finished, such as the pods of a completed Job.

### Init container refuses to finish

```bash
stern pod/api-7d9f -n prod --no-follow --tail 100 --color never
```

Init containers are included by default (`--init-containers=true`); `-c <name>` picks one out.

### Pods that never became ready

```bash
stern . -n prod --condition=ready=false --no-follow --tail 20 --color never
```

Append `=false` to invert any pod condition; names are case-insensitive. The pods this finds are the
ones whose logs explain a stuck rollout.

## Searching

### One error string across a whole namespace

```bash
stern . -n prod --no-follow --since 1h --tail -1 -i 'connection refused' \
  --only-log-lines --color never --max-log-requests 20
```

`--tail -1` (all retained lines) is safe here *because* `--since` and `--include` bound the result —
never combine an unbounded `--tail` with an unbounded `--since`.

### The same, cluster-wide

```bash
stern . -A --no-follow --since 15m -i 'panic' --color never --max-log-requests 50
```

`-A` overrides `-n` entirely. The default output template gains a namespace column under `-A`.

### Exclude the noise

```bash
stern . -n mesh --no-follow --tail 200 \
  -E 'istio-proxy|linkerd-proxy' \
  --exclude-pod 'jaeger|prometheus' \
  -e 'GET /healthz|/readyz' \
  --color never
```

## Time and ordering

```bash
# with timestamps, local timezone
stern deploy/api -n prod --no-follow --tail 100 -t

# compact timestamps, fixed timezone
stern deploy/api -n prod --no-follow --tail 100 --timestamps=short --timezone UTC

# strictly chronological across pods
stern . -n prod --no-follow --since 5m --only-log-lines -t --color never | sort

# strictly pod-by-pod (no interleaving)
stern deploy/api -n prod --no-follow --tail 100 --max-log-requests 1 --color never
```

`--timestamps` keeps `.Message` raw and exposes the formatted time separately as `.Timestamp`, so a
`parseJSON` template still works with `-t` on.

## Watching (interactive only — needs a human or a background task)

```bash
stern deploy/api -n prod --tail 0            # only new lines, streams until interrupted
stern . -n staging --tail 0 -i 'ERROR'
```

If an agent must do this, run it as a background command with an explicit stop condition, and never
as a blocking foreground call.

## Piping into other tools

```bash
# app logs are JSON: strip stern's prefix, hand to jq
stern deploy/api -n prod --no-follow --tail 200 -o raw | jq -r 'select(.level=="error") | .msg'

# stern's own envelope as JSON (keeps pod/container/namespace)
stern deploy/api -n prod --no-follow --tail 200 -o json \
  | jq -r '[.podName, .message] | @tsv'

# count errors per pod
stern deploy/api -n prod --no-follow --since 1h -o json -i ERROR \
  | jq -r .podName | sort | uniq -c | sort -rn
```

## Replaying a local log file

`--stdin` ignores all Kubernetes flags and runs the file through stern's formatting/filtering:

```bash
stern --stdin -i 'ERROR' < service.log
stern --stdin --template '{{with $m := .Message | tryParseJSON}}[{{levelColor $m.level}}] {{$m.msg}}{{else}}{{.Message}}{{end}}{{"\n"}}' < service.log
```

Useful for turning a dumped JSON log into something readable without a cluster.

## Selecting a Helm release interactively

```bash
stern -p        # prompts for an 'app.kubernetes.io/instance' label value
```

Interactive — do not use from an agent; use `-l app.kubernetes.io/instance=<release>` instead.

## Running stern elsewhere

Container:

```bash
docker run ghcr.io/stern/stern --version
docker run --rm -v "$HOME/.kube:$HOME/.kube" -e KUBECONFIG="$HOME/.kube/config" \
  ghcr.io/stern/stern --no-follow --tail 50 -n prod .
```

Inside a Pod — bind this ClusterRole to the ServiceAccount:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: stern
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "watch", "list"]
```

## When stern is the wrong tool

- Pod *state*, events, restart counts, OOMKills → `kubectl get pods`, `kubectl describe pod`,
  `kubectl get events`.
- A single pod, single container, one-shot → `kubectl logs` is fine.
- **The previous instance of a container that is running now** → `kubectl logs --previous`. stern
  sets no `Previous` flag on its log request and has no equivalent option, so it can only ever show
  the current instance. The exception is the crash-loop window above: while nothing is running, the
  API serves the last terminated instance to an ordinary request, which is why that recipe works
  without `--previous`.
- Logs older than the node's retention → they are gone from the API; query the log backend instead.
