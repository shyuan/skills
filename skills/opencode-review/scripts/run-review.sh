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
#   OPENCODE_REVIEW_PROVIDER     provider to reach the default models through, e.g.
#                                "omniroute" -> omniroute/opencode-go/glm-5.2. Applies
#                                to the four DEFAULTS below only; an explicit *_MODEL
#                                is always a full id. Unset = direct (unchanged).
#   OPENCODE_REVIEW_SWE_MODEL    default opencode-go/kimi-k2.7-code
#   OPENCODE_REVIEW_ARCH_MODEL   default opencode-go/glm-5.2
#   OPENCODE_REVIEW_CHAIR_MODEL  default opencode-go/qwen3.7-max
#   OPENCODE_REVIEW_MODEL        run a SINGLE model (with the SWE persona) instead
#                                of the committee
#   OPENCODE_REVIEW_AGENT        run a SINGLE pre-configured opencode agent via
#                                --agent (escape hatch; must be a mode:primary agent)
#   OPENCODE_REVIEW_FACTCHECK    1 to run the phase-3 fact-check pass, 0 to skip (default 1)
#   OPENCODE_REVIEW_FACTCHECK_MODEL  fact-check model (default opencode-go/deepseek-v4-pro)
#   OPENCODE_REVIEW_DEP_DIRS     extra dependency-source dirs the file tools may read,
#                                colon-separated (GOMODCACHE and the cargo registry are
#                                detected automatically)
#   OPENCODE_REVIEW_TIMEOUT      per-model hard timeout in seconds (default 900)
#   OPENCODE_REVIEW_STAGGER      seconds between the two parallel member launches,
#                                to dodge opencode's session-init DB lock (default 3)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"

# ------------------------------------------------------------- model selection
# The defaults name the models by their DIRECT provider (opencode-go/…), which is
# one account. A setup that fronts several plans with a router (OmniRoute and the
# like) exposes the same models one level down — omniroute/opencode-go/glm-5.2 —
# and reaching them that way is what spreads a run's four calls (two of them
# concurrent) across the plans instead of stacking them on one.
#
# So the router is a PREFIX on the defaults, not a new set of defaults: hardcoding
# a router id would tie this skill to one machine's config, and every reviewer
# model would silently 404 anywhere that provider is not configured. Unset, the
# ids are exactly what they were.
#
# It deliberately does not touch OPENCODE_REVIEW_{SWE,ARCH,CHAIR,FACTCHECK}_MODEL
# or OPENCODE_REVIEW_MODEL: those are ids the caller wrote out, and prefixing them
# would make "the id I asked for" not the id that runs. Route an explicit override
# by spelling the provider into it.
PROVIDER="${OPENCODE_REVIEW_PROVIDER:-}"
PROVIDER="${PROVIDER%/}" # tolerate "omniroute/"
PROVIDER_PREFIX="${PROVIDER:+${PROVIDER}/}"

SWE_MODEL="${OPENCODE_REVIEW_SWE_MODEL:-${PROVIDER_PREFIX}opencode-go/kimi-k2.7-code}"
ARCH_MODEL="${OPENCODE_REVIEW_ARCH_MODEL:-${PROVIDER_PREFIX}opencode-go/glm-5.2}"
CHAIR_MODEL="${OPENCODE_REVIEW_CHAIR_MODEL:-${PROVIDER_PREFIX}opencode-go/qwen3.7-max}"
# Optional fact-check pass over the chair's report (port of open-code-review's
# REVIEW_FILTER_TASK: prune only findings the diff can directly falsify). Set
# OPENCODE_REVIEW_FACTCHECK=0 to skip. Defaults to a reasoning-strong model that is
# independent of the chair (qwen): the pass is pure inline diff+report judgment (no
# tools), and its failure mode is over-pruning, so it rewards disciplined instruction
# following and faithful report reproduction over coding/agentic ability.
FACTCHECK_ENABLED="${OPENCODE_REVIEW_FACTCHECK:-1}"
FACTCHECK_MODEL="${OPENCODE_REVIEW_FACTCHECK_MODEL:-${PROVIDER_PREFIX}opencode-go/deepseek-v4-pro}"
SINGLE_MODEL="${OPENCODE_REVIEW_MODEL:-}"
SINGLE_AGENT="${OPENCODE_REVIEW_AGENT:-}"
TIMEOUT="${OPENCODE_REVIEW_TIMEOUT:-900}"
# Delay between launching the two parallel members. opencode's session sqlite
# can hit "database is locked" if two runs start within the same session-init
# write window; a few seconds' stagger avoids that startup race while keeping the
# members overlapping for the bulk of the run.
STAGGER="${OPENCODE_REVIEW_STAGGER:-3}"

