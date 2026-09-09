#!/usr/bin/env bash
#
# opencode-review / scripts/run-review.sh
#
# Self-contained, headless multi-model "reviewer committee" over the LOCAL diff
# (before any PR exists). Prints the chair's consolidated report to stdout for
# Claude Code to consume, and saves it where run-verify.sh can find it later.
#
# Self-contained = the skill ships everything: it drives opencode by MODEL
# (`opencode run --pure --format json --model <id>`), embedding each reviewer's
# persona (from ./prompts/*.md) into the message. It does NOT depend on agents
# being defined in the user's opencode.jsonc. The environment requirements are
# that the chosen models are authenticated in OpenCode (model access, not
# config), and that jq or python3 is present to read the JSON event stream.
#
# Claude Code (the caller) is the lead/orchestrator. The members fan out in
# parallel, then the chair synthesises, then an optional fact-check prunes:
#   swe        (correctness / bugs / security)      prompts/swe.md        default seat
#   architect  (design / architecture)              prompts/architect.md  default seat
#   tester     (tests / regression risk)            prompts/tester.md     opt-in
#   sre        (operability / compatibility)        prompts/sre.md        opt-in
#   chair      (dedupe + verify + fill gaps)        prompts/chair.md
#   factcheck  (prune diff-falsifiable findings)    prompts/factcheck.md
#
# The shared machinery — permission set, scratch dir, oc_run, the JSON event
# readers — lives in lib/common.sh, which run-verify.sh sources too.
#
# Run from the repository root:
#   bash run-review.sh            # detect the stage: uncommitted and/or branch vs base
#   bash run-review.sh main       # diff current branch vs "main"
#   bash run-review.sh <sha>      # a specific commit
#   bash run-review.sh ""         # force: uncommitted changes only
#
# Env overrides:
#   OPENCODE_REVIEW_SEATS        comma-separated member seats (default "swe,architect";
#                                available: swe, architect, tester, sre)
#   OPENCODE_REVIEW_PROVIDER     provider to reach the default models through, e.g.
#                                "omniroute" -> omniroute/opencode-go/glm-5.3-flash.
#                                Applies to the DEFAULTS only; an explicit *_MODEL
#                                is always a full id. Unset = direct (unchanged).
#   OPENCODE_REVIEW_SWE_MODEL      default opencode-go/muse-spark-1.3-contributor
#   OPENCODE_REVIEW_ARCH_MODEL     default opencode-go/glm-5.3-flash
#   OPENCODE_REVIEW_TESTER_MODEL   default opencode-go/qwen3.8-flash
#   OPENCODE_REVIEW_SRE_MODEL      default opencode-go/gpt-5.6-luna
#   OPENCODE_REVIEW_CHAIR_MODEL    default opencode-go/minimax-m3 (no effort ladder)
#   OPENCODE_REVIEW_{SWE,ARCH,TESTER,SRE,CHAIR,FACTCHECK}_VARIANT
#                                reasoning-effort variant for that seat (`--variant`).
#                                Defaults apply ONLY while the seat runs its DEFAULT
#                                model, since effort names are per-model; "" = none.
#   OPENCODE_REVIEW_VARIANT      variant for OPENCODE_REVIEW_MODEL (no default)
#   OPENCODE_REVIEW_MODEL        run a SINGLE model (with the SWE persona) instead
#                                of the committee
#   OPENCODE_REVIEW_AGENT        run a SINGLE pre-configured opencode agent via
#                                --agent (escape hatch; must be a mode:primary agent)
#   OPENCODE_REVIEW_FACTCHECK    1 to run the phase-3 fact-check pass, 0 to skip (default 1)
#   OPENCODE_REVIEW_FACTCHECK_MODEL  fact-check model (default opencode-go/deepseek-v4-flash)
#   OPENCODE_REVIEW_FACTCHECK_DIFF_MAX  max bytes of diff inlined into the fact-check
#                                message before it is truncated with a marker (default 200000)
#   OPENCODE_REVIEW_SAVE         1 to save the report + reviewed diff under
#                                <git-dir>/opencode-review/ for run-verify.sh, 0 to
#                                skip (default 1)
#   OPENCODE_REVIEW_RULES        0 to disable the file-type checklist injection
#   OPENCODE_REVIEW_DEP_DIRS     extra dependency-source dirs the file tools may read,
#                                colon-separated (GOMODCACHE and the cargo registry are
#                                detected automatically)
#   OPENCODE_REVIEW_TIMEOUT      per-model hard timeout in seconds (default 900)
#   OPENCODE_REVIEW_STAGGER      seconds between parallel member launches, to dodge
#                                opencode's session-init DB lock (default 3)
#   OPENCODE_REVIEW_DRY_RUN      1 to synthesise every model call (test seam; see
#                                lib/common.sh). Nothing is billed and nothing is
#                                reviewed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC_LOG_PREFIX="opencode-review"
OC_MODEL_ENV_HINT="OPENCODE_REVIEW_{SWE,ARCH,TESTER,SRE,CHAIR,FACTCHECK}_MODEL"
OC_VARIANT_ENV_HINT="OPENCODE_REVIEW_{SWE,ARCH,TESTER,SRE,CHAIR,FACTCHECK}_VARIANT"
TIMEOUT="${OPENCODE_REVIEW_TIMEOUT:-900}"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ------------------------------------------------------------- model selection
# The defaults name the models by their DIRECT provider (opencode-go/…), which is
# one account. A setup that fronts several plans with a router (OmniRoute and the
# like) exposes the same models one level down — omniroute/opencode-go/glm-5.3-flash —
# and reaching them that way is what spreads a run's calls (several of them
# concurrent) across the plans instead of stacking them on one.
#
# So the router is a PREFIX on the defaults, not a new set of defaults: hardcoding
# a router id would tie this skill to one machine's config, and every reviewer
# model would silently 404 anywhere that provider is not configured. Unset, the
# ids are exactly what they were.
#
# It deliberately does not touch an explicit *_MODEL or OPENCODE_REVIEW_MODEL:
# those are ids the caller wrote out, and prefixing them would make "the id I
# asked for" not the id that runs. Route an explicit override by spelling the
# provider into it.
PROVIDER="${OPENCODE_REVIEW_PROVIDER:-}"
PROVIDER="${PROVIDER%/}" # tolerate "omniroute/"
PROVIDER_PREFIX="${PROVIDER:+${PROVIDER}/}"

