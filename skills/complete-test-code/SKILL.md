---
name: complete-test-code
description: >-
  Use this skill whenever the user wants test code written, added, audited, or judged
  "good enough" — not merely run. Trigger when they: ask you to write or improve tests
  for a module (parser, retry/network logic, migration, auth/token, billing, state
  machine, library/SDK); worry that edge cases or "garbage input" keep slipping through
  release after release; ask what testing a component needs before shipping,
  open-sourcing, or tagging a version; want code made robust, reliable, or
  production-ready; report flaky, missing, or weak tests; or raise data corruption,
  crash/rollback/atomicity, concurrency, or fault-handling concerns. Also apply
  proactively right after non-trivial logic is implemented, to cover failure paths and
  boundaries even if "test" was never said. Brings SQLite-grade methods (fuzzing,
  property/differential/metamorphic testing, fault injection, mutation testing,
  coverage) but right-sizes rigor to the component's blast radius. Not for just running
  an existing suite or general debugging.
---

# Complete Test Code

Reliability is not achieved by careful coding alone — it is *earned by testing*. This
skill packages the testing methodology that makes [SQLite](https://sqlite.org/testing.html)
one of the most reliable pieces of software on Earth, and translates it into practices you
can apply to **any** project, in any language, at a cost proportional to what's at stake.

Two jobs:
- **Writing** new tests with the rigor the code actually deserves.
- **Auditing / hardening** an existing suite — finding the gaps that let bugs through.

The goal is never "more tests." It is *the right tests, where they matter, that would
actually notice if the code were wrong.*

---

## Core philosophy — adopt this mental model first

These seven ideas are the whole skill in compressed form. Everything else is mechanics.

1. **Test investment scales to blast radius, not to code size.** What determines how much
   rigor a component deserves is the *cost of being wrong* — how widely it's deployed, how
   hard a bad release is to recall, and whether it persists state that "remembers" mistakes.
   A near-zero test ratio on a load-bearing module is the real red flag; an imperfect
   coverage number on a throwaway script is not.

2. **The unhappy path is where reliability lives.** Correct behavior on good input on a
   healthy machine is the easy part. The hard, valuable work is sane behavior under bad
   input and system malfunction (OOM, I/O errors, crashes, timeouts, corruption).
   Error-handling and cleanup code is the *least-exercised and most dangerous* code in any
   program, because it only runs when something already went wrong. Deliberately injecting
   failures and feeding garbage is the single highest-leverage shift most suites can make.

3. **Independent, redundant verification beats one bigger suite.** A single suite encodes
   its authors' assumptions, so its blind spots are *correlated* — bugs those assumptions
   hide stay hidden no matter how large it grows. Diversity of method (unit + contract +
   property + differential + fuzz) and of authorship (tests written from the spec, by
   someone other than the implementer) produce *uncorrelated* failure modes. When two
   independent checks disagree, that disagreement is a high-signal bug.

4. **An oracle you didn't hand-write lets correctness testing scale.** The hardest bug
   class is the *wrong answer* — crash-free, leak-free, yet incorrect. You can't hand-author
   expected results at scale, so generate them: a reference implementation, a prior version,
   your own unoptimized slow path, an inverse function (round-trip), or a metamorphic
   relation (a transform that must not change the result). Each turns millions of generated
   inputs into checkable correctness tests for free.

5. **Coverage measures the test suite, not the product.** Running under a coverage tool "is
   not a test of the code, it is a test of the test — a meta-test." Coverage proves code
   *ran*, never that a test would *notice* if it were wrong. Two disciplines give it meaning:
   dense **assertions** turn silent corruption into loud, located failures; **mutation
   testing** breaks the code on purpose to confirm a test fails. Prefer *branch* coverage
   over statement coverage, and validate the *as-shipped* build separately.

6. **Make the safety net cheap, automatic, and tiered — or it won't run.** The bottleneck is
   whether checks actually execute. Run a fast subset on every commit (minutes) and the full
   expensive suite (fuzz/soak/anomaly/matrix) before release. Bake leak detection into every
   run with zero setup. Distill billion-case fuzz campaigns into a few-thousand-case corpus
   that replays on every `make test`. On-by-default and fast-enough-to-be-habitual is what
   makes a technique real.

7. **Automation catches anticipated failures; keep a human asking "is this really right?"**
   Every assertion encodes a failure someone foresaw. SQLite deliberately does *not* automate
   its ~200-item release checklist, because a human reviewing output at the top level catches
   anomalies no assertion was written for. The same skepticism applies to a green CI check or
   AI-generated "passing" code.

---

## START HERE — right-size the effort before writing anything

The fastest way to misuse this skill is to apply SQLite-grade rigor to a CRUD admin page,
or Essential-only rigor to a payments ledger. **Score the component** (not the whole repo)
on four axes, 1–5 each, and sum:

| Axis | Low (1) → High (5) |
|---|---|
| **Criticality / blast radius** | internal dev tool → public library, SDK, or shared platform service |
| **Complexity** | straight-line CRUD → parsers, state machines, concurrency, money/auth, planners |
| **Persistence ("remembers its mistakes?")** | ephemeral compute → writes durable / replicated / irrecoverable state |
| **Change frequency** | frozen → high churn by people who don't hold all its context |

| Sum | Tier | Apply |
|---|---|---|
| ~4–9 | **Essential** | Regression-test every bug; test malformed input & boundaries; branch coverage where free; fast suite; assertions; basic CI matrix; lightweight checklist. *Do not* fuzz, mutation-test, or chase 100% coverage — that's over-engineering here. |
| ~10–15 | **+ Advanced** | Add fault injection at dependency seams, leak detection, coverage-guided fuzzing on untrusted input, a differential oracle for wrong-answer-sensitive logic, sanitizer runs pre-release, mutation testing on the trickiest modules. |
| ~16–20 | **+ Extreme** | Reserve 100% branch/MC-DC, crash-state simulation, multiple independent harnesses, protocol-monitoring shims, continuous dedicated-core fuzzing for ubiquitous / persistent / irrecoverable software. Justify each explicitly. |

**Two overrides bump a component up regardless of the sum:**
- It's an **attack surface for untrusted input** → fuzzing + malformed-input tests become mandatory.
- It **persists or replicates state that can't easily be recalled** → integrity / atomicity / crash testing become mandatory.

**Score per module, not per repo.** A project can have an Extreme-tier storage layer and an
Essential-tier admin UI. When unsure between two tiers, the cheap Essential items are almost
never wrong; the expensive Extreme ones are wrong far more often than right for typical apps.

Full rubric, the "does it remember its mistakes?" heuristic, and worked examples (throwaway
script → internal service → public library → migration layer → auth/billing):
**`references/decision-framework.md`**.

---

## Workflow A — writing new tests

1. **Score the component** (rubric above) → pick the tier. Note the two overrides.
2. **Cover the unhappy path first.** For each external dependency (allocation, I/O, network,
   DB, sub-service), write a test that makes it fail and assert a *clean typed error* plus
   *consistent state after* — not just the return code. This is where the bugs are.
3. **Pin the boundaries.** For every limit (documented or implicit), test max-allowed
   (succeeds), first-over (rejected), and the n−1 / n / n+1 neighbors. See
   `references/fuzzing-and-malformed-input.md`.
4. **Build a generated oracle** for any wrong-answer-sensitive logic (round-trip, reference
   impl, slow path, metamorphic relation) so you're not limited to hand-written cases.
   See `references/oracles-and-differential.md`.
5. **Assert invariants in the code**, not only in tests — preconditions, postconditions,
   "can't happen" guards. Run tests with assertions *enabled*. See `references/dynamic-analysis.md`.
6. **Parameterize / table-drive** so a few definitions yield many cases. Keep tests
   co-located and the suite fast.
7. **Add the tier's Advanced/Extreme techniques** (fault-injection loops, fuzzing, mutation,
   crash simulation) by following the matching reference file.
