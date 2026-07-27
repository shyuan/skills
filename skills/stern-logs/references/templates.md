# stern output templates

Use these when the application logs structured JSON and the raw stream is unreadable, or when you
need a specific line shape for downstream tooling.

## Predefined `--output` templates

| output | shape |
|---|---|
| `default` | `[namespace] pod container [timestamp] message`, colorized per `--color`; the namespace column appears only with `-A` or multiple `-n` |
| `raw` | the message alone (plus timestamp if `-t`) — the one to pipe into `jq` |
| `json` | stern's envelope marshalled as JSON, one object per line |
| `extjson` | `{"pod": …, "container": …, "message": …}` with colorized names |
| `ppextjson` | the same, pretty-printed |

`-o json` field names: `message`, `timestamp` (omitted unless `--timestamps`), `nodeName`,
`namespace`, `podName`, `containerName`, `labels`, `annotations`.

## The template struct

`--template` compiles a Go `text/template` executed once per log line, receiving:

| property | type | notes |
|---|---|---|
| `.Message` | string | the log line; stays **raw** even with `--timestamps`, so `parseJSON` keeps working |
| `.Timestamp` | string | formatted per `--timestamps`/`--timezone`; empty unless `--timestamps` is set |
| `.NodeName` | string | |
| `.Namespace` | string | |
| `.PodName` | string | |
| `.ContainerName` | string | |
| `.Labels` | map[string]string | |
| `.Annotations` | map[string]string | |
| `.PodColor` / `.ContainerColor` | `*color.Color` | pass to the `color` function |

Templates do not emit a newline on their own — end with `{{"\n"}}`.

## Template functions

On top of Go's builtins:

| func | args | description |
|---|---|---|
| `json` | object | marshal as JSON |
| `color` | `color.Color, string` | wrap text in one of the provided colors |
| `parseJSON` | string | parse as JSON; **errors** on failure |
| `tryParseJSON` | string | parse as JSON; returns nil on failure (use with `with`/`else`) |
| `extractJSONParts` | string, ...keys | parse and concatenate the given keys; dot notation reaches nested fields (`python.levelname`) |
| `tryExtractJSONParts` | string, ...keys | same, but returns the original text on failure |
| `prettyJSON` | any | pretty-print; passes the input through unchanged if it is not JSON |
| `toRFC3339Nano` | object | parse a timestamp (string/int/json.Number) → RFC3339Nano |
| `toTimestamp` | object, layout [, tz] | parse and format with a Go layout; timezone defaults to UTC |
| `levelColor` | string | color a textual log level (`info`/`warn`/`error`…) |
| `bunyanLevelColor` | string | color a numeric bunyan level |
| `colorBlack` `colorRed` `colorGreen` `colorYellow` `colorBlue` `colorMagenta` `colorCyan` `colorWhite` | string | fixed colors |
| `colorCustom` | string, int [, int] | SGR attributes, e.g. `{{colorCustom "Hi" 3 96}}` = italic cyan |

## Examples

Plain custom line:

```bash
stern --template '{{printf "%s (%s/%s/%s/%s)\n" .Message .NodeName .Namespace .PodName .ContainerName}}' backend
```

Keep stern's per-pod colors:

```bash
stern --template '{{.Message}} ({{.Namespace}}/{{color .PodColor .PodName}}/{{color .ContainerColor .ContainerName}}){{"\n"}}' backend
```

JSON logs → level + message (non-JSON lines are dropped by `with`):

```bash
stern --template='{{.PodName}}/{{.ContainerName}} {{with $d := .Message | parseJSON}}[{{$d.level}}] {{$d.message}}{{end}}{{"\n"}}' backend
```

JSON logs with a fallback for plain lines — **the safest general-purpose template**:

```bash
stern --template='{{.PodName}}/{{.ContainerName}} {{with $msg := .Message | tryParseJSON}}[{{colorGreen (toRFC3339Nano $msg.ts)}}] {{levelColor $msg.level}} ({{colorCyan $msg.caller}}) {{$msg.msg}}{{else}} {{.Message}} {{end}}{{"\n"}}' backend
```

Pretty-print whatever is JSON, pass the rest through:

```bash
stern --template='{{ .Message | prettyJSON }}{{"\n"}}' backend
```

Nested fields via dot notation — for `{"python": {"levelname": "INFO", "module": "router"}}`:

```bash
stern --template='{{ levelColor (extractJSONParts .Message "python.levelname") }} {{ extractJSONParts .Message "python.module" }}{{"\n"}}' backend
```

From a file, when the template gets long:

```bash
stern --template-file=~/.stern.tpl backend
```

## Custom colors

Colors are comma-separated [SGR sequences](https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters),
so underline / background / 8-bit / 24-bit all work if the terminal supports them:

```bash
podColors="38;2;255;97;136,38;2;169;220;118,38;2;255;216;102,38;2;120;220;232,38;2;171;157;242"
stern --pod-colors "$podColors" deploy/app
```

`--container-colors` defaults to `--pod-colors` and must have the same length. Both can live in the
config file (`pod-colors:` / `container-colors:`).
