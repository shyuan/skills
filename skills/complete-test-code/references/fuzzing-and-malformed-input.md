# Fuzzing & Malformed Input — hardening every input surface

> *"Fuzz testing seeks to establish that [the software] responds correctly to invalid,
> out-of-range, or malformed inputs."* Any code that ingests untrusted or persisted input is an
> attack surface — and the **mandatory override** in the decision framework: an input boundary
> earns fuzzing + malformed-input tests regardless of its complexity score.

SQLite's progression is instructive: blind random fuzzing was ineffective until **AFL** (2014)
introduced *coverage-guided* fuzzing — instrument the program, keep inputs that reach new code
paths, mutate those further. Then **OSS-Fuzz** (continuous, on Google's infra), then
**dbsqlfuzz** (structure-aware, mutating *both* the SQL and the database file at once, ~1
billion mutations/day on ~16 dedicated cores), then **jfuzz** (corrupt JSONB blobs into the
JSON functions). Findings are distilled into **fuzzcheck** — a few thousand "interesting"
cases replayed on every `make test`.

---

## 1. Boundary value testing (E — start here, it's cheap)

Before any fuzzing infrastructure, pin every limit. For each documented or implicit limit
(max columns, max length, max integer, array bounds, buffer sizes, rate limits):

- Test the **maximum allowed** value → must succeed.
- Test the **first value over** → must return a clean error, not crash or silently truncate.
- Test the **neighbors**: n−1, n, n+1 around each boundary.
- SQLite uses `testcase()` macros to *enforce* that both sides of each boundary are exercised —
  see `references/coverage-and-mutation.md §4` for that obligation pattern.

Off-by-one and boundary errors are the highest-frequency bug class; this is the highest-ROI
item in the whole skill.

## 2. Property-based testing — the accessible on-ramp to fuzzing (A)

Most teams should reach for **property-based testing** before standalone fuzzers. Instead of
hand-writing inputs, you declare *properties that must hold for all inputs* and the framework
generates hundreds of cases and shrinks failures to a minimal reproducer:

- Round-trip: `decode(encode(x)) == x` for all `x`.
- Invariants: the output is always sorted / always valid / never negative.
- Metamorphic relations: `f(x)` and `f(transform(x))` relate predictably (see
  `references/oracles-and-differential.md`).

Property tests *are* a form of fuzzing with a built-in oracle, which is why they catch
wrong-answer bugs that crash-only fuzzers miss. Tools: `fast-check` (JS/TS), `hypothesis`
(Python), `gopter`/`rapid` (Go), `proptest`/`quickcheck` (Rust). See `references/ecosystem-pointers.md`.

## 3. Coverage-guided fuzzing (A — for untrusted/parsing surfaces)

Wire a coverage-guided fuzzer to every entry point that parses or deserializes input:

- Write a **fuzz target**: a function taking a byte buffer and feeding it to your parser.
- **Seed** it with a corpus of valid inputs so the fuzzer starts from reachable states.
- **Run it under sanitizers** (ASan/UBSan/MSan) so memory errors and UB surface as crashes,
  not silent corruption — fuzzing without sanitizers misses most of what it could find.
- Native: `libFuzzer`, `AFL++`, `cargo-fuzz`, `go test -fuzz`, `Atheris` (Python), `Jazzer`
  (JVM), `jsfuzz` (JS).

## 4. Structure-aware & multi-surface fuzzing (X)

Pure byte mutation rarely gets past a format/length check to reach deep logic. Two upgrades:

- **Structure-aware mutation:** a grammar or custom mutator that produces *mostly-valid but
  twisted* inputs (e.g. syntactically-correct-but-nonsensical SQL), so the fuzzer spends its
  time in the interesting logic, not bouncing off the front-door validator.
- **Multi-surface mutation:** mutate *several interacting inputs at once*. dbsqlfuzz's edge
  over earlier fuzzers is that it mutates the SQL **and** the database file simultaneously,
  reaching error states neither alone could. If your component takes config + data + a request,
  fuzz them together.

## 5. Malformed-artifact / corruption tests (A)

Distinct from fuzzing the *input API*: take a **valid persisted artifact** (file, blob,
serialized message, on-disk database) and corrupt it externally, then read it back. SQLite
classifies the bytes it flips:

- **Bytes in the middle of data** → content changes but structure stays valid (tests semantic
  handling).
- **Unused/padding bytes** → should have no effect (tests you don't over-read).
- **Structural / header bytes** → the interesting case: the reader must detect the corruption
  and report a clean typed error (SQLite's `SQLITE_CORRUPT`) **without buffer overruns, null
  derefs, or other unwholesome actions**.

**Treat your own serialized / on-disk formats as untrusted on read.** The file you wrote last
release may be read by code that has since changed, or may have been corrupted on disk, or
crafted by an attacker. Internal binary formats (like SQLite's JSONB) deserve their own
targeted fuzzer feeding the consumer.

## 6. Capture findings into a fast replay corpus (A)

A fuzzer that runs once finds bugs once. SQLite's **fuzzcheck** keeps every behavior-distinct
input the fuzzers ever found (the actual bugs *plus* merely-interesting cases) as data files,
and replays a few thousand of them deterministically on **every** `make test`. This converts an
expensive, nondeterministic campaign into a cheap permanent regression net.

- Every crash/repro a fuzzer finds becomes a checked-in corpus file.
- The corpus replays in the fast suite; the live fuzzer keeps running separately.
- This is regression discipline (`references/regression-and-process.md`) applied to fuzzing.

## 7. Continuous fuzzing (X — ubiquitous/persistent software)

For high-blast-radius targets, fuzzing is not a one-time pass — it runs continuously:
- Enroll in **OSS-Fuzz** (free for open source) or run fuzzers on CI nightly / dedicated cores.
- Fuzz the **latest commits**, auto-notify the offending commit's author, auto-confirm fixes.
- **Many independent fuzzers** beat one — SQLite credits having several independently-developed
  fuzzers (and external researchers) for catching obscure issues; "given enough eyeballs, all
  bugs are shallow." Act on every external fuzzer report.

---

## The fuzzing ↔ coverage tension (read this)

Documented honestly by SQLite: **code tested to 100% MC/DC tends to be *more* vulnerable to
fuzzing, and fuzz-robust code tends to have *less* than 100% MC/DC.** Why: MC/DC discourages
defensive "can't-happen" code (it creates unreachable branches that wreck coverage) — but that
same defensive code is what stops a fuzzer from exploiting an unexpected state. MC/DC builds
code robust in *normal* use; fuzzing builds code robust against *attack*. You want both, and
doing both at once is genuinely hard.

Resolution: keep defensive code on attack surfaces, **mark** unreachable branches so coverage
stays honest (`references/coverage-and-mutation.md §2`), and budget normal-use robustness and
attack robustness as **separate goals**. Note the synergy too: *because* SQLite maintains 100%
MC/DC, when a fuzzer does find a problem it can be fixed fast with low risk of regression.

## Anti-patterns specific to this theme

- **Fuzzing without sanitizers** — most memory/UB bugs become silent instead of crashes; you
  lose most of the value.
- **No seed corpus** — the fuzzer wastes its budget rediscovering your input format.
- **Treating your own format as trusted on read** — last release's writer is not this release's
  reader; corruption and version skew are real.
- **One-shot fuzzing** — a fuzzer you ran once protects nothing; capture repros into the replay
  corpus and/or run continuously.

→ Per-language fuzzers, property frameworks, and sanitizer flags: `references/ecosystem-pointers.md`.
