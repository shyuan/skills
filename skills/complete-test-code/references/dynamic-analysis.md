# Dynamic Analysis — making latent bugs loud, located, and deterministic

> *"Dynamic analysis refers to internal and external checks on the code which are performed
> while it is live and running."* The goal is to convert silent corruption — the bug that
> returns a plausible answer while quietly damaging state — into an **immediate, located,
> reproducible failure** that a test or fuzzer trips on the spot.

---

## 1. Assertions as executable contracts (E — the cheapest high-value habit)

The SQLite core contains **6754 `assert()` statements** checking preconditions, postconditions,
and loop invariants. An assertion is a boolean the code *assumes* is always true; if it's false
the program halts loudly at the exact point the assumption broke — instead of limping onward and
corrupting something three functions later.

- **Write assertions for what "can't" be false:** non-null after construction, index in range,
  invariant preserved across a loop, state machine in a legal state, sorted-ness, balance ≥ 0.
- **Run tests with assertions ENABLED.** This is the key operational detail. SQLite's asserts
  are *disabled in production* (they're in performance-critical paths — the engine runs ~3×
  slower with them on) via `NDEBUG`, and *enabled* only in test/debug builds (`SQLITE_DEBUG`).
  Mirror this: assertions on in CI and dev, compiled/stripped out in prod where the cost
  matters. (In many managed languages assertions are cheap enough to leave on — measure.)
- **Assertions multiply the value of fuzzing.** Most of what AFL found in SQLite were
  *assertion failures* — the assert turned an obscure bad state into a catchable crash. A fuzzer
  with no assertions to trip only finds hard crashes; a fuzzer running against assertion-dense
  code finds logic violations. The two techniques compound.
- Assertions are also the best executable documentation of a function's contract.

## 2. Memory / UB / race analyzers (A — run on a subset pre-release)

SQLite leans heavily on **Valgrind** — *"perhaps the most amazing and useful developer tool in
the world"* — which simulates execution and catches array overruns, reads of uninitialized
memory, stack overflows, and leaks, then drops you into a debugger at the fault. Because
simulation is slow (~smartphone speed on a workstation), SQLite runs only the fast "veryquick"
subset and the TH3 coverage tests under Valgrind before each release — **not** the full suite.

The transferable workflow: pick the analyzers your stack supports and run a **representative
subset** under them before release (full suite is usually too slow):
- **Memory errors / leaks:** Valgrind, AddressSanitizer (`-fsanitize=address`).
- **Undefined behavior:** UBSan (`-fsanitize=undefined`), MSan for uninitialized reads, Miri
  (Rust).
- **Data races:** ThreadSanitizer, `go test -race`.
See `references/ecosystem-pointers.md` for per-language equivalents — and note the analyzers are
**uneven across platforms**; map to your environment's real equivalent rather than assuming a
tool ports.

## 3. Layer a fast always-on checker under the slow deep one (A)

Valgrind is too slow to run constantly, so SQLite *also* has **memsys2** — a lightweight debug
allocator (enabled with `SQLITE_MEMDEBUG`) that checks for leaks, buffer overruns, uninitialized
reads, and use-after-free much faster than Valgrind, so it can run on *every* test. The pattern:

- **Fast, always-on** instrumentation in the default test run (debug allocator with guard
  bytes / poison-on-free / sentinel fill; assertions; leak tracking).
- **Slow, deep** analysis (Valgrind / full sanitizers) on a subset, periodically / pre-release.

The fast layer catches the common case every run; the slow layer catches the rest occasionally.
Two speeds beat one.

## 4. Make concurrency contracts executable (A)

Concurrency bugs are nondeterministic and brutal to debug, so assert the contract directly.
SQLite's mutex subsystem exposes `sqlite3_mutex_held()` / `sqlite3_mutex_notheld()`, used
*inside `assert()` statements* throughout the code to verify each mutex is held/released at
exactly the right moments. Generalize:
- Assert lock ownership at the entry of code that requires it ("caller must hold lock X").
- Assert thread affinity ("this object is only touched from its owner thread/loop").
- Add **concurrency stress tests** (many threads/processes hammering shared state — SQLite's
  `mptester`/`threadtest3`) and run the suite under a race detector.

## 5. Undefined / implementation-defined behavior, and the config matrix (X)

C makes it easy to write code that works today and breaks on another compiler/platform: signed
integer overflow (which does *not* reliably wrap), over-wide shifts, `memcpy` on overlapping
buffers, argument evaluation order, signedness of `char`. SQLite avoids it actively (e.g.
checking for overflow *before* adding integers, falling back to float) and *verifies* the
avoidance by running the suite under `-ftrapv`, `-fsanitize=undefined`, MSVC `/RTC1`, with
`-funsigned-char` **and** `-fsigned-char`, on **32- and 64-bit**, **big- and little-endian**,
across CPU architectures — plus tests deliberately crafted to provoke UB (e.g.
`SELECT -1*(-9223372036854775808);`).

Most languages have less raw UB, but the *spirit* transfers — non-determinism and
environment-dependence are everywhere:
- Locale, timezone, encoding (UTF-8 vs UTF-16), Unicode normalization.
- Floating-point rounding and formatting; integer overflow (silent in C/Go, panics in debug
  Rust, big-ints in Python/JS).
- Hash/map iteration order; default collation/sort order.
- Filesystem case-sensitivity; path separators; line endings.
- Word size, endianness where you (de)serialize binary.

(X) **Run your suite across the matrix you claim to support** — OS, runtime version, locale,
timezone, architecture — and flip the environment defaults to prove your code doesn't secretly
depend on them.

## Anti-patterns specific to this theme

- **Assertions stripped in the test build.** If `NDEBUG` (or equivalent) is set in CI, your
  6754 contracts check *nothing*. Verify assertions are live where you test.
- **Assertions left on in a hot production path** without measuring the cost — SQLite disables
  them in prod for a 3× reason. Know your tradeoff per language.
- **Running the whole suite under Valgrind/sanitizers** and then abandoning it because it's too
  slow. Run a representative subset; keep it sustainable so it actually runs.
- **Assuming a tool ports.** The best analyzers are Linux-centric; find your platform's real
  equivalent instead of assuming `valgrind` exists everywhere.

→ Per-language assertion idioms, sanitizer flags, and race detectors: `references/ecosystem-pointers.md`.
