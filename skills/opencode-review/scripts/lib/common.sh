# shellcheck shell=bash
#
# opencode-review / scripts/lib/common.sh
#
# Everything the review and the verify runs both need: the headless-run
# permission set, the private scratch dir, the bounded `opencode run` wrapper,
# and the JSON event-stream readers that turn a run into a report.
#
# Sourced, never executed. It defines functions and computes the permission set;
# the caller then sets its own model/seat variables and calls oc_env_init to
# create the scratch dir, start the --variant probe, and resolve the readable
# paths outside the repo. Split out of run-review.sh when run-verify.sh appeared
# and would otherwise have had to copy ~900 lines of it.
#
# Two strings the callers own, because their text names caller-specific env vars:
#   OC_LOG_PREFIX       the "[...]" every log line carries (default opencode-review)
#   OC_MODEL_ENV_HINT   what diagnose_models tells you to set when a model is missing
#   OC_VARIANT_ENV_HINT what report_variant_support tells you to clear
#
# Dry run: with OPENCODE_REVIEW_DRY_RUN=1, oc_run synthesises an event stream
# instead of calling opencode, and oc_env_init skips the two probing opencode
# calls. Nothing is billed and nothing reaches a provider, so the orchestration
# — seat fan-out, message assembly, report plumbing, exit statuses — can be
# exercised end to end. It is a test seam, not a review.

# Resolved from this file, not from the entry script, so a caller in any
# directory finds the prompts.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/../.." && pwd)"
PROMPTS_DIR="$SKILL_DIR/prompts"
RULES_DIR="$PROMPTS_DIR/rules"

OC_LOG_PREFIX="${OC_LOG_PREFIX:-opencode-review}"
OC_MODEL_ENV_HINT="${OC_MODEL_ENV_HINT:-OPENCODE_REVIEW_{SWE,ARCH,CHAIR,FACTCHECK}_MODEL}"
OC_VARIANT_ENV_HINT="${OC_VARIANT_ENV_HINT:-OPENCODE_REVIEW_{SWE,ARCH,CHAIR,FACTCHECK}_VARIANT}"
DRY_RUN="${OPENCODE_REVIEW_DRY_RUN:-0}"
TIMEOUT="${TIMEOUT:-900}"

# ---------------------------------------------------------- reasoning variants
# `opencode run --variant <effort>` picks a model's reasoning effort. Every seat
# in this skill runs at or near the top of what its model offers: effort is far
# cheaper than a bigger model, and every stage here is a judgment task rather
# than a throughput one.
#
# The values are NOT interchangeable between models — they come from each model's
# own reasoning_options, and the ladders genuinely differ (glm/deepseek top out at
# "max", muse/qwen at "xhigh"; not every model has all rungs, and some have none).
# So a variant default is only valid for the model it was chosen for: naming your
# own model for a seat clears that seat's variant unless you also name a variant,
# rather than passing an effort the new model may reject. Explicit "" = no variant.
seat_variant() { # $1 seat env value (unset marker), $2 model-was-overridden, $3 default
  if [ "$1" != "__unset__" ]; then printf '%s' "$1"; # explicit, including ""
  elif [ -n "$2" ]; then printf '';                  # custom model, no variant guess
  else printf '%s' "$3"; fi
}

log() { printf '[%s] %s\n' "$OC_LOG_PREFIX" "$*" >&2; }

# "model" or "model @effort" — the variant changes what a seat produced, so it
# belongs wherever the model is logged rather than only in the env docs.
seat_desc() { # $1 model, $2 variant
  if [ -n "${2:-}" ]; then printf '%s @%s' "$1" "$2"; else printf '%s' "$1"; fi
}

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