# ------------------------------------------------------------------ the seats
# A member seat is (persona file, default model, default effort, env prefix,
# what it is for). They are declared here as case arms rather than as an
# associative array because macOS ships bash 3.2, which has none.
#
# Every seat sits on the cheap tier of its family and buys quality back with
# reasoning effort rather than with a bigger model — see references/design-notes.md,
# "Why these models". The four members deliberately run four DIFFERENT families,
# the chair a fifth and the fact-check a sixth: the whole argument for a
# committee is blind-spot diversity, two seats on one family is one seat that
# costs twice, and a stage that judges another stage's output must not be the
# model that produced it.
#
# ORTHOGONALITY IS THE ADMISSION TEST, not usefulness. The chair treats "two
# members raised this" as a confidence signal, so a seat that overlaps an
# existing one does not add a check — it manufactures agreement. That is why
# there is no security seat: prompts/swe.md already covers injection, auth
# bypass and secret leakage, and splitting it out would double-count every
# finding it makes unless swe.md gave that ground up.
#
#   swe        correctness, bugs, security          — the default pair, the
#   architect  design, abstraction, coupling          two views a review needs
#   tester     test coverage, regression risk       — orthogonal: neither default
#                                                     seat reads the test files
#   sre        operability, compatibility, rollout  — orthogonal: what happens
#                                                     after this ships
SEAT_ALL="swe architect tester sre"

seat_prompt() {
  case "$1" in
  swe) printf 'swe.md' ;;
  architect) printf 'architect.md' ;;
  tester) printf 'tester.md' ;;
  sre) printf 'sre.md' ;;
  esac
}

# The heading each seat's report gets in the chair's message.
seat_label() {
  case "$1" in
  swe) printf 'SWE report (correctness/bugs/security)' ;;
  architect) printf 'Architect report (design/architecture)' ;;
  tester) printf 'Tester report (test coverage/regression risk)' ;;
  sre) printf 'SRE report (operability/compatibility/rollout)' ;;
  esac
}

# The env prefix, which is NOT always the seat id: ARCH predates this table and
# renaming it would break every existing invocation.
seat_env() {
  case "$1" in
  swe) printf 'SWE' ;;
  architect) printf 'ARCH' ;;
  tester) printf 'TESTER' ;;
  sre) printf 'SRE' ;;
  esac
}

seat_default_model() {
  case "$1" in
  # The SWE member is the seat that runs out of context first: it reads the whole
  # diff, the rules checklists, and whatever else it opens with the file tools.
  # Its default was once the only one with a small window — kimi-k2.7-code caps at
  # 262k where the others sit at ~1M — and real runs died on that ceiling, so the
  # window is a hard requirement for this seat, not a preference.
  swe) printf 'muse-spark-1.3-contributor' ;;
  architect) printf 'glm-5.3-flash' ;;
  tester) printf 'qwen3.8-flash' ;;
  # The SRE seat is deliberately not deepseek-v4-flash, which is what the
  # fact-check stage runs: fact-check exists to strike this member's weaker
  # findings, and a model does not strike its own reasoning as unsupported.
  # gpt-5.6-luna is a sixth family with room for the whole diff (1.05M ctx) and
  # an effort ladder that goes to "max".
  sre) printf 'gpt-5.6-luna' ;;
  esac
}

# Effort ladders are per-model: glm/deepseek/gpt top out at "max", muse/qwen at
# "xhigh". These are the top rung of the model above them, which is why naming
# your own model for a seat clears the default rather than passing an effort the
# new model may reject.
seat_default_variant() {
  case "$1" in
  swe) printf 'xhigh' ;;
  architect) printf 'max' ;;
  tester) printf 'xhigh' ;;
  sre) printf 'max' ;;
  esac
}

# Which seats this run uses. The two opt-in seats are OFF by default, and the
# reason is the chair rather than the money: every extra member enlarges the
# chair's synthesis job and adds an independent source of false positives, while
# the chair — the stage that rejects shaky items — stays one flash model. Widen
# the committee when a change deserves it, not by default.
SEATS="${OPENCODE_REVIEW_SEATS:-swe,architect}"
SEAT_LIST=""
for _s in $(printf '%s' "$SEATS" | tr ',' ' '); do
  case " $SEAT_ALL " in
  *" $_s "*) ;;
  *)
    log "ERROR: unknown seat '${_s}' in OPENCODE_REVIEW_SEATS. Available: $(printf '%s' "$SEAT_ALL" | tr ' ' ',')."
    exit 1
    ;;
  esac
  # Silently deduplicate: the same seat twice would run the same persona twice
  # and hand the chair two identical reports, which is exactly the manufactured
  # agreement the orthogonality rule above exists to prevent.
  case " $SEAT_LIST " in
  *" $_s "*) continue ;;
  esac
  SEAT_LIST="${SEAT_LIST}${SEAT_LIST:+ }${_s}"
done
[ -n "$SEAT_LIST" ] || {
  log "ERROR: OPENCODE_REVIEW_SEATS is empty; the committee needs at least one member."
  exit 1
}
SEAT_COUNT="$(printf '%s' "$SEAT_LIST" | wc -w | tr -d ' ')"

# Per-seat model and variant, resolved once into seat_model_<id> / seat_variant_<id>.
# printf -v rather than eval: the values come from the environment, and eval would
# make a model id holding a backtick executable.
for _s in $SEAT_LIST; do
  _env="$(seat_env "$_s")"
  eval "_m=\${OPENCODE_REVIEW_${_env}_MODEL:-}"
  eval "_v=\${OPENCODE_REVIEW_${_env}_VARIANT-__unset__}"
  printf -v "seat_model_${_s}" '%s' "${_m:-${PROVIDER_PREFIX}opencode-go/$(seat_default_model "$_s")}"
  printf -v "seat_variant_${_s}" '%s' "$(seat_variant "$_v" "$_m" "$(seat_default_variant "$_s")")"
done
unset _s _env _m _v

# Every per-seat value — the two resolved above, plus the job pid and the four
# result fields the run fills in later — lives in a variable named
# seat_<field>_<id>, reached through these two. One pair of accessors rather than
# a getter per field, because the fields are what grows when a stage is added.
seat_get() {
  local n="seat_$2_$1"
  printf '%s' "${!n-}"
}
seat_set() {
  printf -v "seat_$2_$1" '%s' "$3"
}

# One seat's outcome in the same shape every other stage reports it.
seat_note() {
  stage_note "$(seat_get "$1" st)" "$(seat_get "$1" ex)" "$(seat_get "$1" stop)"
}

# The seats that wrote no report, for the DEGRADED notice. Named, not counted:
# "architect and sre are missing" tells the reader which half of the review they
# are not getting, where "2 of 4" does not.
absent_seats() {
  local s out=""
  for s in $SEAT_LIST; do
    [ "$(seat_get "$s" ex)" = "2" ] && out="${out}${out:+, }$s"
  done
  printf '%s' "$out"
}

