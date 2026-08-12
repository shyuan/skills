#!/usr/bin/env bash
#
# opencode-review / scripts/run-review.sh
#
# Self-contained, headless multi-model "reviewer committee" over the LOCAL diff
# (before any PR exists). Prints the chair's consolidated report to stdout for
# Claude Code to consume.
#
# Self-contained = the skill ships everything: it drives opencode by MODEL
# (`opencode run --pure --format json --model <id>`), embedding each reviewer's
# persona (from ./prompts/*.md) into the message. It does NOT depend on agents
# being defined in the user's opencode.jsonc. The environment requirements are
# that the chosen models are authenticated in OpenCode (model access, not
# config), and that jq or python3 is present to read the JSON event stream.
#
# Claude Code (the caller) is the lead/orchestrator: it fans out to two members
# in parallel, then hands both reports to the chair:
#   SWE       (correctness / bugs / security)   prompts/swe.md
#   Architect (design / architecture)           prompts/architect.md
#   Chair     (dedupe + verify + fill gaps)     prompts/chair.md
#
# Run from the repository root:
#   bash run-review.sh            # detect the stage: uncommitted and/or branch vs base
#   bash run-review.sh main       # diff current branch vs "main"
#   bash run-review.sh <sha>      # a specific commit
#   bash run-review.sh ""         # force: uncommitted changes only
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

# ----------------------------------------------------------------- pre-flight
command -v opencode >/dev/null 2>&1 ||
  {
    log "ERROR: 'opencode' is not on PATH."
    exit 127
  }

# Stages run with `--format json`, so a JSON reader is required. jq is preferred
# and python3 is the fallback; both are checked here rather than at first use so
# a machine with neither fails before spending a model call on it.
JSON_BIN=""
if command -v jq >/dev/null 2>&1; then
  JSON_BIN="jq"
elif command -v python3 >/dev/null 2>&1; then
  JSON_BIN="python3"
else
  log "ERROR: neither 'jq' nor 'python3' is on PATH; one is needed to read opencode's JSON events."
  exit 127
fi
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
#   webfetch/websearch   -> deny: outbound egress while reading an untrusted diff.
#                           Was UNSET and therefore ALLOWED — a reviewer could
#                           fetch an arbitrary URL, which is a way for injected
#                           text in a diff to send repo content outward, with no
#                           host or path restriction of the kind bash has. No
#                           persona asks for the network; nothing here needs it.
#   task/skill deny      -> delegation. A reviewer spawning a subagent or invoking
#                           another skill runs work this permission set does not
#                           describe, and the committee is orchestrated from
#                           outside opencode by design.
#   lsp deny             -> starting a language server on the repo under review
#                           runs project tooling over untrusted code, which is the
#                           same reason the personas refuse tests and builds.
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
# EVERY key in opencode's PermissionConfig is decided here, because "unset" is not
# a uniform default and cannot be reasoned about as a group. Observed in the same
# headless run: an unset `external_directory` auto-rejects, while an unset
# `webfetch` allows. Leaving a key out is a decision to accept whatever that key's
# default happens to be, today and after the next opencode release.
#
#   named deny   edit, question, doom_loop, webfetch, websearch, task, skill, lsp
#   structured   bash (default-deny + allow-list), external_directory (dep caches)
#   left allowed read, glob, grep, list  -> the reviewers' actual job; a review
#                                           cannot happen without them
#                todowrite               -> session-local scratchpad, no reach
#                                           outside the run
#
# The four navigation tools and todowrite are deliberately NOT written as explicit
# allows even though they are wanted. OPENCODE_PERMISSION is merged with the saved
# config rather than substituted for it, so writing "read":"allow" here would
# override a user who had deliberately restricted it. Denies are written because
# their absence is the bug; allows are left to config because their presence is.
#
# Denying a tool outright is free, unlike denying a bash PATTERN. A denied tool is
# removed from the model's toolset rather than rejected on use: asked to fetch a
# URL under this set, a member answers "I don't have a WebFetch tool available in
# my current toolset — only bash, glob, grep, read, and todowrite", having spent
# no turn on it. That listing is also this block's own inventory read back by a
# model, which is why the denies above can be broad without costing the run the
# way a rejected call does.
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
PERM="{\"edit\":\"deny\",\"question\":\"deny\",\"doom_loop\":\"deny\",\"webfetch\":\"deny\",\"websearch\":\"deny\",\"task\":\"deny\",\"skill\":\"deny\",\"lsp\":\"deny\",${EXT_DIR_RULES}\"bash\":${PERM_BASH}}"

