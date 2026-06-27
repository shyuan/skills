# Regression Discipline & Test Process

> The techniques in the other references find bugs. This file is about the *process* that makes
> the safety net cumulative, habitual, and trustworthy — and about spending effort honestly.

---

## 1. Every bug becomes a permanent regression test (E — highest ROI in the skill)

SQLite's rule: *"Whenever a bug is reported, that bug is not considered fixed until new test
cases that would exhibit the bug have been added."* Thousands of such tests have accumulated,
and they ensure a fixed bug is **never silently reintroduced**.

The discipline, concretely:
- **Red-green:** the new test must **fail before the fix and pass after**. A test written after
  the fix that you never saw fail might be asserting the wrong thing — confirm it goes red.
- **No bug closed without its test.** In review, reject a fix-only PR for load-bearing code.
- **Tag the test with the issue number** for traceability (`test_issue_1234_*`).
- **Store reproducer inputs as data files** the suite replays, so the corpus grows cheaply
  (this is exactly SQLite's `fuzzcheck` model for fuzzer finds — see
  `references/fuzzing-and-malformed-input.md §6`).
- **A never-shrinking corpus.** When a refactor breaks an old regression test, **investigate** —
  do not "update it to pass." That test encodes a real past failure; its breaking is a signal.
- **The regression suite is what makes fearless refactoring possible.** SQLite credits full
  coverage + regression discipline for enabling the aggressive changes it ships safely.

> The growing regression corpus becomes a precise map of every mistake the team has made — and
> the net that lets you change code without re-making them.

## 2. Tiered runs — fast feedback now, deep checks before release (E)

The bottleneck is whether checks actually run, so match cost to cadence. SQLite runs:
- A fast **"veryquick"** subset (~304K cases, a few minutes) before every check-in — *"most
  tests other than the anomaly, fuzz, and soak tests… sufficient to catch most errors."*
- The **full suite** (anomaly, fuzz, soak, multi-platform, multi-config) before each release —
  hours of work, including a **soak test** of ~248 million cases.

Your version:
- **Pre-commit / PR tier (minutes):** unit + fast integration + the fuzz/repro replay corpus.
  Path of least resistance — if it's slow, people skip or game it.
- **Pre-release / nightly tier (slow):** full integration, fuzzing campaigns, sanitizer runs,
  mutation testing, the full platform/config matrix, performance regression, soak/stress.

## 3. Keep the suite cheap to grow (E)

- **Co-locate** tests with the code so they're maintained together and easy to find.
- **Parameterize / table-drive.** SQLite's tests are heavily parameterized — 50K definitions
  expand to millions of instances. A few definitions × many parameter rows = wide coverage with
  little code. Prefer one table-driven test over twenty copy-pasted ones.
- Treat **test code as a first-class deliverable** — same review bar as production code.

## 4. The platform / configuration matrix (E)

SQLite runs *"on multiple platforms and under multiple compile-time configurations before each
release."* Test the matrix you *claim to support*, not just your laptop:
- OS (Linux/macOS/Windows), runtime/language versions, architecture (incl. ARM), endianness
  where relevant.
- **Key feature flags / build configs** — every supported combination is a separate product.
- (X) Run the **full suite under multiple build definitions** (assert build / coverage build /
  release build) and require identical results — divergence reveals UB or build-config bugs.

## 5. The release checklist — and keeping a human in the loop (E)

SQLite coordinates each release with an **~200-item checklist**, explicitly inspired by *The
Checklist Manifesto*. The deliberate, counter-intuitive choices:
- **It is NOT automated.** *"We find that it is important to keep a human in the loop. Sometimes
  problems are found while running a checklist item even though the test itself passed. It is
  important to have a human reviewing the test output at the highest level, and constantly
  asking 'Is this really right?'"*
- **It continuously evolves** — *"As new problems or potential problems are discovered, new
  checklist items are added."* This is regression discipline at the **process** level: every
  escaped problem becomes a permanent new checklist item, not just a code test.

Your version: a short, version-controlled `RELEASE.md` / deploy checklist that grows after every
incident. Automation catches the failures someone already anticipated and encoded; the human
asking *"is this really right?"* is your only defense against the unknown-unknowns — and against
trusting a green CI check, or AI-generated "passing" code, that's confidently wrong.

## 6. Static analysis & warnings — useful, but honestly bounded (A)

SQLite compiles warning-clean under `-Wall -Wextra` on GCC, Clang, and MSVC, and clean under the
Clang static analyzer. But it reports a striking, honest result:

> *"Static analysis has not been helpful in finding bugs in SQLite… More bugs have been
> introduced into SQLite while trying to get it to compile without warnings than have been found
> by static analysis."*

The transferable lesson is **not** "skip static analysis" — cheap compiler warnings, linters,
and type checkers are worth keeping clean. It's about *expectations and care*:
- **Do** enable strict compiler warnings, linters, and (especially) static type checking — they
  are cheap and catch a real class of mistakes at the door.
- **Don't** assume a heavyweight third-party analyzer will find your real bugs — for a
  well-tested codebase its yield is low and its false-positive rate can be high.
- **Review a warning-"fix" as carefully as a feature change.** Mechanically refactoring subtle,
  working logic to silence a false positive is a leading way to *introduce* a bug. Treat
  third-party analyzer noise as low priority and take solace in your dynamic testing instead.

## 7. Document the testing regime (cross-tier)

SQLite's testing page *itself* is a trust artifact — it states the coverage kind, test counts,
the test-to-code ratio, and the failure classes simulated, which is why people trust SQLite in
mission-critical systems. For any serious component, write a short `TESTING.md` stating:
- which tier each major module is at and why (`references/decision-framework.md`),
- what kind of coverage you measure (branch vs line) and the target,
- which failure classes you simulate (OOM, I/O, crash, malformed input, …),
- how to run the fast tier vs the full tier.

This makes the regime auditable, onboards contributors, and stops the next person from ripping
out rigor they don't understand.

## Anti-patterns specific to this theme

- **Fixing a bug without a failing-first regression test** — it will come back.
- **A slow pre-commit tier** — it gets skipped or gamed; keep the fast tier fast.
- **"Updating" a broken old regression test to pass** instead of investigating why it broke.
- **Over-automating the final gate** — removing the human who asks "is this really right?"
  removes your defense against unknown-unknowns.
- **Cargo-culting volume** — the 590:1 ratio is not a target; effort scales with blast radius
  (`references/decision-framework.md`), and you should spend it where bugs are *actually* caught.