# The chair is the precision lever — it is what rejects the members' shaky items,
# and the fact-check pass below can only ever remove a subset of what it lets
# through. It is also the one stage that WRITES at length, since the consolidated
# report is its output, so the OUTPUT cap is the limit that binds here rather than
# the context window: qwen3.7-max capped at 64k and truncated reports. minimax-m3
# has the 131k that requirement asks for, and a 1M window for the case the chair
# reads the diff itself.
#
# It is the one seat NOT on the cheap tier, and the one seat with no reasoning
# effort: minimax-m3 costs 0.30/1.20 per Mtok (0.60/2.40 above 200k of context) —
# roughly double the dearest member — and its reasoning_options are a bare toggle,
# so there is no ladder to run it near the top of. Both are accepted here and
# nowhere else, for two reasons that only apply to this seat:
#
#   - It is the seat to spend on. Every other stage can only remove from what the
#     chair lets through, so precision bought here is the only kind that reaches
#     the report. The absolute number stays small because the chair's input is the
#     members' REPORTS, not the diff — it is the cheapest stage to run dear.
#   - It has to be nobody's family. The chair's job is to judge the members, and
#     it used to default to qwen3.8-flash — which, once the tester seat was added
#     on that same id, made the chair a member checking itself under a different
#     persona. minimax is a fifth family, shared with no seat.
#
# If the committee still reads thin, this is where to keep spending: qwen3.8-max
# via OPENCODE_REVIEW_CHAIR_MODEL (remember OPENCODE_REVIEW_CHAIR_VARIANT with it,
# since naming a model clears the seat's effort default) before touching the
# others, and widen the committee only after that.
CHAIR_MODEL="${OPENCODE_REVIEW_CHAIR_MODEL:-${PROVIDER_PREFIX}opencode-go/minimax-m3}"
# "" and not an effort name: minimax-m3 offers reasoning as a toggle, and passing
# a rung it does not have is how a stage gets refused for a reason the log calls
# a provider error.
CHAIR_VARIANT="$(seat_variant "${OPENCODE_REVIEW_CHAIR_VARIANT-__unset__}" "${OPENCODE_REVIEW_CHAIR_MODEL:-}" "")"

# Optional fact-check pass over the chair's report (port of open-code-review's
# REVIEW_FILTER_TASK: prune only findings the diff can directly falsify). Set
# OPENCODE_REVIEW_FACTCHECK=0 to skip. Defaults to a model from a different family
# than the chair (qwen): the pass is inline diff+report judgment, and its failure
# mode is over-pruning, so it rewards disciplined instruction following and faithful
# report reproduction over coding/agentic ability — and it is checking the chair, so
# sharing the chair's blind spots is the one thing it must not do. Run at "max"
# effort for the same reason the seats run near the top of their ladder: on this
# tier, effort is the cheapest quality there is.
#
# "Inline" is literally true. The diff is put in the message (scope_diff), so the
# pass has no reason to reach for a tool at all — it previously received the same
# "go and run git diff" instruction the members get, which contradicted both this
# comment and its own persona, and cost it the tool call it stopped on (#35).
#
# The cap bounds that message. Above it the diff is truncated WITH A MARKER, never
# silently: the pass may only remove what the diff contradicts, so it has to know
# when the diff is partial in order to keep findings about the part it cannot see.
#
# Validated here rather than trusted at the point of use. `[ "$n" -gt "$MAX" ]`
# with a non-numeric MAX does not error out under `set -uo pipefail` — the test
# just returns non-zero, so the else branch runs and the WHOLE diff is inlined,
# silently past the cap that is this message's only size bound. A negative value
# is worse than useless: `head -c -20` is "all but the last 20 bytes" on GNU and
# `illegal byte count` on BSD, so the same config would truncate differently per
# platform. Neither should be guessed at.
FACTCHECK_DIFF_MAX="${OPENCODE_REVIEW_FACTCHECK_DIFF_MAX:-200000}"
FACTCHECK_ENABLED="${OPENCODE_REVIEW_FACTCHECK:-1}"
FACTCHECK_MODEL="${OPENCODE_REVIEW_FACTCHECK_MODEL:-${PROVIDER_PREFIX}opencode-go/deepseek-v4-flash}"
FACTCHECK_VARIANT="$(seat_variant "${OPENCODE_REVIEW_FACTCHECK_VARIANT-__unset__}" "${OPENCODE_REVIEW_FACTCHECK_MODEL:-}" max)"

SINGLE_MODEL="${OPENCODE_REVIEW_MODEL:-}"
# The single-model escape hatch has no default variant: the model is the caller's
# choice, so its effort ladder is unknown here.
SINGLE_VARIANT="${OPENCODE_REVIEW_VARIANT:-}"
SINGLE_AGENT="${OPENCODE_REVIEW_AGENT:-}"
# Delay between launching parallel members. opencode's session sqlite can hit
# "database is locked" if two runs start within the same session-init write
# window; a few seconds' stagger avoids that startup race while keeping the
# members overlapping for the bulk of the run.
STAGGER="${OPENCODE_REVIEW_STAGGER:-3}"
SAVE_ENABLED="${OPENCODE_REVIEW_SAVE:-1}"

case "$FACTCHECK_DIFF_MAX" in
'' | *[!0-9]*)
  log "ERROR: OPENCODE_REVIEW_FACTCHECK_DIFF_MAX must be a non-negative integer (got '${FACTCHECK_DIFF_MAX}')."
  exit 1
  ;;
esac

# ---------------------------------------------------------- choose the target
detect_base() {
  local b c
  b="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null |
    sed 's#refs/remotes/origin/##')"
  if [ -n "$b" ]; then
    printf '%s' "$b"
    return
  fi
  for c in main master; do
    git show-ref --verify --quiet "refs/heads/$c" && {
      printf '%s' "$c"
      return
    }
  done
  printf 'main'
}

# uncommitted_files prints every path carrying uncommitted work: tracked
# modifications, staged changes, and untracked-but-not-ignored files.
uncommitted_files() {
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } 2>/dev/null | sed '/^$/d' | sort -u
}

# ------------------------------------------------------------- stage detection
# Which review stage this run is in. "Committed on a branch" and "still in the
# working tree" are INDEPENDENT facts, not a chain, so they are measured
# separately:
#
#   (a) uncommitted  work in the working tree, nothing committed yet
#   (b) branch       committed on a branch, no PR
#   (a+b) both       BOTH are true -> review the union, and say so
#   (c) pushed       the branch is on the remote, so a PR may already exist
#
# Chaining them is a silent mis-target. The previous `if dirty; then uncommitted;
# else branch; fi` reviewed a branch's commits only when the tree happened to be
# spotless — so a branch carrying the real work plus one stray untracked file
# reviewed the stray file, skipped every commit, and logged a scope line that
# read as perfectly correct.
#
# (c) is detected but never handled: this skill is the pre-PR path and runs no gh
# (see SKILL.md). Detecting it is what lets the run stop ASSERTING that no PR
# exists — that claim was injected into every member's prompt unconditionally,
# and it is false the moment a PR is open.
CUR="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
BASE="$(detect_base)"

AHEAD=0
if [ "$CUR" != "$BASE" ] && git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
  AHEAD="$(git rev-list --count "${BASE}..HEAD" 2>/dev/null || printf 0)"
fi

DIRTY_LIST="$(uncommitted_files)"
DIRTY=0
[ -n "$DIRTY_LIST" ] && DIRTY="$(printf '%s\n' "$DIRTY_LIST" | wc -l | tr -d ' ')"

