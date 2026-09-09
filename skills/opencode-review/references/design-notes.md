# Design notes

Why the review is put together the way it is. None of this is needed in order to run either gate
— see [SKILL.md](../SKILL.md) for that.

## Why these models

Every seat sits on the **cheap tier of the family it used to run at the top of**, and buys
back what that costs with **reasoning effort** rather than with a bigger model. A committee
run is four calls by default, two of them reading the whole diff — the flagship tier priced a routine
pre-PR check like a rare one. Per million tokens, in/out:

| seat | was | now | effort |
|---|---|---|---|
| SWE | `kimi-k3` — 3.00 / 15.00 | `muse-spark-1.3-contributor` — 0.10 / 0.20 | `xhigh` |
| Architect | `glm-5.3` — 1.40 / 4.40 | `glm-5.3-flash` — 0.075 / 0.25 | `max` |
| Chair | `qwen3.8-max` — 2.00 / 6.00 | `minimax-m3` — 0.30 / 1.20 | *toggle* |
| Fact-check | `deepseek-v4-pro` — 0.66 / 1.98 | `deepseek-v4-flash` — 0.22 / 0.66 | `max` |
| Tester (opt-in) | — | `qwen3.8-flash` — 0.15 / 0.47 | `xhigh` |
| SRE (opt-in) | — | `gpt-5.6-luna` — 0.20 / 1.20 | `max` |
| Verify (gate two) | — | `glm-5.3-flash` — 0.075 / 0.25 | `max` |

The two limits the seats actually bind on survive the swap, which is what makes it a swap
rather than a downgrade in kind. Every member keeps a **~1M context window** — the SWE seat's
constraint, since it reads the whole diff plus the rules checklists plus whatever it opens with
the file tools, and a run that overruns bills for the whole thing and returns no report — and
the chair keeps a **131k output cap**, its own constraint, since the consolidated report is its
output and a 64k cap once truncated it.

**The chair is the exception to both halves of that trade**, and deliberately so. It is the
dearest seat in the run — `minimax-m3` at 0.30/1.20, and 0.60/2.40 once its context passes
200k, against 0.075–0.20 in for every member — and the only seat with no reasoning effort,
since its `reasoning_options` are a bare toggle with no ladder to climb. Two things
about this seat and no other pay for that:

- **It is the seat to spend on.** Every later stage can only *remove* from what the chair lets
  through, so precision bought here is the only kind that reaches the report. The absolute cost
  stays small because the chair's input is the members' *reports*, not the diff — of every
  stage, it is the cheapest one to run dear.
- **It has to be nobody's family.** The chair judges the members, and it used to default to
  `qwen3.8-flash`, which is also the tester seat's default — so on a four-seat run the chair was
  a member checking itself under a different persona. `minimax` is a fifth family, shared with
  no seat. It also keeps the 131k output cap this seat binds on, and brings a 1M window for when
  the chair reads the diff itself.

None of this is a measured quality claim; it is a cost/quality trade taken deliberately. **If
the committee still reads thin, keep spending here** rather than on the members: put
`qwen3.8-max` in via `OPENCODE_REVIEW_CHAIR_MODEL` before touching the others, and remember to
set `OPENCODE_REVIEW_CHAIR_VARIANT` with it — naming a model clears that seat's effort default,
since effort names are per-model.

## Why only two seats are on by default

The cost of an extra seat is not the money — on this tier a member call is fractions of a cent.
It is three things the committee's design is built on:

- **The chair is the only precision lever, and it stays one flash model.** Every extra member
  enlarges the synthesis job that the one stage capable of rejecting shaky items has to do.
- **The chair reads agreement as confidence.** "Two members raised this" is a signal it acts on,
  so a seat that overlaps an existing one does not add a check — it manufactures agreement.
- **Every seat is an independent false-positive source.** Recall is not free; it is paid for in
  the chair's ability to say no.