# ------------------------------------------------------------- run scratch dir
# One private directory holds every scratch file this run makes, so no scratch
# path is ever predictable.
#
# Each of these used to be `mktemp 2>/dev/null || echo /tmp/<fixed-name>.$$`.
# When mktemp works that is fine, and when it does not the fallback hands a local
# user a name they can compute and pre-place a symlink at — and every one of
# these paths is a redirection target, so the link is followed and whatever it
# points at is truncated. KEEP_DIR below already avoids exactly this with
# `mktemp -d`; these predate it and were never brought in line.
#
# Created before anything is written and removed whole on exit. A failure here is
# fatal rather than a fallback: there is no safe place to put a transcript, and
# the transcripts contain the diff under review.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-run-XXXXXXXX" 2>/dev/null)"
[ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] ||
  {
    log "ERROR: could not create a private temp directory under ${TMPDIR:-/tmp}."
    exit 1
  }
trap 'rm -rf "$WORK_DIR"' EXIT

swe_out="$WORK_DIR/swe.out"
arch_out="$WORK_DIR/arch.out"
chair_out="$WORK_DIR/chair.out"
fc_out="$WORK_DIR/fc.out"
single_out="$WORK_DIR/single.out"
# ..._rep holds the report extracted from the matching ..._out transcript.
swe_rep="$WORK_DIR/swe.rep"
arch_rep="$WORK_DIR/arch.rep"
chair_rep="$WORK_DIR/chair.rep"
fc_rep="$WORK_DIR/fc.rep"
single_rep="$WORK_DIR/single.rep"