# Evidence that the branch reached the remote, where a PR could have been opened
# against it. Two independent signals, because either alone misses:
#   @{upstream}                 set by `git push -u` / a tracked checkout
#   refs/remotes/<remote>/<cur> present after any plain `git push origin <br>`,
#                               which sets no upstream at all
# Guarded on CUR != HEAD: detached HEAD would otherwise match refs/remotes/*/HEAD
# (origin/HEAD exists in most clones) and report every detached run as pushed.
UPSTREAM="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
REMOTE_REF=""
if [ "$CUR" != "HEAD" ] && [ "$CUR" != "$BASE" ]; then
  REMOTE_REF="$(git for-each-ref --format='%(refname:short)' "refs/remotes/*/${CUR}" 2>/dev/null | head -1)"
fi
PUSHED=0
[ "$CUR" != "$BASE" ] && { [ -n "$UPSTREAM" ] || [ -n "$REMOTE_REF" ]; } && PUSHED=1
PUSHED_VIA="${UPSTREAM:-$REMOTE_REF}"

# The prompt never states whether a PR exists, in either direction.
#
# It used to assert "There is no pull request yet" whenever no upstream was set —
# but a branch pushed as `git push origin <branch>` sets no upstream while being
# very much on the remote, so the assertion was false exactly when it mattered.
# Widening the check does not fix the class: a remote-tracking ref can be stale,
# and a branch pushed from another machine and never fetched here leaves no local
# trace at all. Absence of evidence is not evidence of absence, and short of
# running gh — which this skill does not do — the local repo cannot settle it.
#
# So the claim is dropped rather than made more accurate. The half that carries
# the actual instruction is unconditionally true and is all the models need; PR
# existence was never something they had to act on. PUSHED now feeds only the
# operator-facing warning below, where a false positive costs nothing.
PR_NOTE="Review from the local git state only; do not run any gh command."

MSG_UNCOMMITTED="Review the current UNCOMMITTED changes in this repo: combine git diff, git diff --cached, and untracked files from git status --short."

# SCOPE_MODE/SCOPE_ARG are recorded alongside the human-readable SCOPE so the
# rule-matching step (below) can re-derive the exact list of changed files.
# An explicit argument always wins: it is how you ask for one side on purpose
# when both are present ("" forces the working tree, a base name forces the
# branch diff), which is why no separate stage-override knob exists.
if [ "$#" -ge 1 ]; then
  arg="$1"
  if [ -z "$arg" ]; then
    SCOPE="uncommitted changes (forced)"
    SCOPE_MODE="uncommitted"
    MSG="${MSG_UNCOMMITTED} ${PR_NOTE}"
  else
    SCOPE="explicit target '${arg}'"
    SCOPE_MODE="target"
    SCOPE_ARG="$arg"
    MSG="Review target: ${arg}. Interpret it as a commit SHA (git show <sha>) or a branch name to diff against HEAD (git diff <branch>...HEAD). ${PR_NOTE}"
  fi
elif [ "$AHEAD" -gt 0 ] && [ "$DIRTY" -gt 0 ]; then
  SCOPE="branch '${CUR}' vs '${BASE}' (${AHEAD} commits) + ${DIRTY} uncommitted files"
  SCOPE_MODE="both"
  SCOPE_ARG="$BASE"
  MSG="Review BOTH of the following together, as one change set: (1) the diff of the current branch against ${BASE}: git diff ${BASE}...HEAD; and (2) the uncommitted changes layered on top of it: git diff, git diff --cached, and untracked files from git status --short. They are the same in-progress work at two different points, so judge them as a whole. ${PR_NOTE}"
elif [ "$DIRTY" -gt 0 ]; then
  SCOPE="uncommitted changes"
  SCOPE_MODE="uncommitted"
  MSG="${MSG_UNCOMMITTED} ${PR_NOTE}"
elif [ "$AHEAD" -gt 0 ]; then
  SCOPE="branch '${CUR}' vs '${BASE}'"
  SCOPE_MODE="branch"
  SCOPE_ARG="$BASE"
  MSG="Review the diff of the current branch against ${BASE}: git diff ${BASE}...HEAD. ${PR_NOTE}"
else
  log "Nothing to review: working tree is clean and no commits ahead of '${BASE}'. Done."
  exit 0
fi

# Say which stage was chosen AND what it left out, so a wrong call is visible in
# the log instead of silently shaping the review.
case "$SCOPE_MODE" in
both)
  log "stage : (a+b) branch '${CUR}' vs '${BASE}'"
  log "        ${AHEAD} commits + ${DIRTY} uncommitted files, BOTH included"
  ;;
uncommitted)
  log "stage : (a) uncommitted — ${DIRTY} files in the working tree"
  [ "$AHEAD" -gt 0 ] &&
    log "        NOT included: ${AHEAD} commits on '${CUR}' vs '${BASE}' (excluded by argument)"
  ;;
branch)
  log "stage : (b) branch '${CUR}' vs '${BASE}' — ${AHEAD} commits"
  [ "$DIRTY" -gt 0 ] &&
    log "        NOT included: ${DIRTY} uncommitted files (excluded by argument)"
  ;;
target)
  log "stage : explicit target '${SCOPE_ARG}'"
  [ "$DIRTY" -gt 0 ] &&
    log "        NOT included: ${DIRTY} uncommitted files (excluded by argument)"
  ;;
esac
[ "$PUSHED" -eq 1 ] &&
  log "WARN  : '${CUR}' is on the remote as '${PUSHED_VIA}' — a PR may exist. This skill is the PRE-PR path and runs no gh; review an open PR in the OpenCode TUI instead."

# ------------------------------------------------------- file-type rule matching
# Port of open-code-review's path-based rule injection: each changed file is
# mapped (first-match-wins) to a review checklist under prompts/rules/, the union
# of which is appended to every member's persona so each model's attention is
# focused on what actually matters for the file types in this diff. Disable with
# OPENCODE_REVIEW_RULES=0.
# RULES_DIR comes from lib/common.sh, which resolves it from its own location.
RULES_ENABLED="${OPENCODE_REVIEW_RULES:-1}"

# map_rule <path> -> rule doc filename. Mirrors the ordering of
# open-code-review/internal/config/rules/system_rules.json (specific filenames
# before extensions); unmatched paths fall back to default.md.
map_rule() {
  local p bn ext
  p="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  bn="${p##*/}"
  ext="${bn##*.}"
  case "$bn" in
  pom.xml) printf 'pom_xml.md\n'; return ;;
  build.gradle) printf 'build_gradle.md\n'; return ;;
  package.json) printf 'package_json.md\n'; return ;;
  cargo.toml) printf 'cargo_toml.md\n'; return ;;
  *mapper*.xml | *dao*.xml) printf 'mapper_dao_xml.md\n'; return ;;
  esac
  case "$ext" in
  properties) printf 'properties.md\n' ;;
  json | json5) printf 'json.md\n' ;;
  yaml | yml) printf 'yaml.md\n' ;;
  go) printf 'go.md\n' ;;
  java) printf 'java.md\n' ;;
  ets) printf 'arkts.md\n' ;;
  ts | js | tsx | jsx) printf 'ts_js_tsx_jsx.md\n' ;;
  kt) printf 'kotlin.md\n' ;;
  rs) printf 'rust.md\n' ;;
  cpp | cc | hpp) printf 'cpp.md\n' ;;
  c) printf 'c.md\n' ;;
  *) printf 'default.md\n' ;;
  esac
}

