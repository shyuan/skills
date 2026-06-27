# Test Rigor Checklist

A copyable audit checklist distilled from SQLite's testing methodology, generalized to any
project. **Drop this file into a repo** (e.g. `docs/test-rigor-checklist.md`) and work through
it for each major component.

**How to use it**
1. Identify the component and its **tier** using the decision framework (score Criticality,
   Complexity, Persistence, Change-frequency → Essential / Advanced / Extreme). Note the two
   overrides: *untrusted-input surface* forces the fuzzing items; *persists hard-to-recall
   state* forces the integrity/atomicity/crash items — regardless of score.
2. You only owe the items **at or below the component's tier.** An Essential-tier admin UI is
   not expected to pass the Advanced/Extreme items; a payments ledger is.
3. Answer each as **Yes / No / N-A** with a note. Every **No** at or below the tier is a gap —
   prioritize fixes by blast radius.

Legend: **(E)** Essential · **(A)** Advanced · **(X)** Extreme · **(★)** mandatory if an
override applies.

---

## Regression & process
- [ ] **(E)** Every closed bug has a regression test that **failed before the fix and passes
  after**, tagged with its issue number.
- [ ] **(E)** There is a **fast pre-commit/PR tier** (minutes) and a fuller **pre-release tier**
  (slow / fuzz / soak / matrix).
- [ ] **(E)** The primary suite is **co-located** with the code and uses **parameterized /
  table-driven** tests instead of copy-pasted cases.
- [ ] **(E)** CI runs the **test matrix** across supported OS / runtime versions / key feature
  flags before release.
- [ ] **(E)** There is a **written, version-controlled release/deploy checklist** that grows
  after every incident.
- [ ] **(E)** At release, a **human reviews high-level output** asking "is this really right?"
  rather than trusting only a green check.
- [ ] **(A)** The build/lint is **warning-clean at strict settings under more than one
  compiler/linter** (and warning-fixes are reviewed as carefully as feature changes).
- [ ] **(cross)** The testing regime is **documented** with honest headline metrics (coverage
  kind, failure classes simulated, per-module tier).

## The unhappy path — fault injection & resilience
- [ ] **(E/★)** Tests feed **malformed / invalid / garbage input** and assert a **clean typed
  error**, not a crash, hang, or null-deref.
- [ ] **(E/★)** After an injected/expected failure, tests assert **durable state is consistent**
  and the operation was **atomic (all-or-nothing)** — not just the return code.
- [ ] **(A)** Tests can **inject failures** (resource exhaustion, I/O error, dependency
  timeout/outage) **at a seam**, and the failure is **swept across every step** of multi-step
  operations (the failure-point advancement loop).
- [ ] **(A)** Failure scenarios run in **both transient** (fail-once-then-recover) **and
  persistent** (keep-failing) modes.
- [ ] **(A)** Every test run **automatically detects resource leaks** (memory **and** file
  descriptors / threads / connections / locks / listeners), **including on error paths**, with
  zero setup.
- [ ] **(A)** **Compound failures** are tested (a second fault injected during recovery from a
  first).
- [ ] **(X/★)** For durability-critical systems, crash recovery is tested by **modeling the
  post-crash on-disk state** (including reordered / torn / dropped unsynced writes) and
  verifying all-or-nothing recovery.
- [ ] **(X)** For ordering/durability-critical protocols, a **monitoring shim asserts the
  ordering invariant on every operation** (e.g. journal-before-data, persist-before-publish).

## Fuzzing & malformed input
- [ ] **(E)** For every limit, there is a test for the **max-allowed** value (succeeds) **and
  the first-over** value (rejected), plus **n−1 / n / n+1** neighbors.
- [ ] **(A/★)** Every **untrusted / persisted input surface** is covered by a **coverage-guided
  fuzzer** (or property-based test), **seeded** and **run under sanitizers**.
- [ ] **(A/★)** **Corrupted versions of valid persisted artifacts** (especially structural /
  header bytes) are tested under sanitizers for clean handling.
- [ ] **(A)** Fuzz/crash **reproducers are captured into a fast deterministic corpus** replayed
  on every test run.
- [ ] **(X)** **Structure-aware / multi-surface fuzzing** mutates several interacting inputs at
  once; internal binary/serialized formats have a targeted fuzzer feeding their consumer.
- [ ] **(X)** **Continuous fuzzing** runs (CI nightly / dedicated cores / OSS-Fuzz) with a
  growing corpus.

## Oracles & differential testing (wrong-answer bugs)
- [ ] **(A)** Wrong-answer-sensitive logic has a **differential or metamorphic oracle**
  (reference impl, prior version, own slow path, round-trip, or invariant-preserving transform).
- [ ] **(A)** If the code has a **fast path / optimization / cache**, there is a **runtime
  switch to disable it** and a run that **diffs on-vs-off for identical output**, with
  **effectiveness (counter-based) tests kept separate**.
- [ ] **(A)** Differential comparisons are **scoped to the agreed-upon subset**, with known
  divergences **quarantined** in an explicit allowlist (no false-positive flood).

## Coverage & mutation
- [ ] **(E)** The coverage report measures **branch/decision coverage**, and it's clear it is
  branch, not line.
- [ ] **(E)** Coverage / rigor targets are set **per component by blast radius** — most effort
  on load-bearing modules, least on disposable code (not one blanket org-wide percentage).
- [ ] **(A)** Defensive "can't-happen" code is **kept and explicitly marked** (and
  coverage-excluded) rather than deleted to hit a number; it **asserts** in test builds.
- [ ] **(A)** **Mutation testing** has been run on critical modules, with surviving mutants
  triaged as **missing assertions** (performance-only branches excluded).
- [ ] **(X)** For the most critical predicates, each sub-condition is shown to **independently
  change the outcome (MC/DC)**.
- [ ] **(X)** Branch coverage is measured on an instrumented build but **validated by re-running
  and diffing the as-shipped artifact**.

## Dynamic analysis
- [ ] **(E)** The code **asserts preconditions / postconditions / invariants**, and assertions
  are **enabled during test runs**.
- [ ] **(A)** The suite (or a representative subset) is **run under a memory / UB / race
  analyzer** before release.
- [ ] **(A)** A **fast always-on checker** (debug allocator / assertions) runs every test, with
  the **slow deep analyzer** run periodically/pre-release.
- [ ] **(A)** Concurrency contracts are **executable** (lock-ownership / thread-affinity
  assertions), and there are **concurrency stress tests** + a **performance-regression
  benchmark**.
- [ ] **(X)** The suite runs across **word size / endianness / architecture** and **flipped
  implementation-defined / environment defaults** (locale, timezone, encoding, signedness)
  where portability is claimed.

---

### Scoring your audit
Count the **No**s at or below each component's tier. There is no single pass/fail number — the
output is a **prioritized gap list**, sorted by the blast radius of the component each gap sits
in. Fix the Essential gaps on high-blast-radius components first; they are almost always the
highest-yield work. Wire every fix into the **default** test run so it can't be skipped — an
opt-in check is no check at all.
