# Coverage Done Right & Mutation Testing

> *"Running [the code] with gcov is not a test of [the code] — it is a test of the test suite.
> The gcov run is a test of the test, a meta-test."* This single reframing is the most
> important thing to understand about coverage. Coverage tells you code **ran**; it never tells
> you a test would **notice** if that code were wrong. Two disciplines close the gap:
> assertions (`references/dynamic-analysis.md`) and **mutation testing** (below).

---

## 1. Branch coverage, not statement coverage (E)

The metric most people cite ("XX% coverage") is **statement/line** coverage: what fraction of
lines ran at least once. It is weak. **Branch (decision)** coverage is stricter: it asks
whether each branch went *both* directions. SQLite's own example:

```c
if( a>b && c!=25 ){ d++; }
```

A *single* test where `a>b` is false gives **100% statement coverage** of this line — the line
ran. But to get **100% branch coverage** you need three cases:
- `a<=b`
- `a>b && c==25`
- `a>b && c!=25`

100% branch coverage implies 100% statement coverage; the converse is false. **Always report
which kind you mean**, and prefer branch coverage where your tooling supports it (`gcov -b`,
`nyc`/Istanbul branch metrics, `coverage.py --branch`, etc. — see
`references/ecosystem-pointers.md`).

## 2. Defensive code vs the coverage number — keep it, mark it (A)

Well-written code has defensive conditionals that are *always* true or *always* false in
practice ("this can't happen, but if it does…"). They create branches you can never cover —
so the dilemma: delete the guard to hit 100%, or keep it and miss the number?

**Keep it.** Deleting defensive code to win a coverage point is exactly what lets a fuzzer
reach the "impossible" state (`references/fuzzing-and-malformed-input.md`, the tension section).
SQLite's solution is the `ALWAYS()` / `NEVER()` markers:

```c
/* Production: pass-through */
#define ALWAYS(X)  (X)
#define NEVER(X)   (X)

/* Testing: assert the expected truth value — catches wrong design assumptions loudly */
#define ALWAYS(X)  ((X)?1:(assert(0),0))
#define NEVER(X)   ((X)?(assert(0),1):0)

/* Coverage build: constants, so no branch instruction is generated → excluded from coverage */
#define ALWAYS(X)  (1)
#define NEVER(X)   (0)
```

The marker does triple duty: it documents "this is defensive," it **asserts at runtime in test
builds** that the impossible really is impossible, and it **excludes the branch from coverage**
so your number stays honest. Generalize with whatever your language offers: an `assertUnreachable()`
/ `assert false` helper plus your coverage tool's exclusion pragma
(`/* istanbul ignore next */`, `# pragma: no cover`, `#[cfg(...)]`, etc.).

## 3. MC/DC — for genuinely critical predicates only (X)

**Modified Condition/Decision Coverage** is stricter than branch coverage. It requires:
- every decision takes every outcome,
- every *condition* in a decision takes every outcome, **and**
- each condition is shown to **independently** affect the decision's outcome.

In C, where `&&` and `||` short-circuit, MC/DC and branch coverage nearly coincide — the gap is
**boolean-vector / bitmask tests**, where you can hit both branches without proving each bit
matters. MC/DC is the standard for avionics (DO-178B) and is *laborious*; SQLite calls
maintaining it "probably not cost effective for a typical application." Reserve it for the
handful of intricate, safety-relevant predicates where a missed condition is catastrophic.

## 4. Force coverage of boundaries & bitmask cases — `testcase()` obligations (A)

SQLite's `testcase()` macro marks a condition for which it wants tests that make it *both* true
and false. It's a no-op in production but, in a coverage build, emits code the analysis checks
for both outcomes — so the author's knowledge of a tricky boundary becomes a **checkable
obligation**:

```c
testcase( a==b );      /* demand a test where these are equal */
testcase( a==b+1 );    /* and one just past the boundary */
if( a>b && c!=25 ){ d++; }

/* and for bitmasks — prove every bit actually affects the outcome: */
testcase( mask & SQLITE_OPEN_MAIN_DB );
testcase( mask & SQLITE_OPEN_TEMP_DB );
if( (mask & (SQLITE_OPEN_MAIN_DB|SQLITE_OPEN_TEMP_DB))!=0 ){ ... }
```

(SQLite has 1184 of these.) Generalize: when you write a tricky boundary or a multi-flag
condition, leave an explicit obligation — a focused boundary test, or a comment+test pair — so
a future change that stops exercising both sides is caught. This is how SQLite also reaches
100% MC/DC on bit-vector decisions.

## 5. Mutation testing — proving the tests actually assert (A)

Coverage shows a branch *executed*; mutation testing shows the branch **matters and a test
notices**. The method: programmatically mutate the code (flip a branch to always-true /
always-false, change `+` to `-`, delete a statement), rebuild, and **require the test suite to
fail**. A **surviving mutant** (the code changed but all tests still passed) means either dead
code or — far more often — a test that runs the code without asserting on its effect.

> Surviving mutants are a *ranked to-do list of missing assertions.* This is the fastest way to
> find the assertion-poor tests that inflate a coverage number while protecting nothing.

Run it on **critical modules** (it's compute-heavy; don't run it repo-wide every commit). Tools:
`Stryker` (JS/TS), `mutmut` / `cosmic-ray` (Python), `go-mutesting` / `gremlins` (Go),
`cargo-mutants` (Rust), `PIT` (JVM). See `references/ecosystem-pointers.md`.

**The optimization caveat (false positives):** some branches make code *faster* without
changing output, so mutating them doesn't fail any test — a false positive. SQLite annotates
these with `/*OPTIMIZATION-IF-TRUE*/` / `/*OPTIMIZATION-IF-FALSE*/` so the mutation script skips
them. Its example: a string-hash function whose loop-guard mutated to always-jump makes the hash
always return 0 — still a *valid* hash (correct answers, just slower), so no test fails. Exclude
performance-only branches from correctness mutation runs.

---

## 6. Coverage as a meta-test, applied (X)

Putting it together, SQLite's coverage workflow — and the general lesson:
1. Measure coverage on the **instrumented** build (e.g. `-fprofile-arcs -ftest-coverage`).
   Treat the result as a property of the *test suite*, and gate on it.
2. **Recompile with production flags** (no instrumentation — it changes generated code) and
   re-run. *This* is the real test of the software.
3. **Diff the two outputs.** Any difference = UB in your code or a compiler bug. (See
   `references/oracles-and-differential.md`.)
4. Set **per-component targets by risk** (`references/decision-framework.md`), not one blanket
   org-wide percentage. A blanket number over-tests disposable code and under-tests the
   dangerous module hiding behind the average.

## Anti-patterns specific to this theme

- **Coverage as the goal.** It pressures people to delete guards and write assertion-free tests
  that touch lines without checking results. Mutation testing is the antidote; assertions are
  the prevention.
- **Reporting line coverage as if it were branch coverage.** State which you mean.
- **A green number on a build you don't ship.** Instrumented/debug builds generate different
  code; reconcile with the as-delivered artifact.
- **Mutation testing the whole repo every commit.** It's expensive — target critical modules
  and run it periodically, not on the hot path.
