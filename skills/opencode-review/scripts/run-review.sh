#!/usr/bin/env bash
#
# opencode-review / scripts/run-review.sh
#
# Self-contained, headless multi-model "reviewer committee" over the LOCAL diff
# (before any PR exists). Prints the chair's consolidated report to stdout for
# Claude Code to consume.
#
# Self-contained = the skill ships everything: it drives opencode by MODEL
# (`opencode run --pure --model <id>`), embedding each reviewer's persona (from
# ./prompts/*.md) into the message. It does NOT depend on agents being defined
# in the user's opencode.jsonc. The only environment requirement is that the
# chosen models are authenticated in OpenCode (model access, not config).
#
# Claude Code (the caller) is the lead/orchestrator: it fans out to two members
# in parallel, then hands both reports to the chair:
#   SWE       (correctness / bugs / security)   prompts/swe.md
#   Architect (design / architecture)           prompts/architect.md
#   Chair     (dedupe + verify + fill gaps)     prompts/chair.md
#
# Run from the repository root:
#   bash run-review.sh            # auto-detect: uncommitted, else branch vs base
#   bash run-review.sh main       # diff current branch vs "main"
#   bash run-review.sh <sha>      # a specific commit
#   bash run-review.sh ""         # force: uncommitted changes
#
# Env overrides:
#   OPENCODE_REVIEW_SWE_MODEL    default opencode-go/kimi-k2.7-code
#   OPENCODE_REVIEW_ARCH_MODEL   default opencode-go/glm-5.2
#   OPENCODE_REVIEW_CHAIR_MODEL  default opencode-go/qwen3.7-max
#   OPENCODE_REVIEW_MODEL        run a SINGLE model (with the SWE persona) instead
#                                of the committee
#   OPENCODE_REVIEW_AGENT        run a SINGLE pre-configured opencode agent via
#                                --agent (escape hatch; must be a mode:primary agent)
#   OPENCODE_REVIEW_FACTCHECK    1 to run the phase-3 fact-check pass, 0 to skip (default 1)
#   OPENCODE_REVIEW_FACTCHECK_MODEL  fact-check model (default opencode-go/deepseek-v4-pro)
#   OPENCODE_REVIEW_TIMEOUT      per-model hard timeout in seconds (default 900)
#   OPENCODE_REVIEW_STAGGER      seconds between the two parallel member launches,
#                                to dodge opencode's session-init DB lock (default 3)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"

SWE_MODEL="${OPENCODE_REVIEW_SWE_MODEL:-opencode-go/kimi-k2.7-code}"
ARCH_MODEL="${OPENCODE_REVIEW_ARCH_MODEL:-opencode-go/glm-5.2}"
CHAIR_MODEL="${OPENCODE_REVIEW_CHAIR_MODEL:-opencode-go/qwen3.7-max}"
# Optional fact-check pass over the chair's report (port of open-code-review's
# REVIEW_FILTER_TASK: prune only findings the diff can directly falsify). Set
# OPENCODE_REVIEW_FACTCHECK=0 to skip. Defaults to a reasoning-strong model that is
# independent of the chair (qwen): the pass is pure inline diff+report judgment (no
# tools), and its failure mode is over-pruning, so it rewards disciplined instruction
# following and faithful report reproduction over coding/agentic ability.
FACTCHECK_ENABLED="${OPENCODE_REVIEW_FACTCHECK:-1}"
FACTCHECK_MODEL="${OPENCODE_REVIEW_FACTCHECK_MODEL:-opencode-go/deepseek-v4-pro}"
SINGLE_MODEL="${OPENCODE_REVIEW_MODEL:-}"
SINGLE_AGENT="${OPENCODE_REVIEW_AGENT:-}"
TIMEOUT="${OPENCODE_REVIEW_TIMEOUT:-900}"
# Delay between launching the two parallel members. opencode's session sqlite
# can hit "database is locked" if two runs start within the same session-init
# write window; a few seconds' stagger avoids that startup race while keeping the
# members overlapping for the bulk of the run.
STAGGER="${OPENCODE_REVIEW_STAGGER:-3}"

log() { printf '[opencode-review] %s\n' "$*" >&2; }