# Personas carry {{EXTERNAL_READ_PATHS}} where a hardcoded "outside the repo is
# denied" sentence used to be, and it is filled here — the one place every
# persona is loaded, members and chair alike. Substituted rather than appended to
# the message: an appended list would sit alongside the old claim and leave the
# model to pick between two contradicting boundaries, and the persona tells it to
# trust the written one.
#
# Bash parameter expansion, not sed or awk. The replacement is multi-line and
# holds absolute paths: sed would need "/" escaped and would mangle a path
# containing "&", and BSD awk rejects a newline inside a -v assignment outright
# ("newline in string"). ${var//pat/rep} has neither problem and spawns nothing.
#
# READ_PATHS_BLOCK must therefore be set before the first call; it is computed
# unconditionally, right after the scratch dir, and every caller here is in the
# stage-running section far below it.
read_prompt() { # $1 file -> persona text with the read-path list filled in
  [ -f "$1" ] || {
    log "ERROR: prompt file missing: $1"
    exit 1
  }
  local text
  text="$(cat "$1")"
  printf '%s\n' "${text//\{\{EXTERNAL_READ_PATHS\}\}/$READ_PATHS_BLOCK}"
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
  # printf '%s\n', not '%s': without the trailing newline `tr` leaves the LAST
  # field unterminated, `read` returns non-zero on it, and the loop exits before
  # the body runs for it — so the last path was always dropped, and with a single
  # path (the common case, and the one #24 added this for) the variable did
  # nothing at all. The two caches above escape this only because they already
  # print a newline. The extra empty line an unset variable now produces is eaten
  # by the `[ -n "$d" ]` guard.
  printf '%s\n' "${OPENCODE_REVIEW_DEP_DIRS:-}" | tr ':' '\n' | while IFS= read -r d; do
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

# What this contributes to the permission set is not the whole of what the file
# tools may read — the user's own config merges in — so the "deps :" line that
# used to sit here now lives with READ_PATHS below, where the merged answer is.
EXT_DIR_RULES="$(external_dirs_rules)"

# The bash map is kept as a single-quoted literal so patterns like "*$(*" are not
# touched by the shell; only the outer object is assembled.
#
# opencode matches this map per SHELL SEGMENT, not against the whole command
# string: it splits on ";", "&&" and "|" and every segment must hit an allow
# pattern on its own. That is what actually enforces the read-only set —
# `cat f | wc -l` runs because both halves are allowed, `ls | xargs cat` is
# refused because `xargs` is not. Measured, not assumed (issue #46).
#
# Two consequences, both counter-intuitive enough to be worth writing down:
#   - "*;*", "*|*" and "*&*" deny patterns are DEAD. The separator is consumed by
#     the split, so no segment ever contains one and the pattern never matches.
#     They were in this map until #46 and refused nothing in their whole life.
#   - What they DID match was a separator inside a quoted argument, where the
#     shell split leaves it in place: `git grep -n "A\|B"` — an ordinary
#     alternation — was denied as if it were command chaining. In the run that
#     produced the #46 evidence that misfire accounted for seven of eight
#     denials and cost one seat its entire report. Removing the three patterns is
#     what lets a multi-pattern grep through; single "&" is still refused, because
#     opencode splits on it too (`ls & pwd` and `ls&pwd` were both measured denied).
# The redirect, backtick, $(...) and <(...) denies are kept: those were measured
# refusing what they are aimed at.
PERM_BASH='{"*":"deny","git diff*":"allow","git show*":"allow","git log*":"allow","git status*":"allow","git ls-files*":"allow","git rev-parse*":"allow","git blame*":"allow","git grep*":"allow","cat *":"allow","head *":"allow","tail *":"allow","wc *":"allow","ls":"allow","ls *":"allow","grep *":"allow","rg *":"allow","*>*":"deny","*`*":"deny","*$(*":"deny","*<(*":"deny","*\n*":"deny"}'
PERM="{\"edit\":\"deny\",\"question\":\"deny\",\"doom_loop\":\"deny\",\"webfetch\":\"deny\",\"websearch\":\"deny\",\"task\":\"deny\",\"skill\":\"deny\",\"lsp\":\"deny\",${EXT_DIR_RULES}\"bash\":${PERM_BASH}}"

# ------------------------------------------- readable paths outside the repo
# What the file tools may actually read for THIS run is not what dep_dirs
# computed. OPENCODE_PERMISSION is MERGED with the saved config, and
# external_directory merges DEEP, so a path allowed in the user's global config
# or in the project's opencode.json is readable too — and this script never saw
# it. Only opencode can answer what the merge produced, so it is asked.
#
# This matters beyond the log line. The personas tell members what is readable,
# and they are told to trust that boundary rather than discover it by probing. A
# list built from this script's own inputs under-reports, so members correctly do
# not try, and a sibling repo the user deliberately opened up goes unread: the
# report says "cannot verify" about something that was verifiable all along (#42).
#
# Placed here rather than next to PERM for three reasons: PERM must exist (it is
# the question being asked), WORK_DIR must exist (the no-timeout watchdog needs
# somewhere private for the output), and the --variant probe is already running
# in the background, so this call overlaps with it instead of adding to it.
#
# Bounded like every other opencode call here. Measured at ~5s on the machine
# this was written on, and unlike the probe it is synchronous and sits ahead of
# phase 1 — unbounded, a stuck provider or session lock would hang the run before
# any model work started.
READ_PATHS_TIMEOUT=30

# Fail soft, always. A `debug config` that is missing (older opencode), exits
# non-zero, times out or prints something unparseable falls back to dep_dirs,
# which is exactly the behaviour before this existed. A review is never lost to
# a lookup that only ever adds information.
#
# `~` is expanded because a persona needs an absolute path; opencode does expand
# `~` when MATCHING these globs, so the expanded form and the stored form select
# the same files. Only "allow" entries are taken — the map can also carry "deny"
# and "ask", and listing those would send members at reads that get rejected,
# the exact cost #24 set out to remove. Only a trailing "/**" is stripped; any
# other glob is passed through as written, which still reads correctly as "under
# here" in a persona.
effective_external_dirs() {
  local json rc tmp pid wpid
  tmp="$WORK_DIR/debug-config.out"
  if [ -n "$TIMEOUT_BIN" ]; then
    OPENCODE_PERMISSION="$PERM" "$TIMEOUT_BIN" "$READ_PATHS_TIMEOUT" \
      opencode debug config --pure >"$tmp" 2>/dev/null </dev/null
    rc=$?
  else
    # Same shape as diagnose_models' fallback watchdog, for a machine with no
    # timeout(1). </dev/null on both branches: opencode subcommands that wait on
    # stdin produce nothing and look exactly like a hung provider.
    OPENCODE_PERMISSION="$PERM" opencode debug config --pure >"$tmp" 2>/dev/null </dev/null &
    pid=$!
    (
      sleep "$READ_PATHS_TIMEOUT"
      kill -TERM "$pid" 2>/dev/null
      sleep 3
      kill -KILL "$pid" 2>/dev/null
    ) &
    wpid=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
  fi
  json="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
  [ -n "$json" ] || return 1

  if [ "$JSON_BIN" = "jq" ]; then
    printf '%s' "$json" | jq -r --arg home "$HOME" '
      (.permission.external_directory // {})
      | [ to_entries[]
          | select(.value == "allow")
          | .key
          | sub("/\\*\\*$"; "")
          | sub("^~"; $home) ] as $all
      | ($all | map(select(
          startswith("/")
          and (test("[[:cntrl:]]|`") | not)
          and (length <= 512)
        ))) as $ok
      | "#rejected \(($all | length) - ($ok | length))", $ok[]
    ' 2>/dev/null
  else
    printf '%s' "$json" | python3 -c '
import json, os, sys
try:
    cfg = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ext = ((cfg.get("permission") or {}).get("external_directory")) or {}
if not isinstance(ext, dict):
    sys.exit(1)
home = os.path.expanduser("~")
ok, rejected = [], 0
for key, value in ext.items():
    if value != "allow":
        continue
    key = key[:-3] if key.endswith("/**") else key
    if key.startswith("~"):
        key = home + key[1:]
    if (not key.startswith("/")) or len(key) > 512 or any(
        ord(c) < 32 or ord(c) == 127 or c == "`" for c in key
    ):
        rejected += 1
        continue
    ok.append(key)
print("#rejected %d" % rejected)
for key in ok:
    print(key)
' 2>/dev/null
  fi
}

# oc_env_init <variants-this-run-will-pass>
#
# The ordered half of the setup, which is why it is a function and not more
# top-level code: WORK_DIR must exist before the no-timeout watchdogs have
# anywhere private to write, PERM must exist before opencode can be asked what
# the merged config allows, and the --variant probe wants to be running in the
# background while that question is answered. The caller decides its own seats
# and variants first, then calls this once.
#
# The argument is the concatenation of every variant this run will actually pass.
# Empty means no `--variant` anywhere, and the probe is not started at all — the
# warning it arms would be about a flag the run never used.
oc_env_init() {
VARIANTS_REQUESTED="${1:-}"
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
# --------------------------------------------------- --variant support probe
# Whether this opencode understands `run --variant` is a fact about the binary,
# so it is established once per run and reported on EVERY path — not only when
# something failed.
#
# The failure path is the half that does not matter. An argument parser that
# REJECTS the unknown flag fails every stage at once, and the run is already
# loud. The dangerous half is a parser that IGNORES it: every stage succeeds, the
# committee runs at its models' default effort, and the log says `@xhigh` — a
# report that is quietly worse than the one it claims to be, with nothing
# anywhere saying so. A check that only runs after a failure cannot see that case
# by construction.
#
# So it runs on the happy path too, and the ~6s it costs is spent in the
# BACKGROUND, concurrently with phase 1, which takes minutes. The verdict is
# harvested at the end by report_variant_support, where it is needed. Nothing
# waits on it, and a run that passes no variant at all never starts it.
#
# Scoped to the variants THIS RUN will actually pass, which is decided by the mode
# below: the --agent escape hatch passes none (the agent carries its own model and
# effort), the single-model path passes only its own, and the committee passes the
# four seats' — minus fact-check when that phase is switched off. Summing all of
# them regardless would arm the warning for a flag the run never used.
#
# BOUNDED, on both branches. report_variant_support waits on this pid, so an
# unbounded probe would be strictly worse than no probe: every stage could finish
# and the report be ready, and the run would still never return — a hang
# introduced by a diagnostic, on the happy path, for a machine that already has
# no timeout(1). Where timeout(1) exists it does the work; where it does not, the
# same built-in watchdog oc_run and diagnose_models use does. A probe killed
# either way leaves an empty capture, which report_variant_support already reads
# as "claim nothing".
#
# SELF-CONTAINED, which is the part the shape here exists for. The whole probe —
# the call, its watchdog, and the reaping of both — is one background unit, and
# the main shell tracks only the wrapper.
#
# The obvious spelling, a bare `opencode run --help &` plus a sleep-then-kill
# watchdog held in a variable, is wrong HERE in a way it is not wrong in oc_run.
# oc_run waits for its process and cancels its watchdog on the next line; this
# probe is deliberately harvested at the END of the run, minutes later. A
# sleep(30) watchdog whose cancellation is deferred that long is not guarding
# anything for most of its life — the probe finishes in ~6s — and bash reaps
# background children eagerly rather than leaving zombies that hold their pid, so
# by the time the watchdog woke it could TERM a pid the kernel had since handed
# to someone else. Measured, not assumed: `sleep 0.2 & p=$!; sleep 1; kill -0 $p`
# already fails, well before any `wait`.
#
# Reaping inside the wrapper closes that. The watchdog is cancelled the instant
# the probe exits, so the window where its target pid is stale is the microseconds
# between the inner `wait` returning and the `kill` on the next line — the same
# residual oc_run has, rather than a multi-minute one. Cancelling it really does
# disarm it: killing the watchdog shell leaves its `sleep` orphaned, but the
# `kill -TERM` after that sleep is a line the dead shell never reaches. Verified
# by letting a cancelled watchdog's deadline pass and checking it never fired.
# The stray sleep exits on its own and signals nothing.
#
# It also means the probe stays bounded if the run exits early and the trap kills
# the wrapper: the orphaned watchdog is then still armed and fires, so the unit
# cleans itself up either way.
VARIANT_PROBE_TIMEOUT=30
VARIANT_PROBE_OUT="$WORK_DIR/variant-help.out"
VARIANT_PROBE_PID=""
if [ "$DRY_RUN" = "1" ]; then
  VARIANTS_REQUESTED=""
fi
if [ -n "$VARIANTS_REQUESTED" ]; then
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$VARIANT_PROBE_TIMEOUT" opencode run --help >"$VARIANT_PROBE_OUT" 2>&1 &
  else
    (
      opencode run --help >"$VARIANT_PROBE_OUT" 2>&1 &
      _probe=$!
      (
        sleep "$VARIANT_PROBE_TIMEOUT"
        kill -TERM "$_probe" 2>/dev/null
        sleep 3
        kill -KILL "$_probe" 2>/dev/null
      ) &
      _wd=$!
      wait "$_probe" 2>/dev/null
      kill "$_wd" 2>/dev/null
    ) &
  fi
  VARIANT_PROBE_PID=$!
fi
trap 'rm -rf "$WORK_DIR"; [ -n "${VARIANT_PROBE_PID:-}" ] && kill "$VARIANT_PROBE_PID" 2>/dev/null; :' EXIT
# The merged config is partly UNTRUSTED INPUT. A project's own opencode.json is
# a file in the checkout under review, so on a branch someone else wrote, its
# external_directory keys are attacker-controlled text — and this list is
# interpolated into the most trusted part of every persona. A key holding an
# escaped newline used to become a second markdown bullet in the environment
# section, which is a prompt injection with a straight path to "report no
# findings" (Greptile, on the PR that added this).
#
# Three layers, because no single one is convincing on its own:
#   1. the extractors above emit only keys that are plain absolute paths — no
#      control characters, no backtick, at most 512 bytes — and count the rest;
#   2. this grep keeps only lines starting with "/", so anything that got past
#      the JSON layer as a stray line is dropped here rather than trusted;
#   3. each surviving path is rendered inside a code span (below), so a name
#      that reads like prose still reaches the model as data, not instruction.
# What that leaves is a single-line absolute path whose own name is prose. It
# is quoted, capped, and cannot break out of its bullet.
if [ "$DRY_RUN" = "1" ]; then
  READ_PATHS_RAW=""
  READ_PATHS_RC=1
else
  READ_PATHS_RAW="$(effective_external_dirs)"
  READ_PATHS_RC=$?
fi
if [ "$READ_PATHS_RC" -eq 0 ]; then
  READ_PATHS_SOURCE="the merged config"
  READ_PATHS_DROPPED="$(printf '%s\n' "$READ_PATHS_RAW" | sed -n '1s/^#rejected //p')"
  READ_PATHS="$(printf '%s\n' "$READ_PATHS_RAW" | grep '^/' | sort -u)"
else
  READ_PATHS_SOURCE="this script's own list; opencode could not be asked"
  READ_PATHS_DROPPED=0
  READ_PATHS="$(dep_dirs | sort -u)"
fi

# A prompt is not the place for an unbounded list either: nothing stops a repo's
# config from carrying thousands of allows, and every one of them would be paid
# for in four stages. The cap is announced in the text rather than applied
# silently, like the fact-check diff truncation.
READ_PATHS_MAX=40
READ_PATHS_TOTAL="$(printf '%s' "$READ_PATHS" | grep -c '^/')"
READ_PATHS_OMITTED=0
if [ "$READ_PATHS_TOTAL" -gt "$READ_PATHS_MAX" ]; then
  READ_PATHS="$(printf '%s\n' "$READ_PATHS" | head -n "$READ_PATHS_MAX")"
  READ_PATHS_OMITTED=$((READ_PATHS_TOTAL - READ_PATHS_MAX))
fi

if [ -n "$READ_PATHS" ]; then
  log "deps  : file-tool reads allowed under $(printf '%s\n' "$READ_PATHS" | tr '\n' ' ')($READ_PATHS_SOURCE)"
else
  log "deps  : no readable path outside the repo; file tools stay repo-only"
fi
# Counts only. The rejected keys are attacker-controlled text and the caller
# reads this stream, so they are not echoed anywhere.
if [ "${READ_PATHS_DROPPED:-0}" != "0" ]; then
  log "deps  : ignored ${READ_PATHS_DROPPED} external_directory entries that were not plain absolute paths"
fi
if [ "$READ_PATHS_OMITTED" -gt 0 ]; then
  log "deps  : listing the first ${READ_PATHS_MAX}; ${READ_PATHS_OMITTED} more are allowed but not named in the personas"
fi

# Every persona gets this list substituted in by read_prompt, so no prompt file
# states the boundary itself and none of them can drift from the permission set
# actually in force.
if [ -n "$READ_PATHS" ]; then
  READ_PATHS_BLOCK="$(printf '%s\n' "$READ_PATHS" | sed 's/^/  - `/; s/$/`/')"
  if [ "$READ_PATHS_OMITTED" -gt 0 ]; then
    READ_PATHS_BLOCK="$READ_PATHS_BLOCK
  - (另有 ${READ_PATHS_OMITTED} 個路徑同樣可讀,未列出)"
  fi
else
  READ_PATHS_BLOCK="  - (本次執行沒有 repo 外的可讀路徑,檔案工具僅限本 repo)"
fi
}

# Reports the probe's verdict. Called once, last, on every exit path that ran
# stages — success and failure alike.
#
# It states what the binary does, and deliberately does not attribute a failure
# to it. Attribution was the earlier version's other bug: it fired whenever ANY
# seat's variant was non-empty, so a single-model run with no variant, or a
# custom-model seat whose variant was deliberately cleared, could be told that a
# missing --variant explained a failure it had no part in. What ran is knowable;
# why a given stage died is not, from here.
#
# Silence on an unreadable probe, for the same reason diagnose_models bails on a
# truncated listing: empty output would otherwise "prove" the flag missing on any
# machine where --help itself failed.
report_variant_support() {
  # One pid to wait on: the wrapper has already reaped the probe and cancelled
  # its watchdog by the time it exits.
  [ -n "$VARIANT_PROBE_PID" ] || return 0
  wait "$VARIANT_PROBE_PID" 2>/dev/null
  VARIANT_PROBE_PID=""
  local help
  help="$(cat "$VARIANT_PROBE_OUT" 2>/dev/null)"
  [ -n "$help" ] || return 0
  case "$help" in
    *--variant*) return 0 ;;
  esac
  log "WARN: this 'opencode' has no 'run --variant' flag. The reasoning effort logged above as '@...' was therefore NOT applied — each stage ran at its model's default effort, whatever the log line said."
  log "WARN: upgrade opencode, or set ${OC_VARIANT_ENV_HINT}=\"\" to stop passing a flag this binary does not take."
}


# ------------------------------------------------------------------- dry run
# A test seam, not a review. With OPENCODE_REVIEW_DRY_RUN=1 no provider is
# reached and nothing is billed; oc_run synthesises the same event stream shape
# opencode emits, so everything downstream of the model call — extract_report,
# the stage notes, seat fan-out, message assembly, the exit-status rules — runs
# exactly as it does for real.
#
# It exists because the orchestration is the part that breaks when seats are
# added or the script is split, and it is precisely the part a real run is too
# slow and too expensive to exercise repeatedly. Committee runs take minutes and
# cost four model calls; this takes under a second and costs nothing.
#
# The synthesised report ECHOES what the stage was given: its model, variant, and
# the size and first line of its message. That is what makes the seam able to
# catch a wiring bug — a seat handed the wrong persona, a chair handed an empty
# member report — rather than merely proving the plumbing does not crash.
#
# Failures are injectable, since the degraded paths are the ones worth testing
# and the ones a real run will not produce on demand:
#
#   OPENCODE_REVIEW_DRY_RUN_FAIL="swe=empty,chair=error,sre=timeout"
#
#   empty    the model ran, made tool calls, and wrote nothing (issue #33)
#   error    the provider refused the call, with a message
#   timeout  the run hit its deadline (exit 124)
DRY_RUN_FAIL="${OPENCODE_REVIEW_DRY_RUN_FAIL:-}"

# dry_run_mode <stage> -> the injected failure for this stage, or "" for none.
dry_run_mode() {
  local entry
  printf '%s\n' "$DRY_RUN_FAIL" | tr ',' '\n' | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
    "$1="*) printf '%s' "${entry#*=}" ;;
    esac
  done
}

