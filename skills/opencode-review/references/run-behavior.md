# Run behaviour

What the run does when a stage produces nothing, refuses, or times out, and what it prints so a
bad run cannot look like a good one. See [SKILL.md](../SKILL.md) for how to invoke it.

## What a stage's report actually is

Each stage runs with **`--format json`**, so what the script captures is opencode's event
stream — one JSON object per line — not a rendered transcript. The chair's consolidated report
is printed to **stdout** between the `===== … REVIEW … =====` and `===== END OF REVIEW =====`
markers. Only the script's own progress/error lines (prefixed `[opencode-review]`) go to
**stderr**. If the chair fails or times out, the member reports are printed as a fallback so
you still have something actionable.

**A stage's report is its `text` events, and nothing else.** The event stream separates at the
source what a rendered transcript merges into undifferentiated lines:

| event | carries |
|---|---|
| `text` | the model's own words — this is the report |
| `tool_use` | every byte a tool produced, including tool *errors* |
| `step_finish` | `reason` the model stopped: `stop`, `tool-calls`, … |

So tool output cannot be mistaken for prose: it never shares a channel with it. The whole diff
each member reads, the `OPENCODE_PERMISSION` ruleset dumped on every denied bash call, a
mistyped command's shell error — all `tool_use`, none of them candidates.

This replaced a `<<<REVIEW-REPORT>>>` fence the personas had to emit, plus a de-noiser that
inferred structure from rendered output, plus a per-run nonce on the markers. That design
failed in both directions on real runs. Models that investigated for 30–70 KB and then stopped
left nothing fenced, so the fallback ran and forwarded whatever its state machine had last
seen: one run handed the chair **150 bytes of a shell error message** as the SWE report,
another **99 bytes of a model's opening narration** as the architect's — each logged as
`ok, but the report was not fenced`, which reads as a formatting nit rather than *this is not
a review*. Reading `text` events makes that class unrepresentable. It also retires the nonce,
which existed only because a fence line was authoritative wherever it appeared and members can
`cat` repository files, so the tree under review could forge one; file content is now tool
output by construction.

Requires **`jq`** (preferred) or **`python3`** to read the stream. Checked at startup, before
any model call, so a machine with neither fails immediately rather than after every stage.

A stage that exits 0 having written **no** report is reported as `NO REPORT PRODUCED`, not
`ok`, in both the log and the message handed to the chair — so `prompts/chair.md`'s "note which
member is absent" rule can fire, and the run's exit status is non-zero. A run that yielded
nothing can no longer look successful.

The event stream also says *how* it produced nothing, which are different failures worth
telling apart:

```
[opencode-review] WARN: swe: stopped after 14 tool calls without writing anything (reason=stop).
```

That is a model that read the diff, investigated, and ended its turn without writing it up —
not a model that never ran, and not a timeout. It is the failure recorded in
[issue #33](https://github.com/shyuan/skills/issues/33), where two members did it independently
on the same run. The script detects and reports it; it does not currently intervene.

**A provider refusal is reported as itself, and short-circuits the run.** opencode emits a
`{"type":"error"}` event when a request fails outright — bad model id, auth failure, quota — and
that event carries the provider's own words:

```
[opencode-review] WARN: swe: provider error: Monthly usage limit reached. Resets in 1 day.
[opencode-review] WARN: every member failed with a provider error; continuing to the chair,
                        which may still read the diff itself.
```

**No stage is skipped because of it**, and the run reports it in the exit status instead. A
refused stage ends in about a second under `--format json`, so there is nothing left to save by
giving up early — the ~45 minutes [issue #30](https://github.com/shyuan/skills/issues/30)
recorded came from the *old* output format leaving the process alive with nothing to say, which
#34 removed when it switched every stage to the event stream. (Fact-check was never part of that
cost: it only runs when the chair produced a report.)

Skipping the chair would also risk the whole output for no gain, because the error event cannot
tell *"this provider is out of quota"* from *"these two model ids are wrong"* — and in the second
case a chair on a valid model would have worked.

Exit statuses: `0` clean, `1` a stage failed, `3` a stage failed **with a provider error, for a
model the provider has**. That is the whole claim — `3` does not tell you whether to retry, and
deliberately so:

```
Monthly usage limit reached. Resets in 1 day.   -> rerunning cannot help
Provider rate limit exceeded                    -> rerunning may well help
Inference is temporarily unavailable            -> rerunning may well help
```

All three arrive as the same event. The message that distinguishes them is the provider's own,
and it is printed on the `WARN` line — so the status classifies and the message advises.

Two conditions gate `3`, both supportable from evidence. There has to be an error event, which
separates a provider failure from a model that merely stopped. And every failed model has to be
one `opencode models` lists: a *nonexistent model id* produces the same generic `UnknownError`,
but the cause there is local configuration and the `diag :` lines already say so (`1`). If the
listing could not be obtained, neither is claimed and it stays `1`.

`3` classifies a run that completed every stage — nothing is skipped to produce it.

**When members are absent, the last thing on stdout says so**, inside the report markers:

```
**DEGRADED: 2 of 4 members produced no report.** Missing: tester, sre.
**DEGRADED: 2 of 2 members produced no report.** Nothing above is a committee finding —
it is a solo judgment by the chair model, which read the diff itself.
```

Which of the two it says is decided by the chair's own state: claiming a solo chair judgment
when the chair also produced nothing would describe output that does not exist.

The chair does note an absence in its own preamble, but that lands where a skimming reader
misses it — and a chair report built on no members is one model's opinion wearing a committee's
shape, which is exactly the thing the design exists to avoid.

**When a stage fails, the log also says whether the models were even available.** opencode
says nothing about the model when the id is bad — `opencode run --model does-not-exist/at-all`
emits a bare `UnknownError: "Unexpected server error"` that never names the id — so the script
would otherwise report `NO REPORT PRODUCED` for every stage with nothing pointing at the cause.
This is the first thing anyone hits running the skill on a machine without the default provider.
So on the failure path only, the run checks the failed stages' models against `opencode models`:

```
[opencode-review] diag  : NOT available in this OpenCode setup: opencode-go/glm-5.3-flash …
[opencode-review] diag  : that alone accounts for an empty report — opencode reports only a
                          generic server error for an unusable model id, never naming it.
[opencode-review] diag  : name models you do have via OPENCODE_REVIEW_{SWE,ARCH,CHAIR,…}_MODEL,
                          or set OPENCODE_REVIEW_PROVIDER=<id> if they sit behind a router.
```

When the models *are* all present it says so too — that rules out the most likely cause and
points you at the kept events instead. `opencode models` costs ~7s, so it runs **only** after
something has already failed, at most once per run; a clean run never pays for it.

Whenever a stage produces no report, its raw event stream — and its stderr, which is captured
separately since it is not JSON — is copied into a per-run `mktemp -d` directory (mode 700) and
the path logged. Everything else the script writes lives in a private work directory removed on
exit, and a blank stage prints nothing. **If a run reports a blank stage, read that file**: the
`tool_use` events show exactly what the model was doing when it stopped.