# ----------------------------------------------------------------- pre-flight
command -v opencode >/dev/null 2>&1 ||
  {
    log "ERROR: 'opencode' is not on PATH."
    exit 127
  }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  {
    log "ERROR: not inside a git repository (cwd=$(pwd))."
    exit 1
  }

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

read_prompt() { # $1 file -> persona text (fatal if missing)
  [ -f "$1" ] || {
    log "ERROR: prompt file missing: $1"
    exit 1
  }
  cat "$1"
}

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

NO_PR="There is no pull request yet; do not run any gh command."

# SCOPE_MODE/SCOPE_ARG are recorded alongside the human-readable SCOPE so the
# rule-matching step (below) can re-derive the exact list of changed files.
if [ "$#" -ge 1 ]; then
  arg="$1"
  if [ -z "$arg" ]; then
    SCOPE="uncommitted changes (forced)"
    SCOPE_MODE="uncommitted"
    MSG="Review the current UNCOMMITTED changes in this repo: combine git diff, git diff --cached, and untracked files from git status --short. ${NO_PR}"
  else
    SCOPE="explicit target '${arg}'"
    SCOPE_MODE="target"
    SCOPE_ARG="$arg"
    MSG="Review target: ${arg}. Interpret it as a commit SHA (git show <sha>) or a branch name to diff against HEAD (git diff <branch>...HEAD). ${NO_PR}"
  fi
else
  if [ -n "$(git status --porcelain)" ]; then
    SCOPE="uncommitted changes"
    SCOPE_MODE="uncommitted"
    MSG="Review the current UNCOMMITTED changes in this repo: combine git diff, git diff --cached, and untracked files from git status --short. ${NO_PR}"
  else
    base="$(detect_base)"
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    if [ "$cur" != "$base" ] && [ -n "$(git rev-list "${base}..HEAD" 2>/dev/null)" ]; then
      SCOPE="branch '${cur}' vs '${base}'"
      SCOPE_MODE="branch"
      SCOPE_ARG="$base"
      MSG="Review the diff of the current branch against ${base}: git diff ${base}...HEAD. ${NO_PR}"
    else
      log "Nothing to review: working tree is clean and no commits ahead of base. Done."
      exit 0
    fi
  fi
fi

# ------------------------------------------------------- file-type rule matching
# Port of open-code-review's path-based rule injection: each changed file is
# mapped (first-match-wins) to a review checklist under prompts/rules/, the union
# of which is appended to every member's persona so each model's attention is
# focused on what actually matters for the file types in this diff. Disable with
# OPENCODE_REVIEW_RULES=0.
RULES_DIR="$SCRIPT_DIR/../prompts/rules"
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

# changed_files prints the affected paths for the resolved scope (one per line).
changed_files() {
  case "$SCOPE_MODE" in
  uncommitted)
    {
      git diff --name-only
      git diff --cached --name-only
      git ls-files --others --exclude-standard
    } 2>/dev/null
    ;;
  branch)
    git diff --name-only "${SCOPE_ARG}...HEAD" 2>/dev/null
    ;;
  target)
    if git rev-parse --verify --quiet "${SCOPE_ARG}^{commit}" >/dev/null 2>&1 &&
      ! git show-ref --verify --quiet "refs/heads/${SCOPE_ARG}"; then
      git show --name-only --pretty=format: "$SCOPE_ARG" 2>/dev/null
    else
      git diff --name-only "${SCOPE_ARG}...HEAD" 2>/dev/null
    fi
    ;;
  esac
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