# dry_run_stage <stage> <model> <message> <variant> <outfile>
# Writes an event stream and returns what the real call would have returned.
# The JSON is assembled with printf rather than a JSON tool because every value
# in it is generated here from ASCII this function controls — a stage label, a
# model id, two integers — so there is nothing to escape, and the seam must work
# on a machine with only jq as well as one with only python3.
dry_run_stage() {
  local stage="$1" model="$2" msg="$3" variant="$4" out="$5" mode bytes head1
  mode="$(dry_run_mode "$stage")"
  bytes="$(printf '%s' "$msg" | wc -c | tr -d ' ')"
  # First line of the message, which is the persona's opening sentence — enough
  # to tell "this seat got the SWE persona" from "this seat got the architect's".
  head1="$(printf '%s' "$msg" | head -1 | cut -c1-60 | tr -d '"\\')"

  : >"$out"
  : >"${out}.err"
  case "$mode" in
  error)
    printf '{"type":"error","error":{"name":"ProviderError","data":{"message":"[dry run] injected provider error for stage %s"}}}\n' "$stage" >"$out"
    return 1
    ;;
  timeout)
    printf '{"type":"tool_use","part":{"tool":"bash"}}\n' >"$out"
    return 124
    ;;
  empty)
    # Tool calls but no text: the model investigated and stopped without writing.
    printf '{"type":"tool_use","part":{"tool":"bash"}}\n{"type":"tool_use","part":{"tool":"read"}}\n{"type":"step_finish","part":{"reason":"stop"}}\n' >"$out"
    return 0
    ;;
  esac

  {
    printf '{"type":"tool_use","part":{"tool":"bash"}}\n'
    printf '{"type":"text","part":{"text":"## [DRY RUN] stage=%s model=%s variant=%s\\n\\nmessage was %s bytes; it began: %s\\n\\nNo model was called and nothing was reviewed. This report exists so the orchestration around it can be exercised without a provider.\\n"}}\n' \
      "$stage" "$model" "${variant:-none}" "$bytes" "$head1"
    printf '{"type":"step_finish","part":{"reason":"stop"}}\n'
  } >"$out"
  return 0
}