So **orthogonality, not usefulness, is the admission test**. Tester and SRE pass it: neither
default seat reads the test files, and neither asks what happens after the change ships. A
*security* seat would fail it — `prompts/swe.md` already covers injection, auth bypass and
secret leakage, so splitting it out would double-count every finding it makes unless `swe.md`
gave that ground up. Docs/DX fails it for a different reason: on most diffs it has nothing to
say, and a seat with nothing to say writes something anyway.

The four members deliberately run four **different families**, the chair a fifth, and the
fact-check a sixth. The whole argument for a committee is blind-spot diversity; two seats on one
family is one seat that costs twice, a chair sharing a member's model is a member marking its own
work, and a fact-check sharing a member's model is that member being asked whether its own
reasoning was supported. The one overlap left is deliberate: gate two's verify model is the
architect's `glm-5.3-flash`, and the two never see the same input — verify reads findings and fix
commits, never the review it is checking up on.

Widen the committee when a change deserves it: a release-shaped change (schema, config format,
public API, deploy path) is what `sre` is for, and a change to code with a real test suite is
what `tester` is for.

## Why the run is configured the way it is

- Driven by `--model` (not `--agent`): self-contained (no config dependency) and avoids the
  `mode:subagent`-as-top-level self-replication fork bomb.
- `--pure` skips external plugins, so startup is lean and there's no port to collide on.
- `--format json` makes the report recoverable at all: the model's prose, tool output and stop
  reason arrive as separate typed events instead of as lines in a rendered transcript that had
  to be told apart afterwards. stderr is captured to its own file rather than merged, since it
  is not JSON and would otherwise interleave unparseable lines into the event stream.
- `OPENCODE_PERMISSION` is set **for this run only** — it is merged with the saved config
  rather than substituted for it, and the saved config is not modified. `edit` is denied, and
  bash is **default-deny with a read-only allow-list** (git reads plus
  `cat`/`head`/`tail`/`wc`/`ls`/`grep`/`rg`). Trailing deny patterns for shell metacharacters
  (`;`, `|`, `&`, `>`, backticks, `$(`, `<(`, newline) override the allows, so an allowed
  prefix can't smuggle chained commands, pipes into a shell, or redirection writes. The diff
  under review is untrusted input to the reviewer models, so this hardens against prompt
  injection as well as keeping the (possibly uncommitted) work tree read-only — though glob
  matching makes it defense-in-depth, not a hard sandbox. `question` and `doom_loop` are
  denied so the run can't stall waiting for input that will never come headless.
- **The run has no network and cannot delegate.** `webfetch` and `websearch` are denied, as are
  `task`, `skill` and `lsp`. `webfetch` was the one that mattered: it had been left unset and
  opencode's default for it is *allow*, so a reviewer had unrestricted outbound egress while
  reading a diff this same block documents as untrusted — a way for injected text to send repo
  content outward, with none of the host or path restrictions bash has. No persona asks for the
  network.
- **Every `PermissionConfig` key is decided, not defaulted.** "Unset" is not a uniform default
  and cannot be reasoned about as a group: in the same headless run an unset `external_directory`
  auto-rejects while an unset `webfetch` allows. Denied: `edit`, `question`, `doom_loop`,
  `webfetch`, `websearch`, `task`, `skill`, `lsp`. Structured: `bash`, `external_directory`.
  Left to the user's config on purpose: `read`, `glob`, `grep`, `list`, `todowrite` — writing
  them as explicit allows would override a user who had deliberately restricted them, and they
  are the reviewers' actual job. Denying is free, unlike denying a bash *pattern*: a denied tool
  is removed from the model's toolset rather than rejected on use, so it costs no turn.