# target_is_bare_commit <ref> — true when an explicit target names a commit and
# not a ref, i.e. `git show <it>` is right and `git diff <it>...HEAD` is not.
#
# The single point where that is decided, because it was decided in two places
# and got it wrong in both. Checking only `refs/heads/<it>` treats anything
# outside refs/heads as a bare commit — so `run-review.sh origin/main`, the
# obvious way to review a feature branch against the remote's main, resolved as a
# commit and reviewed origin/main's tip instead of diffing against it.
#
# `--symbolic-full-name` settles it in one test: empty for a raw SHA, and the
# full ref path for anything that names one, which covers local branches
# (refs/heads), remote-tracking branches (refs/remotes) and tags (refs/tags)
# alike. All three are things to diff against; only a SHA is a thing to show.
target_is_bare_commit() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1 || return 1
  [ -z "$(git rev-parse --symbolic-full-name "$1" 2>/dev/null)" ]
}

# changed_files prints the affected paths for the resolved scope (one per line).
# It must cover exactly what MSG told the members to review — a path missing here
# gets no file-type checklist, so the models review it with the wrong focus.
changed_files() {
  case "$SCOPE_MODE" in
  uncommitted)
    uncommitted_files
    ;;
  branch)
    git diff --name-only "${SCOPE_ARG}...HEAD" 2>/dev/null
    ;;
  both)
    git diff --name-only "${SCOPE_ARG}...HEAD" 2>/dev/null
    uncommitted_files
    ;;
  target)
    if target_is_bare_commit "$SCOPE_ARG"; then
      git show --name-only --pretty=format: "$SCOPE_ARG" 2>/dev/null
    else
      git diff --name-only "${SCOPE_ARG}...HEAD" 2>/dev/null
    fi
    ;;
  esac
}

# ------------------------------------------------------------ fact-check input
# scope_diff prints the diff itself for the resolved scope, mirroring
# changed_files. Only the fact-check stage uses it: members are given the
# instruction form so they can explore the repo around what they read, whereas
# fact-check is defined as judging the report against the supplied diff and
# nothing else. It was being handed the same instruction, so it had to spend a
# tool call fetching the diff before it could begin — which is where it stopped
# (#35).
#
# Untracked files have no diff, so they are rendered against /dev/null to appear
# as the additions they are. --no-index is what makes that work on a path git is
# not tracking.
# --no-color throughout: a user with color.ui=always gets ANSI even when stdout is
# a file, and this output goes into a prompt where escape sequences are noise the
# model has to read past.
scope_diff() {
  local f
  case "$SCOPE_MODE" in
  uncommitted)
    git diff --no-color HEAD 2>/dev/null
    scope_diff_untracked
    ;;
  branch)
    git diff --no-color "${SCOPE_ARG}...HEAD" 2>/dev/null
    ;;
  both)
    git diff --no-color "${SCOPE_ARG}...HEAD" 2>/dev/null
    git diff --no-color HEAD 2>/dev/null
    scope_diff_untracked
    ;;
  target)
    if target_is_bare_commit "$SCOPE_ARG"; then
      git show --no-color "$SCOPE_ARG" 2>/dev/null
    else
      git diff --no-color "${SCOPE_ARG}...HEAD" 2>/dev/null
    fi
    ;;
  esac
}

# Untracked files rendered as the additions they are. A symlink is emitted as
# `new file mode 120000` plus its target path, not the target's contents, so this
# does not pull anything outside the tree into the prompt.
scope_diff_untracked() {
  local f
  git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    git diff --no-color --no-index -- /dev/null "$f" 2>/dev/null
  done
}

# build_rules_block prints a checklist section (union of matched rule docs, with
# the files each one covers), or nothing when disabled / no files / no docs.
# Filenames from git are untrusted input: they are only ever passed around as
# data (variables, pipes), never re-parsed by the shell — no eval anywhere.
build_rules_block() {
  [ "$RULES_ENABLED" = "0" ] && return 0
  [ -d "$RULES_DIR" ] || return 0

  local files doc docs="" f cov out=""
  files="$(changed_files | sed '/^$/d' | sort -u)"
  [ -z "$files" ] && return 0

  # Pass 1: the distinct rule docs, in first-appearance order.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    doc="$(map_rule "$f")"
    case " $docs " in *" $doc "*) ;; *) docs="$docs $doc" ;; esac
  done <<EOF
$files
EOF

  # Pass 2: per doc, re-match to list the files it covers.
  for doc in $docs; do
    [ -f "$RULES_DIR/$doc" ] || continue
    cov="$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ "$(map_rule "$f")" = "$doc" ] && printf '%s\n' "$f"
    done | paste -sd ', ' -)"
    out="${out}
### Checklist for: ${cov}
$(cat "$RULES_DIR/$doc")
"
  done

  [ -z "$out" ] && return 0
  printf '\n--- File-type review checklist (focus areas for the files in this diff) ---\n%s\n' "$out"
}
# --------------------------------------------------------------- environment
# Every variant this run will actually pass, so the --variant probe only arms its
# warning for a flag the run used. Decided by mode: the --agent escape passes none
# (the agent carries its own model and effort), the single-model path passes only
# its own, and the committee passes every seat's plus the chair's — minus
# fact-check when that phase is off.
if [ -n "$SINGLE_AGENT" ]; then
  VARIANTS_WANTED=""
elif [ -n "$SINGLE_MODEL" ]; then
  VARIANTS_WANTED="$SINGLE_VARIANT"
else
  VARIANTS_WANTED=""
  for _s in $SEAT_LIST; do VARIANTS_WANTED="${VARIANTS_WANTED}$(seat_get "$_s" variant)"; done
  VARIANTS_WANTED="${VARIANTS_WANTED}${CHAIR_VARIANT}"
  [ "$FACTCHECK_ENABLED" != "0" ] && VARIANTS_WANTED="${VARIANTS_WANTED}${FACTCHECK_VARIANT}"
  unset _s
fi

# Creates WORK_DIR, starts the --variant probe, resolves the readable paths, and
# installs the cleanup trap. Everything below may use WORK_DIR and read_prompt.
oc_env_init "$VARIANTS_WANTED"

chair_out="$WORK_DIR/chair.out"
fc_out="$WORK_DIR/fc.out"
single_out="$WORK_DIR/single.out"
chair_rep="$WORK_DIR/chair.rep"
fc_rep="$WORK_DIR/fc.rep"
single_rep="$WORK_DIR/single.rep"
final_rep="$WORK_DIR/final.rep"