# ---------------------------------------------------- headless run permissions
# Applied ONLY to this run via OPENCODE_PERMISSION; the saved config is untouched.
# opencode evaluates bash patterns LAST-match-wins, so the order inside "bash" is
# load-bearing: default deny first, read-only allows next, and metacharacter
# denies last so they override every allow.
#   edit deny            -> read-only review (defense-in-depth over the models)
#   question deny        -> a run cannot stall waiting for input
#   doom_loop deny       -> a repeated identical tool call cannot stall on approval
#   bash "*" deny        -> default-deny: the diff under review is untrusted input
#                           to the reviewer models (prompt injection), so only the
#                           read-only commands below are allowed.
#   read-only allows     -> git reads + cat/head/tail/wc/ls/grep/rg; enough for
#                           the personas' "read related repo files" instruction.
#   metachar denies      -> ; | & > ` $( <( and newline: an allowed prefix cannot
#                           smuggle chained commands, pipes-to-shell, command
#                           substitution, or redirection writes. Costs the models
#                           regex alternation ('a|b') in grep args — acceptable.
# This is defense-in-depth over glob matching, not a hard sandbox.
PERM='{"edit":"deny","question":"deny","doom_loop":"deny","bash":{"*":"deny","git diff*":"allow","git show*":"allow","git log*":"allow","git status*":"allow","git ls-files*":"allow","git rev-parse*":"allow","git blame*":"allow","git grep*":"allow","cat *":"allow","head *":"allow","tail *":"allow","wc *":"allow","ls":"allow","ls *":"allow","grep *":"allow","rg *":"allow","*;*":"deny","*|*":"deny","*&*":"deny","*>*":"deny","*`*":"deny","*$(*":"deny","*<(*":"deny","*\n*":"deny"}}'

swe_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-swe.$$")"
arch_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-arch.$$")"
chair_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-chair.$$")"
fc_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-fc.$$")"
single_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-single.$$")"
trap 'rm -f "$swe_out" "$arch_out" "$chair_out" "$fc_out" "$single_out"' EXIT

# oc_run <flag> <value> <message> <outfile>
# Runs one opencode invocation headlessly (flag is --model or --agent), capturing
# BOTH streams to <outfile> (opencode emits the report on its render stream, not
# its final stdout). Honors a hard timeout via timeout(1) when present, else a
# built-in watchdog so a hung run can't block forever. Returns the exit status
# (124 on timeout).
oc_run() {
  local flag="$1" val="$2" msg="$3" out="$4" st td pid wpid
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
      "$TIMEOUT_BIN" "$TIMEOUT" opencode run --pure "$flag" "$val" "$msg" >"$out" 2>&1
    return $?
  fi
  GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
    opencode run --pure "$flag" "$val" "$msg" >"$out" 2>&1 &
  pid=$!
  td="$(mktemp 2>/dev/null || echo "/tmp/oc-td.$$")"
  rm -f "$td"
  (
    sleep "$TIMEOUT"
    kill -TERM "$pid" 2>/dev/null && : >"$td"
    sleep 5
    kill -KILL "$pid" 2>/dev/null
  ) &
  wpid=$!
  wait "$pid" 2>/dev/null
  st=$?
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  [ -f "$td" ] && st=124
  rm -f "$td"
  return "$st"
}

status_note() {
  case "$1" in
  0) printf 'ok' ;;
  124) printf 'TIMED OUT after %ss' "$TIMEOUT" ;;
  *) printf 'exited with status %s' "$1" ;;
  esac
}

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

# --------------------------------------------------------- single-run escapes
if [ -n "$SINGLE_AGENT" ]; then
  log "scope : ${SCOPE}"
  log "mode  : single agent '${SINGLE_AGENT}' (must be mode:primary)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (agent ${SINGLE_AGENT}) — ${SCOPE} ====="
  oc_run --agent "$SINGLE_AGENT" "$MSG" "$single_out"
  st=$?
  cat "$single_out"
  echo "===== END OF REVIEW ====="
  log "single-agent review: $(status_note "$st")"
  exit "$st"
fi

if [ -n "$SINGLE_MODEL" ]; then
  log "scope : ${SCOPE}"
  log "mode  : single model '${SINGLE_MODEL}' (SWE persona)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (model ${SINGLE_MODEL}) — ${SCOPE} ====="
  oc_run --model "$SINGLE_MODEL" "$(member_msg "$(read_prompt "$PROMPTS_DIR/swe.md")")" "$single_out"
  st=$?
  cat "$single_out"
  echo "===== END OF REVIEW ====="
  log "single-model review: $(status_note "$st")"
  exit "$st"
fi

