# Oracles & Differential Testing — catching wrong-answer bugs at scale

> The hardest bug class is the **wrong answer**: crash-free, leak-free, UB-free, yet incorrect.
> Crash-only fuzzers and coverage tools never catch it — nothing checks the *result*. The only
> way to find wrong answers at scale is an **oracle**: an independent source of the expected
> result that you did *not* hand-write. SQLite's most powerful tests are all oracle-based.

The problem with hand-written `assertEqual(actual, expected)` tests is that you can only write
a few hundred of them, and you tend to write the cases you already understand — exactly the
ones least likely to be buggy. A generated oracle lets you check *millions* of inputs,
including ones no human would think to write.

---

## Five kinds of oracle (in rough order of accessibility)

### 1. Round-trip / inverse function (A — cheapest, start here)
If your operation has an inverse, their composition is identity:
- `decode(encode(x)) == x`, `deserialize(serialize(x)) == x`, `decompress(compress(x)) == x`,
  `parse(render(x)) == x`.
Generate random `x`, assert the round-trip. No second implementation needed — the inverse *is*
the oracle. Pair with property-based generation (`references/fuzzing-and-malformed-input.md §2`).

### 2. Metamorphic relations (A)
When you don't know the right answer but you know how the answer must *change* under a
transformation of the input:
- Adding a `WHERE` clause to a query never *increases* the row count.
- Sorting then reversing equals sorting descending.
- Re-encoding a JPEG at quality 100 twice changes it less than once at quality 50.
- Translating A→B→A should round-trip close to the original.
Assert `relate(f(x), f(transform(x)))`. Metamorphic testing is the workhorse for systems where
exact expected output is impractical to compute.

### 3. Your own unoptimized slow path (A — the optimization oracle)
This is SQLite's **disabled-optimization testing**, and it's broadly underused. SQLite can
disable selected query optimizations at runtime, then runs the **entire test suite twice** —
once with optimizations on, once off — and requires **identical output**. The slow,
obviously-correct path is the oracle for the fast, clever path.

Apply this anywhere you have a fast path and a slow path that must agree:
- A cache vs the uncached computation.
- A memoized / incremental result vs a full recompute.
- A SIMD/parallel path vs the scalar/sequential path.
- A hand-rolled optimization vs the naive reference.

**Build the switch in from day one:** add a flag/env var that disables the optimization, so the
fast path is differentially testable against the slow path forever. (E-cheap if designed in;
expensive to retrofit.)

### 4. A reference implementation (A/X)
SQLite's **SQL Logic Test** runs 7.2 million queries against SQLite *and* against PostgreSQL,
MySQL, SQL Server, and Oracle, verifying they all return the same answers. A second, independently
built implementation that's *supposed* to compute the same thing is a powerful oracle:
- A mature library you're replacing or reimplementing.
- A spec's reference implementation.
- A different language's stdlib for the same algorithm.

### 5. A prior version of your own code (A)
For behavior that's meant to be preserved across a refactor, the **previous release is the
oracle**. Capture inputs→outputs from the old version, replay against the new one, diff. This is
"golden master" / characterization testing — invaluable before refactoring legacy code with
thin test coverage.

---

## The meta-test trick: instrumented vs as-delivered (X)

SQLite measures coverage on an instrumented build, then **recompiles with production flags and
re-runs**, and **diffs the two outputs**. Any difference means either undefined/indeterminate
behavior in the code *or* a compiler bug — SQLite has hit real bugs in GCC, Clang, *and* MSVC
this way. Generalize: run your suite under two builds that *should* agree (debug vs release,
optimization levels, `-O0` vs `-O2`) and diff. Divergence is a latent portability/UB bug.

---

## Separate correctness tests from effectiveness tests (critical pitfall)

When you run "optimization on vs off" (oracle #3), most tests just check the answer and pass in
both modes — good. But some tests verify the optimization is *actually doing its job* by
counting work (cache hits, queries issued, sort operations, full-scan steps). **Those fail by
design when the optimization is off.** Mixing them into the "off" run produces false failures
that erode trust in the whole suite.

Partition your tests into two buckets:
- **Correctness tests** — assert the *result*; must pass with the optimization on **and** off.
- **Effectiveness tests** — assert the optimization *reduced work* (counters); run only with it
  on. Keep these clearly tagged and excluded from the differential run.

---

## The other essential pitfall: only compare where outputs are *supposed* to agree

Differential testing drowns you in false positives unless you scope it to the agreed-upon
subset. Independent implementations legitimately diverge on:
- Dialect / feature differences, undefined evaluation or row ordering.
- Locale, timezone, float formatting and rounding, NaN handling.
- Error message text, performance, non-deterministic IDs/timestamps.

Restrict comparisons to the contract both implementations actually promise, and **quarantine
known divergences** in an explicit allowlist (with a reason) rather than loosening the
comparison globally. A differential suite that cries wolf gets ignored.

→ Property/differential frameworks and golden-master tooling per language:
`references/ecosystem-pointers.md`.
