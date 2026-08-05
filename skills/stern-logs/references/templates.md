# stern output templates

Use these when the application logs structured JSON and the raw stream is unreadable, or when you
need a specific line shape for downstream tooling.

## Predefined `--output` templates

| output | shape |
|---|---|
| `default` | `[namespace] pod container [timestamp] message`, colorized per `--color`; the namespace column appears only with `-A` or multiple `-n` |
| `raw` | the message alone — the one to pipe into `jq`, but only without `-t`, which prefixes a timestamp and stops the line being valid JSON |
| `json` | stern's envelope marshalled as JSON, one object per line |
| `extjson` | `{"pod": …, "container": …, "message": …}` with colorized names |
| `ppextjson` | the same, pretty-printed |

`-o json` field names: `message`, `nodeName`, `namespace`, `podName`, `containerName`, `labels`,
`annotations`. **There is no `timestamp` key** — not even with `--timestamps`, which instead prefixes
the timestamp into `message`.

## The template struct

`--template` compiles a Go `text/template` executed once per log line, receiving:

| property | type | notes |
|---|---|---|
| `.Message` | string | the log line — **with `--timestamps` the formatted timestamp is prefixed into it**, which breaks `parseJSON` (see below) |
| `.NodeName` | string | |
| `.Namespace` | string | |
| `.PodName` | string | |
| `.ContainerName` | string | |
| `.Labels` | map[string]string | |
| `.Annotations` | map[string]string | |
| `.PodColor` / `.ContainerColor` | `*color.Color` | pass to the `color` function |

Templates do not emit a newline on their own — end with `{{"\n"}}`.

There is **no timestamp property**. `--timestamps` works by prefixing the formatted time into
`.Message`:

```console
$ stern <pod> -n <ns> --no-follow --tail 1 -t --only-log-lines --template='[{{.PodName}}] {{.Message}}{{"\n"}}'
[my-pod-abc123] 2026-08-04T17:32:02.441931913+08:00 {"level":"error","msg":"..."}
                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ inside .Message
```

So `-t` and JSON parsing are mutually exclusive: every `parseJSON` template below falls through to
its `else` branch once `-t` is on. Referencing `.Timestamp` is a hard error —
`can't evaluate field Timestamp in type stern.Log`.

## Template functions

On top of Go's builtins:

| func | args | description |
|---|---|---|
| `json` | object | marshal as JSON |
| `color` | `color.Color, string` | wrap text in one of the provided colors |
| `parseJSON` | string | parse as JSON; **errors** on failure |
| `tryParseJSON` | string | parse as JSON; returns nil on failure (use with `with`/`else`) |
| `extractJSONParts` | string, ...keys | parse and concatenate the given **top-level** keys; a dotted key is looked up literally, so nested access silently yields `<nil>` |
| `tryExtractJSONParts` | string, ...keys | same, but returns the original text on failure |
| `prettyJSON` | any | pretty-print; passes the input through unchanged if it is not JSON |
| `toRFC3339Nano` | object | parse a timestamp (string/int/json.Number) → RFC3339Nano |
| `toTimestamp` | object, layout [, tz] | parse and format with a Go layout; timezone defaults to UTC |
| `levelColor` | string | color a textual log level (`info`/`warn`/`error`…) |
| `bunyanLevelColor` | string | color a numeric bunyan level |
| `colorBlack` `colorRed` `colorGreen` `colorYellow` `colorBlue` `colorMagenta` `colorCyan` `colorWhite` | string | fixed colors |
| `colorCustom` | string, int [, int] | SGR attributes, e.g. `{{colorCustom "Hi" 3 96}}` = italic cyan |

## Examples

Every example below carries `--no-follow --tail 50` because these are copy-ready commands, and
without it stern streams until the harness times out. Drop the bounding flags only when a human is
watching the terminal.

Plain custom line:

```bash
stern --template '{{printf "%s (%s/%s/%s/%s)\n" .Message .NodeName .Namespace .PodName .ContainerName}}' backend --no-follow --tail 50
```

Keep stern's per-pod colors:

```bash
stern --template '{{.Message}} ({{.Namespace}}/{{color .PodColor .PodName}}/{{color .ContainerColor .ContainerName}}){{"\n"}}' backend --no-follow --tail 50
```

JSON logs → level + message (non-JSON lines are dropped by `with`):

```bash
stern --template='{{.PodName}}/{{.ContainerName}} {{with $d := .Message | parseJSON}}[{{$d.level}}] {{$d.message}}{{end}}{{"\n"}}' backend --no-follow --tail 50
```

JSON logs with a fallback for plain lines — **the safest general-purpose template**:

```bash
stern --template='{{.PodName}}/{{.ContainerName}} {{with $msg := .Message | tryParseJSON}}[{{colorGreen (toRFC3339Nano $msg.ts)}}] {{levelColor $msg.level}} ({{colorCyan $msg.caller}}) {{$msg.msg}}{{else}} {{.Message}} {{end}}{{"\n"}}' backend --no-follow --tail 50
```

Pretty-print whatever is JSON, pass the rest through:

```bash
stern --template='{{ .Message | prettyJSON }}{{"\n"}}' backend --no-follow --tail 50
```

Nested fields — for `{"python": {"levelname": "INFO", "module": "router"}}`. `extractJSONParts` reads
**top-level keys only**, and a dotted key produces `<nil>` in the output rather than an error, so
parse first and walk the structure with ordinary Go template field access:

```bash
stern --template='{{with $m := .Message | tryParseJSON}}{{levelColor $m.python.levelname}} {{$m.python.module}}{{else}}{{.Message}}{{end}}{{"\n"}}' backend --no-follow --tail 50
```

`extractJSONParts` stays the shorter option when the keys are flat:

```bash
stern --template='{{ levelColor (extractJSONParts .Message "level") }} {{"\n"}}' backend --no-follow --tail 50
```

From a file, when the template gets long:

```bash
stern --template-file=~/.stern.tpl backend --no-follow --tail 50
```

## Custom colors

Colors are comma-separated [SGR sequences](https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters),
so underline / background / 8-bit / 24-bit all work if the terminal supports them:

```bash
podColors="38;2;255;97;136,38;2;169;220;118,38;2;255;216;102,38;2;120;220;232,38;2;171;157;242"
stern --pod-colors "$podColors" deploy/app --no-follow --tail 50
```

`--container-colors` defaults to `--pod-colors` and must have the same length. Both can live in the
config file (`pod-colors:` / `container-colors:`).