log() { printf '[opencode-review] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- report fence
# Each persona fences its report between these markers and every stage forwards
# only what is between them (see "report extraction" below).
#
# The markers carry a per-run nonce because the fence is allowed to outrank the
# render state machine, so anything that can emit a marker line controls what is
# taken as the report. The repository under review can emit one: the personas
# tell members to read related files, `cat`/`head`/`tail` are permitted and print
# file content verbatim, and the diff under review is untrusted input. A fixed
# marker would also break on this repo, whose own prompts/*.md contain the
# literal token. A nonce the reviewed tree cannot know closes both.
#
# prompts/*.md carry the bare token; read_prompt substitutes the nonced form, so
# the persona files stay readable and there is one source of truth for the value.
REPORT_TOKEN_BEGIN='<<<REVIEW-REPORT>>>'
REPORT_TOKEN_END='<<<END-REVIEW-REPORT>>>'
REPORT_NONCE="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$REPORT_NONCE" ] || REPORT_NONCE="$$$(date +%s)"
REPORT_BEGIN="<<<REVIEW-REPORT-${REPORT_NONCE}>>>"
REPORT_END="<<<END-REVIEW-REPORT-${REPORT_NONCE}>>>"

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

read_prompt() { # $1 file -> persona text, fence markers nonced (fatal if missing)
  [ -f "$1" ] || {
    log "ERROR: prompt file missing: $1"
    exit 1
  }
  sed -e "s|${REPORT_TOKEN_END}|${REPORT_END}|g" \
    -e "s|${REPORT_TOKEN_BEGIN}|${REPORT_BEGIN}|g" "$1"
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
#   external_directory   -> ADDS read access to the dependency caches found by
#                           dep_dirs (below). No blanket deny is written here:
#                           OPENCODE_PERMISSION is merged with the saved config,
#                           not substituted for it, so a "*":"deny" would also
#                           override opencode's own allows and any the user has
#                           configured. The built-in default for an unlisted path
#                           is "ask", which auto-rejects headless — the behaviour
#                           this block relied on before. So this only widens, and
#                           only for the paths named.
# This is defense-in-depth over glob matching, not a hard sandbox.
#
# Note the bash patterns are path-AGNOSTIC: "head *" matches "head /anywhere". The
# boundary this block draws is therefore over *commands*, not over paths — reads
# outside the repo have always been possible by spelling them as a shell command.
# What external_directory adds is making the file tools agree with that for the
# dependency caches, instead of the two routes disagreeing about the same file.

# dep_dirs prints the dependency source caches that exist on this machine, one
# per line. These are the one class of path outside the repo a reviewer genuinely
# needs: when a diff's assertions encode a dependency's contract, "does this match
# what the dependency actually does?" is the review question, and it cannot be
# answered from the diff alone. They are read-only by nature, and they are not the
# untrusted input — the diff is. `edit` stays denied globally, so this grants
# reading, never writing.
#
# Add more with OPENCODE_REVIEW_DEP_DIRS (colon-separated absolute paths).

# go_env_get <KEY> prints KEY from Go's own env file (what `go env -w` writes).
# Location is os.UserConfigDir()/go/env; the macOS path is checked first and only
# one of the two exists on a given machine.
go_env_get() {
  local f
  for f in "$HOME/Library/Application Support/go/env" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/go/env"; do
    [ -f "$f" ] || continue
    sed -n "s/^$1=//p" "$f" | tail -1
    return 0
  done
}

# go_mod_cache prints Go's module cache path, mirroring the toolchain's own
# precedence: GOMODCACHE, else GOPATH/pkg/mod, each falling back to the go env
# file and finally to the documented default of $HOME/go.
#
# Deliberately NOT `go env GOMODCACHE`. That resolves `go` through PATH and runs
# it, from the root of the repository under review, before any permission set is
# in effect. The script cannot avoid running PATH-resolved git and opencode the
# same way, but an optional convenience does not get to widen that surface — and
# resolving it by hand costs nothing and works with no toolchain installed.
go_mod_cache() {
  local v gp
  v="${GOMODCACHE:-}"
  [ -n "$v" ] || v="$(go_env_get GOMODCACHE)"
  if [ -z "$v" ]; then
    gp="${GOPATH:-}"
    [ -n "$gp" ] || gp="$(go_env_get GOPATH)"
    [ -n "$gp" ] || gp="$HOME/go"
    gp="${gp%%:*}" # GOPATH may be a list; the module cache lives under the first
    v="$gp/pkg/mod"
  fi
  printf '%s' "$v"
}

dep_dirs() {
  local d
  d="$(go_mod_cache)"
  [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
  d="${CARGO_HOME:-$HOME/.cargo}/registry"
  [ -d "$d" ] && printf '%s\n' "$d"
  printf '%s' "${OPENCODE_REVIEW_DEP_DIRS:-}" | tr ':' '\n' | while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# external_dirs_rules prints the "external_directory" member of the permission
# object, or nothing when no cache was found. Paths holding a quote or backslash
# are skipped rather than escaped: they cannot be spelled safely here, and a
# dependency cache is never going to be at such a path.
external_dirs_rules() {
  local d out=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in *[\\\"]*) continue ;; esac
    [ -n "$out" ] && out="${out},"
    out="${out}\"${d}/**\":\"allow\""
  done <<EOF
$(dep_dirs | sort -u)
EOF
  [ -n "$out" ] || return 0
  printf '"external_directory":{%s},' "$out"
}

EXT_DIR_RULES="$(external_dirs_rules)"
if [ -n "$EXT_DIR_RULES" ]; then
  log "deps  : file-tool reads allowed under $(dep_dirs | sort -u | tr '\n' ' ')"
else
  log "deps  : no dependency cache found; file tools stay repo-only"
fi

# The bash map is kept as a single-quoted literal so patterns like "*$(*" are not
# touched by the shell; only the outer object is assembled.
PERM_BASH='{"*":"deny","git diff*":"allow","git show*":"allow","git log*":"allow","git status*":"allow","git ls-files*":"allow","git rev-parse*":"allow","git blame*":"allow","git grep*":"allow","cat *":"allow","head *":"allow","tail *":"allow","wc *":"allow","ls":"allow","ls *":"allow","grep *":"allow","rg *":"allow","*;*":"deny","*|*":"deny","*&*":"deny","*>*":"deny","*`*":"deny","*$(*":"deny","*<(*":"deny","*\n*":"deny"}'
PERM="{\"edit\":\"deny\",\"question\":\"deny\",\"doom_loop\":\"deny\",${EXT_DIR_RULES}\"bash\":${PERM_BASH}}"

swe_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-swe.$$")"
arch_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-arch.$$")"
chair_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-chair.$$")"
fc_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-fc.$$")"
single_out="$(mktemp 2>/dev/null || echo "/tmp/oc-review-single.$$")"
# ..._rep holds the report extracted from the matching ..._out transcript.
swe_rep="$(mktemp 2>/dev/null || echo "/tmp/oc-review-swe-rep.$$")"
arch_rep="$(mktemp 2>/dev/null || echo "/tmp/oc-review-arch-rep.$$")"
chair_rep="$(mktemp 2>/dev/null || echo "/tmp/oc-review-chair-rep.$$")"
fc_rep="$(mktemp 2>/dev/null || echo "/tmp/oc-review-fc-rep.$$")"
single_rep="$(mktemp 2>/dev/null || echo "/tmp/oc-review-single-rep.$$")"
trap 'rm -f "$swe_out" "$arch_out" "$chair_out" "$fc_out" "$single_out" \
  "$swe_rep" "$arch_rep" "$chair_rep" "$fc_rep" "$single_rep"' EXIT

# oc_run <flag> <value> <message> <outfile>
# Runs one opencode invocation headlessly (flag is --model or --agent), capturing
# BOTH streams to <outfile> (opencode emits the report on its render stream, not
# its final stdout). What lands in <outfile> is therefore a transcript — run it
# through extract_report before showing it to anyone. Honors a hard timeout via
# timeout(1) when present, else a built-in watchdog so a hung run can't block
# forever. Returns the exit status (124 on timeout).
#
# stdin is /dev/null: with stdin left attached, `opencode run` waits on it and the
# run hangs until the timeout fires, having produced no output at all.
oc_run() {
  local flag="$1" val="$2" msg="$3" out="$4" st td pid wpid
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
      "$TIMEOUT_BIN" "$TIMEOUT" opencode run --pure "$flag" "$val" "$msg" </dev/null >"$out" 2>&1
    return $?
  fi
  GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
    opencode run --pure "$flag" "$val" "$msg" </dev/null >"$out" 2>&1 &
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

# ------------------------------------------------------------ report extraction
# What oc_run captures is a TRANSCRIPT, not a report: opencode renders tool-call
# headers, tool output (including an echo of the whole diff, once per member),
# ANSI escapes, and — on every denied bash call — the entire OPENCODE_PERMISSION
# ruleset as JSON. Handing that to the next stage is what stalled the chair: it
# received 60-78 KB of render noise and had to find the reports inside it.
#
# So every persona fences its report (REPORT_BEGIN/REPORT_END, defined up top with
# the reasoning for the nonce), and each stage passes on only what is between them.
# Below this many non-whitespace BYTES (CJK runs ~3/char) an "extracted report" is
# a stray heading or a courtesy line, not a report; the stage is reported as blank.
REPORT_MIN_BYTES=40

# Where a transcript is kept when no report could be extracted from it, so the
# next occurrence can be diagnosed instead of guessed at. Every other copy is a
# mktemp file removed on exit, and a blank stage prints nothing — without this
# there is no way to tell "the model said nothing" from "the de-noiser ate it".
#
# The directory is created by mktemp -d on first use: atomically, mode 700, under
# an unpredictable name. A fixed name under a shared /tmp would let a local user
# pre-place a path there — clobbering the evidence, or, since cp follows a
# destination symlink, diverting a transcript that contains the diff under review.
KEEP_DIR=""

# retain_transcript <transcript> <stage-label> -> sets KEPT_PATH ("" if not kept).
# Skips an empty transcript: there is nothing in it to diagnose. Assigns rather
# than prints so KEEP_DIR survives — a command substitution would subshell it
# away and every stage would make its own directory.
KEPT_PATH=""
retain_transcript() {
  KEPT_PATH=""
  [ -s "$1" ] || return 0
  if [ -z "$KEEP_DIR" ]; then
    KEEP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-XXXXXXXX" 2>/dev/null)" || return 0
    [ -n "$KEEP_DIR" ] || return 0
  fi
  cp "$1" "$KEEP_DIR/$2.log" 2>/dev/null && KEPT_PATH="$KEEP_DIR/$2.log"
}

# denoise <transcript>
# Prints the report on stdout; exits 0 if it came from between the fences, 1 if
# the fences were absent and the de-noised transcript was used instead.
#
# De-noising uses opencode's own render structure: a line starting with ESC is
# either a bare separator, a tool header, or an error banner; the plain lines
# after a tool header are that tool's output. A separator ends the tool block.
#
# An error banner also ends it, but what follows the banner differs by error:
#   - a denied bash call puts its whole ruleset on the banner line, and the
#     model's prose resumes on the next line with no separator of its own;
#   - a malformed provider response (e.g. a payload carrying neither `choices`
#     nor `error`) spills a multi-line Zod validation dump below the banner.
# So after a banner we skip continuation lines that look like structured-error
# spill — brackets, quoted keys, "Error message:" — and treat the first line that
# does not as the model's prose.
denoise() {
  awk -v b="$REPORT_BEGIN" -v e="$REPORT_END" '
    BEGIN { esc = sprintf("%c", 27); csi = esc "\\[[0-9;?]*[a-zA-Z]"; state = "prose"; n = 0 }
    {
      isesc = (substr($0, 1, 1) == esc)
      line = $0
      gsub(csi, "", line)
      sub("\r$", "", line)
      if (isesc) {
        if (line == "") { state = "prose"; next }
        if (line ~ /^Error: /) { state = "errspill"; next }
        state = "tool"; next
      }
      # The fence is unambiguous, so it outranks the state machine. This matters:
      # a tool call that renders no output block (Read) is not followed by a
      # separator, so when it is the last call the report starts on the very next
      # line and would otherwise be swallowed as more output from that tool.
      t = line
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == b) state = "prose"
      if (state == "tool") next
      if (state == "errspill") {
        if (line ~ /^[ \t]*([][{}"]|Error message:)/ || line ~ /^[ \t]*$/) next
        state = "prose"
      }
      if (line ~ /^> [a-zA-Z0-9_.-]+ · /) next   # opencode banner: "> build · <model>"
      buf[++n] = line
    }
    END {
      nb = 0
      for (i = 1; i <= n; i++) { t = buf[i]; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == b) nb = i }
      if (nb > 0) {
        ne = n + 1
        for (i = nb + 1; i <= n; i++) { t = buf[i]; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == e) { ne = i; break } }
        lo = nb + 1; hi = ne - 1; rc = 0
      } else {
        lo = 1; hi = n; rc = 1
      }
      while (lo <= hi && buf[lo] ~ /^[ \t]*$/) lo++          # trim blank edges
      while (hi >= lo && buf[hi] ~ /^[ \t]*$/) hi--
      for (i = lo; i <= hi; i++) print buf[i]
      exit rc
    }
  ' "$1"
}

# report_bytes <file> -> non-whitespace byte count.
# LC_ALL=C: reports are largely CJK and BSD tr is not multibyte-safe; a byte
# count is all this needs, and bytewise deletion cannot choke on a UTF-8 lead.
report_bytes() { LC_ALL=C tr -d '[:space:]' <"$1" | wc -c | tr -d ' '; }

# extract_report <transcript> <outfile> [stage-label]
# Writes the stage's report to <outfile>. Exit status:
#   0  fenced report found — this is the good path
#   1  no fence; a de-noised transcript was written instead (model ignored the
#      format instruction — still far smaller than the raw capture)
#   2  nothing substantive — the stage produced no report
#
# There is deliberately no "recover it anyway" pass here. Dropping the tool-output
# rule does salvage a report the de-noiser swallowed, but it cannot tell that
# report from tool output, so a model that runs git diff and then stops gets its
# own diff forwarded as its review and the run is called ok — which is precisely
# the failure the blank check exists to catch. A fenced report is already immune
# (the fence outranks the state machine, above); an unfenced one has no anchor to
# recover from, so it is reported blank and its transcript is kept to be read.
extract_report() {
  local in="$1" out="$2" stage="${3:-stage}" rc bytes

  denoise "$in" >"$out"
  rc=$?
  bytes="$(report_bytes "$out")"
  [ "$bytes" -ge "$REPORT_MIN_BYTES" ] && return "$rc"

  : >"$out"
  retain_transcript "$in" "$stage"
  log "WARN: ${stage}: no report could be extracted from $(wc -c <"$in" | tr -d ' ') B of transcript. Transcript: ${KEPT_PATH:-<empty, not kept>}"
  return 2
}

# stage_note <run-exit-status> <extract-status> -> the label shown in the log and
# handed to the chair, so "exited 0 having written nothing" can no longer read ok.
stage_note() {
  case "$2" in
  0) status_note "$1" ;;
  1) printf '%s, but the report was not fenced — de-noised transcript used' "$(status_note "$1")" ;;
  *) printf 'NO REPORT PRODUCED (run %s)' "$(status_note "$1")" ;;
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
  # A pre-configured agent has its own prompt and cannot be told to fence, so a
  # missing fence here is expected; the de-noising still applies.
  extract_report "$single_out" "$single_rep" "single-agent"
  ex=$?
  cat "$single_rep"
  echo "===== END OF REVIEW ====="
  log "single-agent review: $(stage_note "$st" "$ex")"
  [ "$st" -eq 0 ] && [ "$ex" -eq 2 ] && st=1
  exit "$st"
fi

if [ -n "$SINGLE_MODEL" ]; then
  log "scope : ${SCOPE}"
  log "mode  : single model '${SINGLE_MODEL}' (SWE persona)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (model ${SINGLE_MODEL}) — ${SCOPE} ====="
  oc_run --model "$SINGLE_MODEL" "$(member_msg "$(read_prompt "$PROMPTS_DIR/swe.md")")" "$single_out"
  st=$?
  extract_report "$single_out" "$single_rep" "single-model"
  ex=$?
  cat "$single_rep"
  echo "===== END OF REVIEW ====="
  log "single-model review: $(stage_note "$st" "$ex")"
  [ "$st" -eq 0 ] && [ "$ex" -eq 2 ] && st=1
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
extract_report "$swe_out" "$swe_rep" "swe"
swe_ex=$?
extract_report "$arch_out" "$arch_rep" "architect"
arch_ex=$?
log "phase 1 done: swe=$(stage_note "$swe_st" "$swe_ex"), architect=$(stage_note "$arch_st" "$arch_ex")"

# Phase 2 — the chair dedupes/verifies both reports against the same target. It
# receives the extracted reports, which is what prompts/chair.md says it will get;
# a member that wrote nothing is announced as such, so the chair's own
# "note which member is absent" rule can actually fire.
log "phase 2: chair (synthesis)"
chair_msg="$(printf '%s\n\n===== SWE report (correctness/bugs/security) [%s] =====\n%s\n\n===== Architect report (design/architecture) [%s] =====\n%s\n\n===== review target =====\n%s\n' \
  "$CHAIR_PERSONA" \
  "$(stage_note "$swe_st" "$swe_ex")" "$(cat "$swe_rep")" \
  "$(stage_note "$arch_st" "$arch_ex")" "$(cat "$arch_rep")" \
  "$MSG")"
log "phase 2: chair prompt is $(printf '%s' "$chair_msg" | wc -c | tr -d ' ') B (swe report $(wc -c <"$swe_rep" | tr -d ' ') B of $(wc -c <"$swe_out" | tr -d ' ') B captured, architect $(wc -c <"$arch_rep" | tr -d ' ') B of $(wc -c <"$arch_out" | tr -d ' ') B)"
oc_run --model "$CHAIR_MODEL" "$chair_msg" "$chair_out"
chair_st=$?
extract_report "$chair_out" "$chair_rep" "chair"
chair_ex=$?

# Phase 3 (optional) — fact-check the chair's report against the diff only,
# pruning findings the diff can directly falsify. On any failure the chair's
# report is emitted unchanged, so this phase can only ever reduce false positives.
fc_st=0
fc_ex=0
fc_applied=0
if [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ] && [ "$FACTCHECK_ENABLED" != "0" ]; then
  log "phase 3: fact-check (${FACTCHECK_MODEL})"
  FACTCHECK_PERSONA="$(read_prompt "$PROMPTS_DIR/factcheck.md")"
  fc_msg="$(printf '%s\n\n===== Chair report to fact-check =====\n%s\n\n===== review target =====\n%s\n' \
    "$FACTCHECK_PERSONA" "$(cat "$chair_rep")" "$MSG")"
  oc_run --model "$FACTCHECK_MODEL" "$fc_msg" "$fc_out"
  fc_st=$?
  extract_report "$fc_out" "$fc_rep" "factcheck"
  fc_ex=$?
  if [ "$fc_st" -eq 0 ] && [ "$fc_ex" -ne 2 ]; then
    fc_applied=1
    log "phase 3 done: fact-check applied"
  else
    log "WARN: fact-check $(stage_note "$fc_st" "$fc_ex"); emitting chair report unchanged."
  fi
fi

if [ "$fc_applied" -eq 1 ]; then
  cat "$fc_rep"
elif [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ]; then
  cat "$chair_rep"
else
  log "WARN: chair $(stage_note "$chair_st" "$chair_ex"); falling back to the member reports."
  printf '## SWE (correctness) [%s]\n\n' "$(stage_note "$swe_st" "$swe_ex")"
  cat "$swe_rep"
  printf '\n## Architect (design) [%s]\n\n' "$(stage_note "$arch_st" "$arch_ex")"
  cat "$arch_rep"
fi
echo "===== END OF REVIEW ====="

# A stage that exited 0 having written no report is a failed stage: the caller
# must never be told "ok" about a run that produced nothing.
if [ "$chair_st" -ne 0 ]; then
  status="$chair_st"
elif [ "$chair_ex" -eq 2 ]; then
  status=1
elif [ "$swe_st" -ne 0 ] || [ "$arch_st" -ne 0 ] || [ "$swe_ex" -eq 2 ] || [ "$arch_ex" -eq 2 ]; then
  status=1
else
  status=0
fi

if [ "$status" -eq 0 ]; then
  log "committee review complete."
else
  log "committee review finished with issues (chair=$(stage_note "$chair_st" "$chair_ex"), swe=$(stage_note "$swe_st" "$swe_ex"), architect=$(stage_note "$arch_st" "$arch_ex"))."
fi
exit "$status"