# member message = persona + the review-target instruction + file-type checklist
member_msg() { printf '%s\n\n--- Review target ---\n%s\n%s\n' "$1" "$MSG" "$RULES_BLOCK"; }

# Computed once; shared by every member (and the single-model escape). Empty when
# rule matching is disabled or no checklist applies to the changed files.
RULES_BLOCK="$(build_rules_block)"
if [ -n "$RULES_BLOCK" ]; then
  log "rules : injected file-type checklist ($(changed_files | sed '/^$/d' | sort -u | wc -l | tr -d ' ') changed files)"
else
  log "rules : none injected (disabled or no matching files)"
fi
[ "$DRY_RUN" = "1" ] &&
  log "NOTE  : DRY RUN — no model is called, nothing is reviewed, nothing is billed."

# ------------------------------------------------------------- saving the run
# The report is saved so run-verify.sh can check, later and against a different
# HEAD, whether the findings were actually addressed. Without this the only
# record is stdout and whatever gets pasted into a PR comment, and a PR comment
# is prose: it carries no base/HEAD sha, so "what changed since the review" could
# only be guessed at.
#
# Under the GIT DIR, not the work tree: it is a record about this checkout that
# must never become a file the next review reviews, and .git is already the place
# for per-checkout state that is not content. Nothing here is committed and
# nothing needs a .gitignore entry.
#
# The reviewed diff is saved alongside the report for the case the sha cannot
# cover. When the review included uncommitted work, "<head_sha>..HEAD" after the
# fact is an UPPER BOUND on the fix — it also contains the work that was already
# in the tree when the review ran and has since been committed. The saved diff is
# what lets verify tell those apart instead of assuming.
yaml_str() { # minimal YAML double-quoted scalar
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

save_run() { # $1 how the fact-check pass ended (applied|failed|skipped)
  [ "$SAVE_ENABLED" = "0" ] && return 0
  local gitdir root ts head_sha base_sha dir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
  [ -n "$gitdir" ] || return 0
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  head_sha="$(git rev-parse HEAD 2>/dev/null || printf '')"
  base_sha=""
  [ -n "${SCOPE_ARG:-}" ] && base_sha="$(git rev-parse --verify --quiet "${SCOPE_ARG}^{commit}" 2>/dev/null || printf '')"
  root="$gitdir/opencode-review"
  dir="$root/runs/${ts}-$(printf '%s' "${head_sha:-nohead}" | cut -c1-8)"
  mkdir -p "$dir" 2>/dev/null || {
    log "WARN  : could not create ${dir}; the report was NOT saved and run-verify.sh will not find it."
    return 0
  }

  {
    printf -- '---\n'
    printf 'schema: 1\n'
    printf 'generated_at: %s\n' "$(yaml_str "$ts")"
    printf 'scope: %s\n' "$(yaml_str "$SCOPE")"
    printf 'scope_mode: %s\n' "$(yaml_str "$SCOPE_MODE")"
    printf 'scope_arg: %s\n' "$(yaml_str "${SCOPE_ARG:-}")"
    printf 'branch: %s\n' "$(yaml_str "$CUR")"
    printf 'base: %s\n' "$(yaml_str "$BASE")"
    printf 'base_sha: %s\n' "$(yaml_str "$base_sha")"
    printf 'head_sha: %s\n' "$(yaml_str "$head_sha")"
    # The one field verify cannot work correctly without: it says whether
    # head_sha..HEAD is the fix exactly, or merely an upper bound on it.
    printf 'included_uncommitted: %s\n' "$([ "$SCOPE_MODE" = "uncommitted" ] || [ "$SCOPE_MODE" = "both" ] && printf 'true' || printf 'false')"
    printf 'uncommitted_files_at_review: %s\n' "$DIRTY"
    printf 'seats: %s\n' "$(yaml_str "$SEAT_LIST")"
    printf 'chair_model: %s\n' "$(yaml_str "$CHAIR_MODEL")"
    printf 'factcheck: %s\n' "$(yaml_str "$1")"
    printf -- '---\n\n'
  } >"$dir/report.md" 2>/dev/null
  cat "$final_rep" >>"$dir/report.md" 2>/dev/null
  scope_diff >"$dir/reviewed.diff" 2>/dev/null

  # A pointer file rather than a symlink: it survives a copied .git, needs no
  # readlink, and cannot dangle into whatever a stale link once pointed at.
  printf '%s\n' "${dir#"$root"/}" >"$root/latest" 2>/dev/null
  log "saved : ${dir}/report.md  (run-verify.sh reads this)"
}

# ---------------------------------------------------------------------------
# --------------------------------------------------------- single-run escapes
if [ -n "$SINGLE_AGENT" ]; then
  log "scope : ${SCOPE}"
  log "mode  : single agent '${SINGLE_AGENT}' (must be mode:primary)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (agent ${SINGLE_AGENT}) — ${SCOPE} ====="
  oc_run --agent "$SINGLE_AGENT" "$MSG" "$single_out" "" "single-agent"
  st=$?
  # A pre-configured agent carries its own prompt and is never told this script's
  # output rules — which costs nothing now: its `text` events are its report the
  # same as any other stage's, with no cooperation required.
  extract_report "$single_out" "$single_rep" "single-agent"
  ex=$?
  single_stop="$STAGE_STOP"
  cat "$single_rep"
  echo "===== END OF REVIEW ====="
  log "single-agent review: $(stage_note "$st" "$ex" "$single_stop")"
  # No model to check here — the agent carries its own. The equivalent trap is
  # config-shaped, so state it rather than checking it.
  { [ "$st" -ne 0 ] || [ "$ex" -eq 2 ]; } &&
    log "diag  : if this produced nothing, confirm agent '${SINGLE_AGENT}' exists in opencode.jsonc, is mode:primary, and names a model you have."
  [ "$st" -eq 0 ] && [ "$ex" -eq 2 ] && st=1
  exit "$st"
fi

if [ -n "$SINGLE_MODEL" ]; then
  log "scope : ${SCOPE}"
  log "mode  : single model '$(seat_desc "$SINGLE_MODEL" "$SINGLE_VARIANT")' (SWE persona)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (model ${SINGLE_MODEL}) — ${SCOPE} ====="
  oc_run --model "$SINGLE_MODEL" "$(member_msg "$(read_prompt "$PROMPTS_DIR/swe.md")")" "$single_out" "$SINGLE_VARIANT" "single-model"
  st=$?
  extract_report "$single_out" "$single_rep" "single-model"
  ex=$?
  single_stop="$STAGE_STOP"
  cat "$single_rep"
  echo "===== END OF REVIEW ====="
  log "single-model review: $(stage_note "$st" "$ex" "$single_stop")"
  { [ "$st" -ne 0 ] || [ "$ex" -eq 2 ]; } && diagnose_models "$SINGLE_MODEL"
  report_variant_support
  [ "$st" -eq 0 ] && [ "$ex" -eq 2 ] && st=1
  exit "$st"
fi

# --------------------------------------------------------------- committee flow
CHAIR_PERSONA="$(read_prompt "$PROMPTS_DIR/chair.md")"

seat_descs=""
for s in $SEAT_LIST; do
  seat_descs="${seat_descs}${seat_descs:+ + }${s}($(seat_desc "$(seat_get "$s" model)" "$(seat_get "$s" variant)"))"
done
log "scope : ${SCOPE}"
log "mode  : committee — ${seat_descs} -> chair($(seat_desc "$CHAIR_MODEL" "$CHAIR_VARIANT"))"
[ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s per model)."

echo "===== OPENCODE COMMITTEE REVIEW — ${SCOPE} ====="

# Phase 1 — every member reviews the same target in parallel, launched a few
# seconds apart so they don't collide on opencode's session-init DB lock. The
# stagger goes BETWEEN launches, so a run's startup delay grows with the
# committee rather than being paid once.
log "phase 1: ${SEAT_LIST// /, } (parallel, ${STAGGER}s stagger)"
first=1
for s in $SEAT_LIST; do
  [ "$first" -eq 1 ] || sleep "$STAGGER"
  first=0
  oc_run --model "$(seat_get "$s" model)" \
    "$(member_msg "$(read_prompt "$PROMPTS_DIR/$(seat_prompt "$s")")")" \
    "$WORK_DIR/${s}.out" "$(seat_get "$s" variant)" "$s" &
  seat_set "$s" job "$!"
done
for s in $SEAT_LIST; do
  seat_job="$(seat_get "$s" job)"
  wait "$seat_job"
  seat_set "$s" st "$?"
done
for s in $SEAT_LIST; do
  extract_report "$WORK_DIR/${s}.out" "$WORK_DIR/${s}.rep" "$s"
  seat_set "$s" ex "$?"
  seat_set "$s" stop "$STAGE_STOP"
  seat_set "$s" perr "$STAGE_PROVIDER_ERROR"
done
phase1_note=""
for s in $SEAT_LIST; do
  phase1_note="${phase1_note}${phase1_note:+, }${s}=$(seat_note "$s")"
done
log "phase 1 done: ${phase1_note}"

# Every member lost to the provider. The chair is launched anyway.
#
# An earlier version of this stopped here, on the reasoning from #30 that the
# chair and fact-check were about to burn a timeout each against the same wall.
# Measured, that reasoning no longer holds and had not been checked:
#
#   - fact-check already only runs when the chair produced a report, so it was
#     never launched in this scenario at all;
#   - a provider refusal under --format json ends the run in ~1.3s, not at the
#     900s timeout. The 45 minutes #30 recorded came from the OLD output format
#     leaving the process alive with nothing to say, which #34 removed when it
#     switched every stage to the event stream.
#
# So skipping the chair saved about a second, while risking the whole output:
# json_error cannot tell "this provider is out of quota" from "these model ids
# are wrong", and in the second case a chair on a valid model in the same
# namespace would have worked. Losing a usable degraded report to save 1.3s is
# not a trade worth making, so the run continues and only says what happened.
all_perr=1
for s in $SEAT_LIST; do
  [ -n "$(seat_get "$s" perr)" ] || all_perr=0
done
if [ "$all_perr" -eq 1 ]; then
  log "WARN: every member failed with a provider error; continuing to the chair, which may still read the diff itself."
  for s in $SEAT_LIST; do
    log "WARN:   ${s} : $(seat_get "$s" perr)"
  done
fi

# Phase 2 — the chair dedupes/verifies every report against the same target. It
# receives the extracted reports, which is what prompts/chair.md says it will get;
# a member that wrote nothing is announced as such, so the chair's own
# "note which member is absent" rule can actually fire.
log "phase 2: chair (synthesis)"
chair_msg_file="$WORK_DIR/chair.msg"
{
  printf '%s\n' "$CHAIR_PERSONA"
  printf '\n本次委員會有 %s 位委員,報告依序如下。\n' "$SEAT_COUNT"
  for s in $SEAT_LIST; do
    printf '\n===== %s [%s] =====\n' "$(seat_label "$s")" "$(seat_note "$s")"
    cat "$WORK_DIR/${s}.rep"
  done
  printf '\n===== review target =====\n%s\n' "$MSG"
} >"$chair_msg_file"
chair_msg="$(cat "$chair_msg_file")"
sizes=""
for s in $SEAT_LIST; do
  sizes="${sizes}${sizes:+, }${s} $(wc -c <"$WORK_DIR/${s}.rep" | tr -d ' ')B of $(wc -c <"$WORK_DIR/${s}.out" | tr -d ' ')B captured"
done
log "phase 2: chair prompt is $(wc -c <"$chair_msg_file" | tr -d ' ') B (${sizes})"
oc_run --model "$CHAIR_MODEL" "$chair_msg" "$chair_out" "$CHAIR_VARIANT" "chair"
chair_st=$?
extract_report "$chair_out" "$chair_rep" "chair"
chair_ex=$?
chair_stop="$STAGE_STOP"
chair_perr="$STAGE_PROVIDER_ERROR"

# Phase 3 (optional) — fact-check the chair's report against the diff only,
# pruning findings the diff can directly falsify. On any failure the chair's
# report is emitted unchanged, so this phase can only ever reduce false positives.
fc_st=0
fc_stop=""
fc_perr=""
fc_ex=0
fc_applied=0
fc_state="skipped"
if [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ] && [ "$FACTCHECK_ENABLED" != "0" ]; then
  log "phase 3: fact-check ($(seat_desc "$FACTCHECK_MODEL" "$FACTCHECK_VARIANT"))"
  FACTCHECK_PERSONA="$(read_prompt "$PROMPTS_DIR/factcheck.md")"

  # The diff goes in the message. Truncation is announced in the text rather than
  # done silently, because the pass's safety property is that it only ever prunes
  # what the diff contradicts: a finding about a part it cannot see must survive,
  # and it can only apply that rule if it knows the diff is partial.
  fc_diff_file="$WORK_DIR/fc.diff"
  scope_diff >"$fc_diff_file" 2>/dev/null
  fc_diff_bytes="$(wc -c <"$fc_diff_file" | tr -d ' ')"
  if [ "$fc_diff_bytes" -gt "$FACTCHECK_DIFF_MAX" ]; then
    # Cut on a line boundary, not a byte one. `head -c` can land inside a
    # multi-byte character, and a diff is full of CJK in comments and strings;
    # dropping the partial last line costs nothing and keeps the text valid UTF-8
    # for providers that reject anything else.
    fc_diff="$(head -c "$FACTCHECK_DIFF_MAX" "$fc_diff_file" | sed '$d')
[…DIFF TRUNCATED: ${fc_diff_bytes} bytes total, first ${FACTCHECK_DIFF_MAX} shown. Findings about anything not visible above cannot be falsified from this diff — keep them.]"
    log "phase 3: diff is ${fc_diff_bytes} B, truncated to ${FACTCHECK_DIFF_MAX} B (raise OPENCODE_REVIEW_FACTCHECK_DIFF_MAX to send more)"
  else
    fc_diff="$(cat "$fc_diff_file")"
    log "phase 3: diff inlined (${fc_diff_bytes} B)"
  fi

  fc_msg="$(printf '%s\n\n===== Chair report to fact-check =====\n%s\n\n===== The diff under review (this is the ONLY evidence you may falsify against) =====\n%s\n' \
    "$FACTCHECK_PERSONA" "$(cat "$chair_rep")" "$fc_diff")"
  oc_run --model "$FACTCHECK_MODEL" "$fc_msg" "$fc_out" "$FACTCHECK_VARIANT" "factcheck"
  fc_st=$?
  extract_report "$fc_out" "$fc_rep" "factcheck"
  fc_ex=$?
  fc_stop="$STAGE_STOP"
  fc_perr="$STAGE_PROVIDER_ERROR"
  if [ "$fc_st" -eq 0 ] && [ "$fc_ex" -ne 2 ]; then
    fc_applied=1
    fc_state="applied"
    log "phase 3 done: fact-check applied"
  else
    fc_state="failed"
    log "WARN: fact-check $(stage_note "$fc_st" "$fc_ex" "$fc_stop"); emitting chair report unchanged."
  fi
fi

# The report is assembled into one file rather than printed straight out, so that
# what is saved for run-verify.sh is byte-for-byte what was shown here — including
# the degraded notice. A saved report that differs from the printed one would send
# verify after findings the user never saw.
if [ "$fc_applied" -eq 1 ]; then
  cp "$fc_rep" "$final_rep"
elif [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ]; then
  cp "$chair_rep" "$final_rep"
else
  log "WARN: chair $(stage_note "$chair_st" "$chair_ex" "$chair_stop"); falling back to the member reports."
  : >"$final_rep"
  for s in $SEAT_LIST; do
    {
      printf '## %s [%s]\n\n' "$(seat_label "$s")" "$(seat_note "$s")"
      cat "$WORK_DIR/${s}.rep"
      printf '\n'
    } >>"$final_rep"
  done
fi

# How many members actually contributed. A chair report built on no members is
# one model's opinion wearing a committee's shape — the diversity that justifies
# the whole design is gone. The chair is told to note an absence and does, but
# that lands in its preamble where a skimming reader misses it. This goes after
# the report, inside the markers, so it is the last thing read.
absent=0
for s in $SEAT_LIST; do
  [ "$(seat_get "$s" ex)" = "2" ] && absent=$((absent + 1))
done
if [ "$absent" -gt 0 ]; then
  {
    printf '\n---\n\n**DEGRADED: %d of %d members produced no report.** ' "$absent" "$SEAT_COUNT"
    # The chair's own state decides what is true here. Claiming a solo chair
    # judgment when the chair also produced nothing would describe output that
    # does not exist — above would be empty member sections.
    if [ "$absent" -eq "$SEAT_COUNT" ] && [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ]; then
      printf 'Nothing above is a committee finding — it is a solo judgment by the chair model, which read the diff itself. '
    elif [ "$absent" -eq "$SEAT_COUNT" ]; then
      printf 'The chair produced nothing either, so there is no review above at all — every stage failed. '
    else
      printf 'Missing: %s. ' "$(absent_seats)"
    fi
    printf 'See the [%s] WARN lines on stderr for what each absent stage did before stopping.\n' "$OC_LOG_PREFIX"
  } >>"$final_rep"
fi
cat "$final_rep"
echo "===== END OF REVIEW ====="
save_run "$fc_state"

# A stage that exited 0 having written no report is a failed stage: the caller
# must never be told "ok" about a run that produced nothing.
members_failed=0
for s in $SEAT_LIST; do
  { [ "$(seat_get "$s" st)" != "0" ] || [ "$(seat_get "$s" ex)" = "2" ]; } && members_failed=1
done
if [ "$chair_st" -ne 0 ]; then
  status="$chair_st"
elif [ "$chair_ex" -eq 2 ]; then
  status=1
elif [ "$members_failed" -eq 1 ]; then
  status=1
else
  status=0
fi

if [ "$status" -eq 0 ]; then
  log "committee review complete."
else
  member_notes=""
  for s in $SEAT_LIST; do
    member_notes="${member_notes}, ${s}=$(seat_note "$s")"
  done
  log "committee review finished with issues (chair=$(stage_note "$chair_st" "$chair_ex" "$chair_stop")${member_notes})."
  # Only the models that actually failed, so the report names causes rather than
  # every model the run happened to mention.
  diag_models=""
  for s in $SEAT_LIST; do
    { [ "$(seat_get "$s" st)" != "0" ] || [ "$(seat_get "$s" ex)" = "2" ]; } &&
      diag_models="$diag_models $(seat_get "$s" model)"
  done
  { [ "$chair_st" -ne 0 ] || [ "$chair_ex" -eq 2 ]; } && diag_models="$diag_models $CHAIR_MODEL"
  { [ "$fc_st" -ne 0 ] || [ "$fc_ex" -eq 2 ]; } && diag_models="$diag_models $FACTCHECK_MODEL"
  # Unquoted on purpose: this is a space-separated list being split into args,
  # and model ids cannot contain whitespace or globbing characters.
  # shellcheck disable=SC2086
  [ -n "$diag_models" ] && diagnose_models $diag_models

  # Exit 3 means: a stage failed because the PROVIDER returned an error, for a
  # model the provider does have. That is all it means, and the wording below is
  # careful to claim no more.
  #
  # It said more, through four rounds of review, and each round narrowed a claim
  # that was still too strong. The last of them was "rerunning this cannot help",
  # which the provider errors actually seen do not support:
  #
  #   Monthly usage limit reached. Resets in 1 day.   -> rerunning cannot help
  #   Provider rate limit exceeded                    -> rerunning may well help
  #   Inference is temporarily unavailable            -> rerunning may well help
  #
  # An error event says something failed at the provider. It does not say whether
  # to retry, switch, or fix credentials — and the message that DOES say, in the
  # provider's own words, is already printed on the WARN line above. So the status
  # classifies and the message advises, rather than the status guessing.
  #
  # Two conditions still gate it, because both are supportable. There has to be an
  # error event at all, which separates a provider failure from a model that
  # merely stopped. And every failed model has to be one `opencode models` lists:
  # a missing model produces the same generic UnknownError, but the cause is local
  # configuration and diagnose_models has already said so. An unchecked listing
  # claims neither.
  any_perr=""
  for s in $SEAT_LIST; do
    [ -n "$(seat_get "$s" perr)" ] && any_perr=1
  done
  if [ "$DIAG_VERDICT" = "present" ] &&
    { [ -n "$any_perr" ] || [ -n "$chair_perr" ] || [ -n "$fc_perr" ]; }; then
    log "committee review: a stage failed with a provider error, for a model the provider has. Read the provider's message on the WARN line above — it distinguishes a quota that resets, a rate limit worth retrying, and an outage."
    status=3
  fi
fi
report_variant_support
exit "$status"