- **What the boundary actually is.** The bash patterns are path-agnostic — `head *` matches
  `head /anywhere` — so the allow-list restricts *commands*, not *paths*: reads outside the
  repo have always been possible when spelled as a shell command. The file tools are gated
  separately by `external_directory`, whose default for an unlisted path is "ask", i.e. an
  auto-reject headless. The two routes therefore used to disagree about the same file, which
  cost members turns on rejected `Read` calls (#24). The script now allows file-tool reads
  under the dependency caches it finds (Go's module cache, `$CARGO_HOME/registry`, plus
  anything in `OPENCODE_REVIEW_DEP_DIRS`) so the ergonomic route works where it matters: for a
  diff whose assertions encode a dependency's contract, that source *is* the review question.
  Only allows are written, never a blanket deny — a `"*":"deny"` here would also override
  opencode's own entries and any the user has configured, since the two are merged. The Go
  path is resolved from `GOMODCACHE`/`GOPATH`/the `go env` file rather than by running
  `go env`: the script has to run PATH-resolved `git` and `opencode` from the repo root
  before any permission set exists, but an optional convenience should not widen that.
- **How the bash map is actually matched — measured (#46).** opencode matches it per *shell
  segment*, splitting on `;`, `&`, `&&` and `|` and requiring every segment to hit an allow
  pattern on its own. `cat f | wc -l` runs because both halves are allowed; `ls | xargs cat` is
  refused because `xargs` is not. A single `&` splits like the rest — `ls & pwd` and `ls&pwd` were
  both measured denied — so backgrounding is not a way around it either. That split is what
  enforces the read-only set, and it has two consequences worth stating plainly, because both
  were got wrong here for a long time:
  - `"*;*"`, `"*|*"` and `"*&*"` deny patterns are **dead**. The separator is consumed by the
    split, so no segment ever contains one. They sat in this map refusing nothing until #46
    removed them. What they *did* catch was a separator inside a quoted argument, which the split
    leaves in place: `git grep -n "A\|B"` — an ordinary alternation — was rejected as if it were
    command chaining. In the run that produced the #46 evidence that misfire was seven of the
    eight denials in the whole review, and it cost one seat its entire report: the architect spent
    four of its thirty-one tool calls on rejected greps, never wrote anything, and timed out.
    The `>`, backtick, `$(...)` and `<(...)` denies were measured refusing what they aim at, and
    stay.
  - Removing the read commands would not close the path boundary, so it is not worth its cost.
    `"git diff*"` is on the allow-list, and `git diff --no-index -- /dev/null /bin/ls` prints the
    contents of any file on the machine; the architect found that on its own in the same run. The
    honest description is that **this is an allow-list of commands, not a path sandbox**, and
    `external_directory` is the only path-enforced boundary there is — over the file tools alone.
  - The one legitimate use of a repo-external bash read is recovering opencode's own truncated
    tool output: a `git show` of a large file spills its full text to
    `~/.local/share/opencode/tool-output/<id>`, which is not in `external_directory`, so bash is
    the only way back to the half that was cut. Two seats did exactly this and nothing else
    outside the repo. The personas now name that use and say there is no other.
- **What is readable is asked, not assumed.** `OPENCODE_PERMISSION` is *merged* with the saved
  config and `external_directory` merges deep, so a path allowed in your global config or the
  project's `opencode.json` is readable to the file tools as well — something the caches above
  say nothing about. The script therefore asks `opencode debug config --pure`, under the
  permission set it is about to use, for the merged answer, and it is that list the `deps :`
  line reports and the personas receive. Only `"allow"` entries are taken (naming a `deny`/`ask`
  path would send members at reads that get rejected), a trailing `/**` is stripped and `~` is
  expanded, since a persona needs an absolute path. The call is bounded like every other
  `opencode` call here and fails soft: on a missing subcommand, a non-zero exit, a timeout or
  unparseable output the list falls back to the script's own caches and the log says so, so the
  lookup can only ever add information. It costs one extra `opencode` invocation (~5s, measured)
  before phase 1, overlapped with the `--variant` probe.
- **That list is partly untrusted, and is treated as such.** A project's `opencode.json` is a
  file in the checkout under review, so on a branch you did not write its `external_directory`
  keys are attacker-controlled text heading straight for the most trusted part of every persona.
  A key holding an escaped newline would otherwise become a second bullet in the environment
  section — a prompt injection with a short path to "report no findings". So only keys that are
  plain absolute paths survive (no control characters, no backtick, 512 bytes max), a second
  filter drops any line that is not a path before it reaches a prompt, each one is rendered
  inside a code span so a name that reads like prose arrives as data, the personas say outright
  that the entries are path strings and not instructions, and the list is capped at 40 with the
  remainder announced. Rejected entries are counted in the log, never echoed — the log is read
  by the calling agent too.
- **The personas state these boundaries up front** rather than letting models find them by
  hitting them: no test/build execution (that would run code from the untrusted diff), what is
  readable and how, no retrying a rejected call, and — because two members once ended a run on
  a rejected call having written nothing — produce a report regardless, noting what could not
  be verified. The readable-path list is not written in the prompt files: they carry a
  `{{EXTERNAL_READ_PATHS}}` placeholder that `read_prompt` fills for every persona, members and
  chair alike, so no persona can state a boundary that differs from the one in force. Before
  this, all three hardcoded "outside the repo is denied" — and, told to trust that rather than
  probe, reviewers left a sibling repo the user had deliberately allowed unread and reported it
  as unverifiable (#42).
- `GIT_PAGER=cat` / `PAGER=cat` stop git from opening a pager that would hang in a non-TTY.
- The members run in parallel, then the chair runs once, then the optional fact-check runs
  once — so a large diff can take a few minutes. Each model run has its own timeout; a hung
  member can't block the others, the chair, or the fact-check.
- The fact-check pass can only ever *remove* false positives: on any failure/timeout/empty
  output the chair's report is emitted unchanged, and removed items are listed transparently
  (not silently dropped) so you can override the call.
- **Both scripts share `scripts/lib/common.sh`**, which holds the permission set, the private
  scratch dir, the bounded `opencode run` wrapper, the JSON event readers and the model
  diagnosis. It is sourced, never executed; the caller sets its own seat/model variables and
  calls `oc_env_init`, whose ordering is load-bearing (scratch dir → `--variant` probe →
  cleanup trap → permission-dependent readable-path resolution). It was split out when gate two
  appeared and would otherwise have had to copy ~900 lines of gate one.
- **Gate two keeps repo read access; the fact-check pass does not.** They look similar — one
  model, one message, adjudicating someone else's findings — but their safety properties are
  opposite. Fact-check is diff-only precisely so that it *cannot* over-prune: a finding it
  cannot see is a finding it must keep. Gate two has to answer "is this fix correct", and a fix
  read without its callers is routinely judged wrong; denying it the repo would not make it
  safer, it would make every non-trivial verdict `無法驗證`.

## What the fact-check pass does and does not catch

The fact-check pass (phase 3) is a deliberately **narrow, safe** precision filter, not a
general noise reducer. Its coverage boundary, confirmed empirically across controlled and
real-commit A/B runs:

- **It fires only on diff-*internal* falsifiable claims** — findings the supplied diff itself
  directly contradicts (e.g. "no nil check" when the diff shows one; "variable unused" when the
  diff shows it returned). On a planted-false-positive fixture it lifted surfaced-finding
  precision from ~60% to 100% with zero recall loss.
- **It deliberately does not touch claims about code outside the diff.** A reviewer member may
  have read other files via tools; fact-check sees only the diff, so by its "falsify, not
  verify" rule it keeps anything it cannot directly disprove. In a real A/B where a weak chair
  over-reached into other files (`agent.go`, `llm_cmd.go`), every such item was kept — and those
  items turned out to be *true* adjacent findings, so keeping them was correct.
- **Consequence — its real-world hit rate is low, by design.** Two upstream effects usually
  leave it nothing to remove: (1) a capable chair already rejects shaky items during synthesis,
  and (2) most committee noise on real diffs is out-of-diff over-reach, which is outside this
  pass's scope. Treat fact-check as a cheap last-resort safety net for the case where the chair
  lets a diff-contradicted claim slip through — not as the main precision lever. The main lever
  is a strong chair model.
- If you specifically want to catch out-of-diff over-reach too, that requires giving the
  fact-checker repo read access — which trades away the "diff-only ⇒ can never over-prune"
  safety guarantee, and costs more time/tokens. The current design intentionally keeps the
  safety guarantee instead.