# oc_run <flag> <value> <message> <outfile> [variant]
# Runs one opencode invocation headlessly (flag is --model or --agent), capturing
# its JSON event stream to <outfile>, one event per line.
#
# <variant> is the reasoning effort passed as `--variant`. Empty (the default)
# means the flag is not passed at all rather than passed empty: opencode reads a
# variant name against the model's own ladder, and "" is not a rung on any of
# them. It is built as an ARRAY so an empty one expands to no words — the older
# `${var:+--variant $var}` spelling would word-split a value with a space in it.
#
# Whether the installed opencode takes the flag at all is established separately,
# by the background probe above; see report_variant_support.
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
  local flag="$1" val="$2" msg="$3" out="$4" variant="${5:-}" stage="${6:-$2}" st td pid wpid
  local vopt=()
  if [ "$DRY_RUN" = "1" ]; then
    dry_run_stage "$stage" "$val" "$msg" "$variant" "$out"
    return $?
  fi
  [ -n "$variant" ] && vopt=(--variant "$variant")
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
      "$TIMEOUT_BIN" "$TIMEOUT" opencode run --pure --format json "$flag" "$val" \
      ${vopt[@]+"${vopt[@]}"} "$msg" </dev/null >"$out" 2>"${out}.err"
    return $?
  fi
  GIT_PAGER=cat GH_PAGER=cat PAGER=cat OPENCODE_PERMISSION="$PERM" \
    opencode run --pure --format json "$flag" "$val" ${vopt[@]+"${vopt[@]}"} "$msg" \
    </dev/null >"$out" 2>"${out}.err" &
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
# It exists because opencode's own answer for an unusable model id says nothing
# about the model. `opencode run --model does-not-exist/at-all "hi"` exits 1 with
# only:
#   {"type":"error","error":{"name":"UnknownError","data":{"message":"Unexpected
#    server error. Check server logs for details.","ref":"err_86eccad5"}}}
# — a generic server error, no mention of the id that caused it. That is the first
# thing anyone running this skill on a machine without the default provider hits,
# and without this check all four stages fail in unison for no stated reason.
#
# (An earlier version of this comment said the run exits 0. That was measured
# through a pipe, so the 0 was head's status, not opencode's. It exits 1, which
# is why the diagnosis below already fired despite the wrong rationale.)
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
# What the availability check concluded, which is also what separates a provider
# REFUSING a model from the caller naming one that does not exist:
#   present   every failed stage's model is in `opencode models` -> the provider
#             had it and still said no; switching provider or waiting is the fix
#   missing   at least one was not -> a configuration error wearing the same
#             generic UnknownError event; the fix is to name a model you have
#   unchecked the listing could not be obtained, so neither can be claimed
DIAG_VERDICT="unchecked"
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
  # `omniroute/opencode-go/glm-5.3-flash` this script builds is exactly what is listed.
  for m in "$@"; do
    [ -n "$m" ] || continue
    printf '%s\n' "$avail" | grep -qxF -- "$m" || missing="${missing} ${m}"
  done

  DIAG_VERDICT="present"
  if [ -z "$missing" ]; then
    log "diag  : every model involved is present in 'opencode models', so this was not model access."
    return 0
  fi

  DIAG_VERDICT="missing"
  log "diag  : NOT available in this OpenCode setup:${missing}"
  log "diag  : that alone accounts for an empty report — opencode reports only a generic server error for an unusable model id, never naming it."
  log "diag  : name models you do have via ${OC_MODEL_ENV_HINT}, or set OPENCODE_REVIEW_PROVIDER=<id> if they sit behind a router. Run 'opencode models' to see what is configured."
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