# oc_run <flag> <value> <message> <outfile>
# Runs one opencode invocation headlessly (flag is --model or --agent), capturing
# its JSON event stream to <outfile>, one event per line.
#
# `--format json` is what makes the report recoverable at all. The default format
# is a rendered transcript in which the model's prose, tool output, tool errors
# and ANSI control sequences are all just lines, and telling them apart after the
# fact was guesswork that got it wrong in both directions (see extract_report).
# The JSON stream separates them at the source: `text` events are the model's own
# words, `tool_use` events carry every byte a tool produced, and step_finish
# carries the reason the model stopped.
#
# stderr goes to its own file rather than being merged: it is not JSON, so
# merging it would put unparseable lines in the middle of the event stream. It is
# kept rather than discarded because it is where opencode reports the failures
# that produce no events at all.
#
# Honors a hard timeout via timeout(1) when present, else a built-in watchdog so a
# hung run can't block forever. Returns the exit status (124 on timeout).
#
# stdin is /dev/null: with stdin left attached, `opencode run` waits on it and the
# run hangs until the timeout fires, having produced no output at all.
oc_run() {
  local flag="$1" val="$2" msg="$3" out="$4" st td pid wpid
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
      "$TIMEOUT_BIN" "$TIMEOUT" opencode run --pure --format json "$flag" "$val" "$msg" \
      </dev/null >"$out" 2>"${out}.err"
    return $?
  fi
  GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
    opencode run --pure --format json "$flag" "$val" "$msg" </dev/null >"$out" 2>"${out}.err" &
  pid=$!
  # Timeout sentinel: the watchdog creates this path to signal that it fired, so
  # its EXISTENCE is the signal and it starts out deleted.
  #
  # Derived from the output file, which is unique per stage. Primarily so the
  # path is inside WORK_DIR and not one a local user can compute and pre-place a
  # symlink at — `: >"$td"` would otherwise follow the link and truncate whatever
  # it pointed to, which is the same hazard as the capture files above.
  #
  # It also stops concurrent callers sharing one sentinel. The old fallback name
  # `/tmp/oc-td.$$` was the same string in both parallel members, since `$$` in
  # bash is the invoking shell's pid and background subshells inherit it
  # ($BASHPID differs, $$ does not), so one member's timeout signal was written
  # where the other was reading. That is a race on shared state rather than a
  # reliable misreport, and deliberately not claimed as more: whichever member
  # reads the sentinel also deletes it, so the window in which the other can see
  # it is microseconds wide, and a constructed timing test could not observe a
  # wrong verdict. Worth removing on principle; the symlink reason is the one
  # that stands on its own.
  td="${out}.timedout"
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

# ------------------------------------------------------------ failure diagnosis
# Checks the models a failed stage was asked to run against what this OpenCode
# setup actually has, and says so.
#
# It exists because opencode's own answer for an unusable model id is no answer.
# `opencode run --model does-not-exist/at-all "hi"` EXITS 0 and prints only:
#   Error: {"name":"UnknownError","data":{"message":"Unexpected server error..."}}
# — no mention of the model, nothing to act on. This script then correctly reports
# NO REPORT PRODUCED (run ok), which is accurate and still leaves the reader with
# no idea that the cause is a model they do not have. That is the first thing
# anyone running this skill on a machine without the default provider hits, and
# without this check all four stages just fail in unison for no stated reason.
#
# `opencode models` costs about 7s, so it never runs on the happy path — only
# once, after something has already failed, where the cost does not matter.
# Memoised because several stages fail together in exactly that case.
# `opencode models` is itself a network-touching call, and this runs on the path
# where something has already gone wrong — so it gets its own short timeout.
# Without one, a provider that hangs would hang the diagnosis too, outliving the
# run it exists to explain.
DIAG_TIMEOUT=30
DIAG_DONE=0
diagnose_models() { # $@ = the model ids whose stages failed
  [ "$DIAG_DONE" -eq 1 ] && return 0
  DIAG_DONE=1

  local avail rc missing="" m tmp pid wpid
  if [ -n "$TIMEOUT_BIN" ]; then
    avail="$("$TIMEOUT_BIN" "$DIAG_TIMEOUT" opencode models 2>/dev/null)"
    rc=$?
  else
    # Same shape as oc_run's fallback watchdog, for a machine with no timeout(1).
    # Inside WORK_DIR like every other scratch file, so the path is private.
    tmp="$WORK_DIR/models.out"
    opencode models >"$tmp" 2>/dev/null &
    pid=$!
    (
      sleep "$DIAG_TIMEOUT"
      kill -TERM "$pid" 2>/dev/null
      sleep 3
      kill -KILL "$pid" 2>/dev/null
    ) &
    wpid=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    avail="$(cat "$tmp" 2>/dev/null)"
    rm -f "$tmp"
  fi

  # A non-zero exit can still leave partial output on stdout; judging model
  # access from a truncated listing would invent missing models. Bail instead.
  if [ "$rc" -ne 0 ]; then
    log "diag  : 'opencode models' failed (status ${rc}), so model access could not be checked."
    return 0
  fi
  if [ -z "$avail" ]; then
    log "diag  : 'opencode models' returned nothing, so model access could not be checked."
    return 0
  fi

  # Exact whole-line match. Verified against the real command: one id per line,
  # no header, no ANSI once stdout is a pipe, and — the part that matters for a
  # routed setup — ids carry their provider prefix verbatim, so the prefixed
  # `omniroute/opencode-go/glm-5.2` this script builds is exactly what is listed.
  for m in "$@"; do
    [ -n "$m" ] || continue
    printf '%s\n' "$avail" | grep -qxF -- "$m" || missing="${missing} ${m}"
  done

  if [ -z "$missing" ]; then
    log "diag  : every model involved is present in 'opencode models', so this was not model access."
    return 0
  fi

  log "diag  : NOT available in this OpenCode setup:${missing}"
  log "diag  : that alone accounts for an empty report — opencode exits 0 on an unusable model id and reports only a generic server error."
  log "diag  : name models you do have via OPENCODE_REVIEW_{SWE,ARCH,CHAIR,FACTCHECK}_MODEL, or set OPENCODE_REVIEW_PROVIDER=<id> if they sit behind a router. Run 'opencode models' to see what is configured."
}

# ------------------------------------------------------------ report extraction
# A stage's report is the model's own prose, and the JSON event stream says which
# bytes those are: `text` events and nothing else. Tool output, tool errors, the
# OPENCODE_PERMISSION dump printed on every denied bash call, and the model's
# reading of the diff all arrive as `tool_use` events and are never candidates.
#
# This replaces a fence the personas had to emit plus a de-noiser that inferred
# structure from rendered output. Both failed, in both directions. Models that
# investigated for 30-70 KB and then stopped left nothing fenced, so the fallback
# ran and forwarded whatever the state machine had last seen: one run handed the
# chair 150 bytes of a shell error message as the SWE report, another 99 bytes of
# a model's opening narration as the architect's — each reported `ok, but the
# report was not fenced`, which reads as a formatting nit rather than "this is
# not a review". Reading `text` events makes that class unrepresentable: tool
# output cannot be mistaken for prose when it never shares a channel with it.
#
# It also retires the per-run nonce. That existed because a fence line was
# authoritative wherever it appeared, and members read repository files with cat,
# so the tree under review could forge one. File content is now tool output by
# construction and cannot reach the report at all.
#
# Below this many non-whitespace BYTES (CJK runs ~3/char) the model's prose is a
# courtesy line or a narration fragment, not a report. Unlike the old threshold
# this is applied to text known to be the model's own words, not to a guess.
REPORT_MIN_BYTES=40

# Where a stage's event stream is kept when no report could be extracted from it,
# so the next occurrence can be diagnosed instead of guessed at. Everything else
# lives in WORK_DIR and is removed on exit, and a blank stage prints nothing —
# without this copy there is no way to see what the model was doing when it
# stopped, which the tool_use events show exactly.
#
# The directory is created by mktemp -d on first use: atomically, mode 700, under
# an unpredictable name. A fixed name under a shared /tmp would let a local user
# pre-place a path there — clobbering the evidence, or, since cp follows a
# destination symlink, diverting events that contain the diff under review.
KEEP_DIR=""

# retain_events <file> <stage-label> -> sets KEPT_PATH ("" if not kept).
# Skips an empty file: there is nothing in it to diagnose. Assigns rather
# than prints so KEEP_DIR survives — a command substitution would subshell it
# away and every stage would make its own directory.
KEPT_PATH=""
retain_events() {
  KEPT_PATH=""
  [ -s "$1" ] || return 0
  if [ -z "$KEEP_DIR" ]; then
    KEEP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-XXXXXXXX" 2>/dev/null)" || return 0
    [ -n "$KEEP_DIR" ] || return 0
  fi
  cp "$1" "$KEEP_DIR/$2.log" 2>/dev/null && KEPT_PATH="$KEEP_DIR/$2.log"
}

# json_text <events> -> the model's prose on stdout, text events in order.
# Unparseable lines are skipped rather than fatal: stderr has its own file, but a
# provider can still put a stray line on stdout, and one bad line must not cost
# the whole report. Parts are concatenated raw — opencode emits one event per
# assistant message, already whole, not streamed fragments.
json_text() {
  if [ "$JSON_BIN" = "jq" ]; then
    # -R reads each line as a raw string and `fromjson?` drops the ones that do
    # not parse. Without -R, jq parses the file as a JSON stream and ABORTS at
    # the first malformed line — exiting 0 having silently discarded everything
    # after it, so one stray line on stdout would truncate a report mid-sentence
    # or below the size floor. The python3 branch below always skipped bad lines;
    # this is what makes the two agree.
    jq -Rrj 'fromjson? | select(.type == "text") | .part.text // empty' <"$1" 2>/dev/null
  else
    python3 -c '
import json, sys
with open(sys.argv[1], "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "text":
            sys.stdout.write((d.get("part") or {}).get("text") or "")
' "$1" 2>/dev/null
  fi
}

# json_stats <events> -> "<text-events> <tool-calls> <last-step-finish-reason>"
# Describes what the stage did, so a stage that produced no report can be told
# apart from one that never ran. `reason` is opencode's own word for why the
# model stopped: "stop" when it chose to, "tool-calls" when it was still working.
json_stats() {
  if [ "$JSON_BIN" = "jq" ]; then
    # -Rn with `inputs` for the same reason as json_text: slurping (-s) makes one
    # malformed line fail the whole parse, which would report a model that spoke
    # as having produced nothing at all.
    jq -Rrn '
      [inputs | fromjson?] |
      [ (map(select(.type == "text")) | length),
        (map(select(.type == "tool_use")) | length),
        ((map(select(.type == "step_finish")) | last | .part.reason) // "none")
      ] | @tsv' <"$1" 2>/dev/null
  else
    python3 -c '
import json, sys
t = u = 0
reason = "none"
with open(sys.argv[1], "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        k = d.get("type")
        if k == "text":
            t += 1
        elif k == "tool_use":
            u += 1
        elif k == "step_finish":
            reason = (d.get("part") or {}).get("reason") or reason
print("%d\t%d\t%s" % (t, u, reason))
' "$1" 2>/dev/null
  fi
}

# report_bytes <file> -> non-whitespace byte count.
# LC_ALL=C: reports are largely CJK and BSD tr is not multibyte-safe; a byte
# count is all this needs, and bytewise deletion cannot choke on a UTF-8 lead.
report_bytes() { LC_ALL=C tr -d '[:space:]' <"$1" | wc -c | tr -d ' '; }

# extract_report <events> <outfile> [stage-label]
# Writes the stage's report to <outfile>. Exit status:
#   0  the model produced prose — this is the good path
#   2  no report: either it never spoke, or what it said is too short to be one
#
# The old status 1 ("unfenced, de-noised transcript used") is gone. It existed
# only because the fallback could not tell prose from tool output; there is no
# such fallback now, so a stage either produced text or it did not.
#
# STAGE_STOP is set to a description when the model ran and stopped without
# reporting, which is a different failure from a silent or timed-out run: it did
# the work and then declined to write it up. Callers surface it.
STAGE_STOP=""
extract_report() {
  local in="$1" out="$2" stage="${3:-stage}" bytes stats texts tools reason errsz kept_events kept_err

  STAGE_STOP=""
  json_text "$in" >"$out"
  # Text parts are concatenated exactly as the model wrote them, and a model
  # rarely ends on a newline — without one, whatever the caller prints next runs
  # onto the report's last line (the END OF REVIEW marker did precisely that).
  # In a command substitution a trailing newline is stripped, so a non-empty
  # result here means the last byte was not one.
  [ -s "$out" ] && [ -n "$(tail -c1 "$out")" ] && printf '\n' >>"$out"
  bytes="$(report_bytes "$out")"

  stats="$(json_stats "$in")"
  texts="$(printf '%s' "$stats" | cut -f1)"
  tools="$(printf '%s' "$stats" | cut -f2)"
  reason="$(printf '%s' "$stats" | cut -f3)"
  [ -n "$texts" ] || texts=0
  [ -n "$tools" ] || tools=0
  [ -n "$reason" ] || reason=none

  [ "$bytes" -ge "$REPORT_MIN_BYTES" ] && return 0

  : >"$out"
  # Order matters and the result must be captured immediately: retain_events
  # clears KEPT_PATH on entry, so retaining stderr second would blank or replace
  # the events path that the WARN below is meant to point at. The events file is
  # the useful one — it holds the tool calls showing what the model was doing.
  retain_events "$in" "$stage"
  kept_events="$KEPT_PATH"
  kept_err=""
  if [ -s "${in}.err" ]; then
    retain_events "${in}.err" "${stage}.stderr"
    kept_err="$KEPT_PATH"
  fi
  KEPT_PATH="$kept_events"

  # A model that made tool calls and then stopped is the case issue #33 is about:
  # it read the diff, investigated, and ended its turn with nothing written. Say
  # that plainly instead of reporting it the same way as a run that never started.
  if [ "$tools" -gt 0 ] && [ "$texts" -eq 0 ]; then
    STAGE_STOP="stopped after ${tools} tool calls without writing anything (reason=${reason})"
    log "WARN: ${stage}: ${STAGE_STOP}. Events: $(wc -c <"$in" | tr -d ' ') B kept at ${kept_events:-<none>}${kept_err:+, stderr at $kept_err}"
  else
    errsz=0
    [ -f "${in}.err" ] && errsz="$(wc -c <"${in}.err" | tr -d ' ')"
    STAGE_STOP="produced no usable report (${texts} text events, ${tools} tool calls, reason=${reason})"
    log "WARN: ${stage}: ${STAGE_STOP}. Events: $(wc -c <"$in" | tr -d ' ') B kept at ${kept_events:-<none>}, stderr ${errsz} B${kept_err:+ kept at $kept_err}"
  fi
  return 2
}

# stage_note <run-exit-status> <extract-status> [stop-description] -> the label
# shown in the log and handed to the chair, so "exited 0 having written nothing"
# can no longer read ok.
stage_note() {
  case "$2" in
  0) status_note "$1" ;;
  *)
    if [ -n "${3:-}" ]; then
      printf 'NO REPORT PRODUCED — %s (run %s)' "$3" "$(status_note "$1")"
    else
      printf 'NO REPORT PRODUCED (run %s)' "$(status_note "$1")"
    fi
    ;;
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
  log "mode  : single model '${SINGLE_MODEL}' (SWE persona)"
  [ -z "$TIMEOUT_BIN" ] && log "note  : no 'timeout'/'gtimeout'; built-in watchdog (${TIMEOUT}s)."
  echo "===== OPENCODE REVIEW (model ${SINGLE_MODEL}) — ${SCOPE} ====="
  oc_run --model "$SINGLE_MODEL" "$(member_msg "$(read_prompt "$PROMPTS_DIR/swe.md")")" "$single_out"
  st=$?
  extract_report "$single_out" "$single_rep" "single-model"
  ex=$?
  single_stop="$STAGE_STOP"
  cat "$single_rep"
  echo "===== END OF REVIEW ====="
  log "single-model review: $(stage_note "$st" "$ex" "$single_stop")"
  { [ "$st" -ne 0 ] || [ "$ex" -eq 2 ]; } && diagnose_models "$SINGLE_MODEL"
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
swe_stop="$STAGE_STOP"
extract_report "$arch_out" "$arch_rep" "architect"
arch_ex=$?
arch_stop="$STAGE_STOP"
log "phase 1 done: swe=$(stage_note "$swe_st" "$swe_ex" "$swe_stop"), architect=$(stage_note "$arch_st" "$arch_ex" "$arch_stop")"

# Phase 2 — the chair dedupes/verifies both reports against the same target. It
# receives the extracted reports, which is what prompts/chair.md says it will get;
# a member that wrote nothing is announced as such, so the chair's own
# "note which member is absent" rule can actually fire.
log "phase 2: chair (synthesis)"
chair_msg="$(printf '%s\n\n===== SWE report (correctness/bugs/security) [%s] =====\n%s\n\n===== Architect report (design/architecture) [%s] =====\n%s\n\n===== review target =====\n%s\n' \
  "$CHAIR_PERSONA" \
  "$(stage_note "$swe_st" "$swe_ex" "$swe_stop")" "$(cat "$swe_rep")" \
  "$(stage_note "$arch_st" "$arch_ex" "$arch_stop")" "$(cat "$arch_rep")" \
  "$MSG")"
log "phase 2: chair prompt is $(printf '%s' "$chair_msg" | wc -c | tr -d ' ') B (swe report $(wc -c <"$swe_rep" | tr -d ' ') B of $(wc -c <"$swe_out" | tr -d ' ') B captured, architect $(wc -c <"$arch_rep" | tr -d ' ') B of $(wc -c <"$arch_out" | tr -d ' ') B)"
oc_run --model "$CHAIR_MODEL" "$chair_msg" "$chair_out"
chair_st=$?
extract_report "$chair_out" "$chair_rep" "chair"
chair_ex=$?
chair_stop="$STAGE_STOP"

# Phase 3 (optional) — fact-check the chair's report against the diff only,
# pruning findings the diff can directly falsify. On any failure the chair's
# report is emitted unchanged, so this phase can only ever reduce false positives.
fc_st=0
fc_stop=""
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
  fc_stop="$STAGE_STOP"
  if [ "$fc_st" -eq 0 ] && [ "$fc_ex" -ne 2 ]; then
    fc_applied=1
    log "phase 3 done: fact-check applied"
  else
    log "WARN: fact-check $(stage_note "$fc_st" "$fc_ex" "$fc_stop"); emitting chair report unchanged."
  fi
fi

if [ "$fc_applied" -eq 1 ]; then
  cat "$fc_rep"
elif [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ]; then
  cat "$chair_rep"
else
  log "WARN: chair $(stage_note "$chair_st" "$chair_ex" "$chair_stop"); falling back to the member reports."
  printf '## SWE (correctness) [%s]\n\n' "$(stage_note "$swe_st" "$swe_ex" "$swe_stop")"
  cat "$swe_rep"
  printf '\n## Architect (design) [%s]\n\n' "$(stage_note "$arch_st" "$arch_ex" "$arch_stop")"
  cat "$arch_rep"
fi

# How many members actually contributed. A chair report built on no members is
# one model's opinion wearing a committee's shape — the diversity that justifies
# the whole design is gone. The chair is told to note an absence and does, but
# that lands in its preamble where a skimming reader misses it. This goes after
# the report, inside the markers, so it is the last thing read.
absent=0
[ "$swe_ex" -eq 2 ] && absent=$((absent + 1))
[ "$arch_ex" -eq 2 ] && absent=$((absent + 1))
if [ "$absent" -gt 0 ]; then
  printf '\n---\n\n**DEGRADED: %d of 2 members produced no report.** ' "$absent"
  # The chair's own state decides what is true here. Claiming a solo chair
  # judgment when the chair also produced nothing would describe output that
  # does not exist — above would be two empty member sections.
  if [ "$absent" -eq 2 ] && [ "$chair_st" -eq 0 ] && [ "$chair_ex" -ne 2 ]; then
    printf 'Nothing above is a committee finding — it is a solo judgment by the chair model, which read the diff itself. '
  elif [ "$absent" -eq 2 ]; then
    printf 'The chair produced nothing either, so there is no review above at all — every stage failed. '
  else
    printf 'One perspective is missing from everything above. '
  fi
  printf 'See the [opencode-review] WARN lines on stderr for what each absent stage did before stopping.\n'
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
  log "committee review finished with issues (chair=$(stage_note "$chair_st" "$chair_ex" "$chair_stop"), swe=$(stage_note "$swe_st" "$swe_ex" "$swe_stop"), architect=$(stage_note "$arch_st" "$arch_ex" "$arch_stop"))."
  # Only the models that actually failed, so the report names causes rather than
  # every model the run happened to mention.
  diag_models=""
  { [ "$swe_st" -ne 0 ] || [ "$swe_ex" -eq 2 ]; } && diag_models="$diag_models $SWE_MODEL"
  { [ "$arch_st" -ne 0 ] || [ "$arch_ex" -eq 2 ]; } && diag_models="$diag_models $ARCH_MODEL"
  { [ "$chair_st" -ne 0 ] || [ "$chair_ex" -eq 2 ]; } && diag_models="$diag_models $CHAIR_MODEL"
  { [ "$fc_st" -ne 0 ] || [ "$fc_ex" -eq 2 ]; } && diag_models="$diag_models $FACTCHECK_MODEL"
  # Unquoted on purpose: this is a space-separated list being split into args,
  # and model ids cannot contain whitespace or globbing characters.
  # shellcheck disable=SC2086
  [ -n "$diag_models" ] && diagnose_models $diag_models
fi
exit "$status"