8. **Verify the test would fail.** Before trusting a new test, confirm it goes red when the
   behavior is broken (red-green). A test that can't fail protects nothing.

## Workflow B — auditing / hardening an existing suite

1. **Score each major component** to know what rigor it *should* have, then measure the gap.
2. **Run the audit checklist** against the repo: copy `assets/test-rigor-checklist.md` in and
   answer each yes/no question. Each item names its tier, so you only owe the items at or
   below the component's tier.
3. **Look for the classic holes**, in priority order:
   - Bugs closed with no regression test (grep the tracker against the test diff history).
   - Failure paths never exercised — search for `catch`/`except`/`rescue`/error returns with
     no test that triggers them. (Coverage tools usually show these as the uncovered lines.)
   - Coverage reported as *line* not *branch*; or measured on a debug build that isn't shipped.
   - Tests that run code but assert nothing meaningful (mutation testing exposes these fast).
   - Leaks on error paths; missing teardown checks for handles/connections/threads/listeners.
   - One monolithic suite from one author/method (correlated blind spots).
4. **Prove the gap with mutation testing** on a critical module — surviving mutants are a
   ranked to-do list of missing assertions. See `references/coverage-and-mutation.md`.
5. **Report findings by tier and blast radius**, recommend the highest-yield fixes first, and
   (per philosophy #6) wire each fix into the *default* run so it can't be skipped.

---

## The three tiers at a glance

A compact index; the full what/why/how-to-start for each technique lives in the theme
references below. (E)=Essential (A)=Advanced (X)=Extreme.

- **Regression & process:** every bug → a permanent failing-then-passing test (E) · fast/full
  tiered runs (E) · CI matrix across OS/runtime/flags (E) · written release checklist + human
  review (E) · warning-clean multi-compiler builds (A). → `references/regression-and-process.md`
- **Fault injection & resilience:** inject failure at a seam and sweep it across every step (A)
  · transient vs persistent modes (A) · verify integrity + atomicity *after* failure (E) ·
  always-on leak detection (A) · compound failures (A) · crash/power-loss simulation (X) ·
  protocol-monitoring shim (X). → `references/fault-injection-and-resilience.md`
- **Fuzzing & malformed input:** boundary values both sides (E) · coverage-guided fuzzing on
  untrusted input under sanitizers (A) · reproducer corpus replayed every run (A) ·
  malformed-artifact tests (A) · structure-aware / multi-surface fuzzing (X) · continuous
  fuzzing (X). → `references/fuzzing-and-malformed-input.md`
- **Oracles & differential:** differential vs reference/prior/slow-path (A) · optimization
  on-vs-off identical-output diff (A) · metamorphic & round-trip checks (A) · separate
  correctness from effectiveness tests (A). → `references/oracles-and-differential.md`
- **Coverage & mutation:** branch over statement coverage (E) · per-component targets (E) ·
  keep & mark defensive code, don't delete for the number (A) · mutation testing (A) ·
  MC/DC on critical predicates (X) · coverage as meta-test, validate shipped build (X). →
  `references/coverage-and-mutation.md`
- **Dynamic analysis:** assertions as executable contracts (E) · memory/UB/race analyzers on a
  subset pre-release (A) · debug allocator layering (A) · lock-ownership asserts (A) ·
  config-matrix for impl-defined behavior (X). → `references/dynamic-analysis.md`
- **Ecosystem tooling:** concrete commands/libraries per language (JS/TS, Python, Go, Rust,
  Java, C/C++) for every technique above. → `references/ecosystem-pointers.md`

---

## Anti-patterns — how this goes wrong (read before cargo-culting)

The honest failure modes, several called out by the SQLite authors themselves:

- **The 590:1 ratio does not generalize.** SQLite itself says 100% MC/DC is "probably not
  cost effective for a typical application." What transfers is the *budgeting heuristic*
  (effort ∝ blast radius), never the magnitude. Don't quote the ratio as a target.
- **Coverage is not correctness.** 100% coverage with weak assertions catches almost nothing —
  the code ran, nothing checked the result. Never let a percentage become the goal; it
  pressures people to delete guards and write assertion-poor tests. Mutation testing is the
  antidote.
- **Fuzzing and 100% MC/DC pull against each other.** Defensive "can't-happen" guards create
  unreachable branches that wreck coverage — but deleting them to hit the number is exactly
  what lets a fuzzer reach an unexpected state. Keep defensive code on attack surfaces, *mark*
  unreachable branches so coverage stays honest, and treat normal-use robustness and attack
  robustness as separate goals with separate budgets.
- **Differential testing only works where outputs are *supposed* to agree.** Quarantine known
  divergences (dialect, locale, float formatting, undefined ordering) or you drown in false
  positives. Likewise, keep effectiveness tests (that count cache hits / queries / sorts) out
  of any "optimization off" run — they fail *by design* and erode trust in the suite.
- **Opt-in protection is no protection.** A leak detector you have to enable, or a fuzzer you
  run once, gets skipped and catches nothing. If a check isn't wired into the default run,
  assume it isn't protecting you.
- **Happy-path checks give false confidence.** The value is in checking cleanup *after* an
  injected failure, and in compound failures (a fault during recovery from a prior fault).
- **Static analysis isn't universally high-yield.** SQLite found few bugs with it — and
  introduced more bugs mechanically silencing warnings than the analyzer ever found. Use cheap
  compiler warnings and type checkers, but review a warning-"fix" as carefully as a feature
  change, and don't refactor subtle working logic to appease a false positive.
- **More of the same kind of test doesn't add coverage.** Tests written from the
  implementation by its author inherit its blind spots. Independence — a different author, the
  spec instead of the code, a different method/oracle — is what adds real protection.

---

## Reference files (hub-and-spoke — open what the task needs)

| File | Open it when |
|---|---|
| `references/decision-framework.md` | Choosing how much rigor a component warrants; worked examples per project type. |
| `references/fault-injection-and-resilience.md` | Testing failure paths: OOM/I/O/timeout injection, the failure-point sweep loop, post-failure integrity & atomicity, leak detection, crash/power-loss simulation, protocol shims. |
| `references/fuzzing-and-malformed-input.md` | Hardening any code that ingests untrusted or persisted input; boundary values; coverage-guided / structure-aware fuzzing; reproducer corpora. |
| `references/oracles-and-differential.md` | Catching wrong-answer bugs at scale: differential, metamorphic, round-trip, optimization on/off. |
| `references/coverage-and-mutation.md` | Coverage done right (branch, MC/DC, as-shipped) and proving tests actually assert (mutation testing); defensive-code annotation. |
| `references/dynamic-analysis.md` | Assertions, sanitizers (memory/UB/race), debug allocators, concurrency contracts, impl-defined-behavior matrices. |
| `references/regression-and-process.md` | Regression discipline, tiered runs, CI matrix, release checklists, human-in-the-loop, honest cost/benefit. |
| `references/ecosystem-pointers.md` | The concrete tool/command for a technique in a specific language. |
| `assets/test-rigor-checklist.md` | A copyable, tier-labeled yes/no audit checklist to drop into a project (Workflow B step 2). |

When you apply a non-obvious technique, briefly tell the user *why* it fits this component's
tier — the reasoning is the transferable part, and it keeps the team from later ripping out
rigor they don't understand.