# json_error <events> -> the provider/runtime error message, or nothing.
#
# opencode emits `{"type":"error","error":{...}}` when a request fails outright —
# a bad model id, an auth failure, a provider refusing the call. That event is the
# whole diagnosis, and it is already in the stream: #30 had to go and read
# ~/.local/share/opencode/log to find "Monthly usage limit reached" because the
# default output format did not carry it anywhere the script could see.
#
# .error.data.message first, since that is where the provider's own words land;
# .error.name is the fallback when there is no message.
json_error() {
  if [ "$JSON_BIN" = "jq" ]; then
    jq -Rrn '[inputs | fromjson? | select(.type == "error")]
             | last
             | ((.error.data.message // .error.name // empty) | tostring)' <"$1" 2>/dev/null
  else
    python3 -c '
import json, sys
msg = ""
with open(sys.argv[1], "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "error":
            e = d.get("error") or {}
            msg = (e.get("data") or {}).get("message") or e.get("name") or ""
print(msg)
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
# Set by extract_report when the stage failed because the provider rejected the
# call rather than because the model produced nothing. Different cause, different
# remedy: retrying against the same provider cannot help.
STAGE_PROVIDER_ERROR=""
extract_report() {
  local in="$1" out="$2" stage="${3:-stage}" bytes stats texts tools reason errsz kept_events kept_err perr

  STAGE_STOP=""
  STAGE_PROVIDER_ERROR=""
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

  # A provider error outranks everything below: the model never got to run, so
  # counting its tool calls describes nothing. STAGE_PROVIDER_ERROR is what makes
  # the run short-circuit rather than launching the chair into the same wall.
  perr="$(json_error "$in")"
  if [ -n "$perr" ]; then
    STAGE_PROVIDER_ERROR="$perr"
    STAGE_STOP="provider error: ${perr}"
    log "WARN: ${stage}: ${STAGE_STOP}"
    log "WARN: ${stage}: events kept at ${kept_events:-<none>}${kept_err:+, stderr at $kept_err}"
    return 2
  fi

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