# --------------------------------------------------------------- committee flow
SWE_PERSONA="$(read_prompt "$PROMPTS_DIR/swe.md")"
ARCH_PERSONA="$(read_prompt "$PROMPTS_DIR/architect.md")"
CHAIR_PERSONA="$(read_prompt "$PROMPTS_DIR/chair.md")"

log "scope : ${SCOPE}"
log "mode  : committee — swe(${SWE_MODEL}) + architect(${ARCH_MODEL}) -> chair(${CHAIR_MODEL})"
[ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s per model)."

echo "===== OPENCODE COMMITTEE REVIEW — ${SCOPE} ====="

# Phase 1 — the two members review the same target in parallel, launched a few
# seconds apart so they don't collide on opencode's session-init DB lock.
log "phase 1: swe + architect (parallel, ${STAGGER}s stagger)"
oc_run --model "$SWE_MODEL" "$(member_msg "$SWE_PERSONA")" "$swe_out" &
swe_job=$!
sleep "$STAGGER"
oc_run --model "$ARCH_MODEL" "$(member_msg "$ARCH_PERSONA")" "$arch_out" &
arch_job=$!
wait "$swe_job"
swe_st=$?
wait "$arch_job"
arch_st=$?
log "phase 1 done: swe=$(status_note "$swe_st"), architect=$(status_note "$arch_st")"

# Phase 2 — the chair dedupes/verifies both reports against the same target.
log "phase 2: chair (synthesis)"
chair_msg="$(printf '%s\n\n===== SWE report (correctness/bugs/security) [%s] =====\n%s\n\n===== Architect report (design/architecture) [%s] =====\n%s\n\n===== review target =====\n%s\n' \
  "$CHAIR_PERSONA" \
  "$(status_note "$swe_st")" "$(cat "$swe_out")" \
  "$(status_note "$arch_st")" "$(cat "$arch_out")" \
  "$MSG")"
oc_run --model "$CHAIR_MODEL" "$chair_msg" "$chair_out"
chair_st=$?

# Phase 3 (optional) — fact-check the chair's report against the diff only,
# pruning findings the diff can directly falsify. On any failure the chair's
# report is emitted unchanged, so this phase can only ever reduce false positives.
fc_st=0
fc_applied=0
if [ "$chair_st" -eq 0 ] && [ -s "$chair_out" ] && [ "$FACTCHECK_ENABLED" != "0" ]; then
  log "phase 3: fact-check (${FACTCHECK_MODEL})"
  FACTCHECK_PERSONA="$(read_prompt "$PROMPTS_DIR/factcheck.md")"
  fc_msg="$(printf '%s\n\n===== Chair report to fact-check =====\n%s\n\n===== review target =====\n%s\n' \
    "$FACTCHECK_PERSONA" "$(cat "$chair_out")" "$MSG")"
  oc_run --model "$FACTCHECK_MODEL" "$fc_msg" "$fc_out"
  fc_st=$?
  if [ "$fc_st" -eq 0 ] && [ -s "$fc_out" ]; then
    fc_applied=1
    log "phase 3 done: fact-check applied"
  else
    log "WARN: fact-check $(status_note "$fc_st"); emitting chair report unchanged."
  fi
fi

if [ "$fc_applied" -eq 1 ]; then
  cat "$fc_out"
elif [ "$chair_st" -eq 0 ] && [ -s "$chair_out" ]; then
  cat "$chair_out"
else
  log "WARN: chair $(status_note "$chair_st"); falling back to the raw member reports."
  printf '## SWE (correctness) [%s]\n\n' "$(status_note "$swe_st")"
  cat "$swe_out"
  printf '\n## Architect (design) [%s]\n\n' "$(status_note "$arch_st")"
  cat "$arch_out"
fi
echo "===== END OF REVIEW ====="

if [ "$chair_st" -ne 0 ]; then
  status="$chair_st"
elif [ "$swe_st" -ne 0 ] || [ "$arch_st" -ne 0 ]; then
  status=1
else
  status=0
fi

if [ "$status" -eq 0 ]; then
  log "committee review complete."
else
  log "committee review finished with issues (chair=$(status_note "$chair_st"), swe=$(status_note "$swe_st"), architect=$(status_note "$arch_st"))."
fi
exit "$status"
