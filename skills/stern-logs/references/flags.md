# stern flag reference

Accurate for stern **v1.34.0**. `stern --help` is authoritative; `stern --show-hidden-options`
reveals the inherited client-go flags (most Kubernetes flags are hidden except `--kubeconfig` and
`--context`).

```
stern pod-query [flags]
```

## Selection

| flag | default | purpose |
|---|---|---|
| *(positional)* `pod-query` | — | pod-name regex, or `<resource>/<name>` for an exact resource |
| `--all-namespaces`, `-A` | `false` | tail across all namespaces; overrides `--namespace` |
| `--namespace`, `-n` | context default | repeatable or comma-separated |
| `--context` | — | kubeconfig context |
| `--kubeconfig` | `$KUBECONFIG` | overrides the env var |
| `--container`, `-c` | `.*` | container name regex |
| `--exclude-container`, `-E` | `[]` | container name regex to exclude (repeatable) |
| `--exclude-pod` | `[]` | pod name regex to exclude (repeatable) |
| `--container-state` | `all` | `running`, `waiting`, `terminated`, `all` (repeatable/comma-separated) |
| `--init-containers` | `true` | include init containers |
| `--ephemeral-containers` | `true` | include ephemeral containers |
| `--selector`, `-l` | — | label selector; if set, pod-query defaults to `.*` |
| `--field-selector` | — | field selector; if set, pod-query defaults to `.*` |
| `--node` | — | filter by node name |
| `--condition` | — | `condition-name[=value]`, value defaults to `true`, case-insensitive. **Only with `--tail=0` or `--no-follow`.** Valid names: `Ready`, `ContainersReady`, `Initialized`, `PodScheduled`, `DisruptionTarget`, `PodReadyToStartContainers` |
| `--prompt`, `-p` | `false` | interactive picker for `app.kubernetes.io/instance` values |

Resources accepted in `<resource>/<name>`: `pod`/`po`, `replicationcontroller`/`rc`,
`service`/`svc`, `daemonset`/`ds`, `deployment`/`deploy`, `replicaset`/`rs`, `statefulset`/`sts`,
`job` (plural forms also work; `job` has no short alias).

## Volume and lifetime

| flag | default | purpose |
|---|---|---|
| `--no-follow` | `false` | exit once all logs have been shown — **required for non-interactive use** |
| `--tail` | `-1` | lines from the end, per container; `-1` = all. `--tail=0` = only new lines, and is incompatible with `--no-follow` |
| `--since`, `-s` | `48h0m0s` | relative duration (`5s`, `2m`, `3h`) |
| `--max-log-requests` | `-1` | concurrent log requests. Resolves to **5 with `--no-follow`** (throttle) or **50 without** (error on exceed) |
| `--qps` | `0` | API QPS; `-1` disables client-side throttling |
| `--burst` | `0` | API burst; ignored when `--qps=-1` |

## Line filtering

| flag | default | purpose |
|---|---|---|
| `--include`, `-i` | `[]` | only lines matching the regex (repeatable) |
| `--exclude`, `-e` | `[]` | drop lines matching the regex (repeatable) |
| `--highlight`, `-H` | `[]` | highlight matches within lines (repeatable) |

## Output

| flag | default | purpose |
|---|---|---|
| `--output`, `-o` | `default` | `default`, `raw`, `json`, `extjson`, `ppextjson` |
| `--template` | — | Go template rendered once per log line |
| `--template-file`, `-T` | — | template from a file; overrides `--template` |
| `--only-log-lines` | `false` | suppress the `+ pod` / `- pod` status lines |
| `--timestamps`, `-t` | — | `default` or `short`. The `=` cannot be omitted: `--timestamps short` silently ignores the value and uses the full format. The timestamp is prefixed into the message, not exposed as a separate field |
| `--timezone` | `Local` | e.g. `UTC`, `Asia/Taipei` |
| `--color` | `auto` | `auto` (tty only), `always`, `never` |
| `--diff-container`, `-d` | `false` | distinct colors per container |
| `--pod-colors` | — | comma-separated SGR sequences, e.g. `"32,33,34,35,36,37"` |
| `--container-colors` | — | same format; defaults to `--pod-colors`, must match its length |

## Misc

| flag | default | purpose |
|---|---|---|
| `--stdin` | `false` | read from stdin; **all Kubernetes flags are ignored** |
| `--config` | `~/.config/stern/config.yaml` | config file path (`$STERNCONFIG` also works) |
| `--completion` | — | `bash`, `zsh`, `fish` |
| `--verbosity` | `0` | klog verbosity; `6` is a good level for debugging API interaction |
| `--show-hidden-options` | `false` | list hidden (client-go) options |
| `--version`, `-v` | `false` | print version and exit |

## Config file

Defaults for any flag, at `~/.config/stern/config.yaml`:

```yaml
# <flag name>: <value>
tail: 10
max-log-requests: 999
timestamps: short
pod-colors: "32,33,34,35,36,37"
container-colors: "32;4,33;4,34;4,35;4,36;4,37;4"
```

A config file on the machine changes what a bare `stern` command does — when output looks unexpected
(e.g. timestamps you did not ask for), check it. Pass explicit flags in scripts rather than relying
on it.

## Shell completion

```sh
source <(stern --completion=zsh)                 # zsh
source <(stern --completion=bash)                # bash, after bash-completion is sourced
stern --completion=fish >~/.config/fish/completions/stern.fish
```

Completion is dynamic for `--namespace`, `--context`, `--node`, `<resource>/<name>` queries, and
flags with fixed choices. Via krew:

```bash
source <(kubectl stern --completion bash)
complete -o default -F __start_stern kubectl stern
```

## Installation

```bash
brew install stern                 # macOS / Linux
kubectl krew install stern         # as a kubectl plugin
winget install stern.stern         # Windows
go install github.com/stern/stern@latest
asdf plugin add stern && asdf install stern latest
```
