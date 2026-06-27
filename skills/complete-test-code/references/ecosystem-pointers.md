# Ecosystem Pointers — the concrete tool per language

The techniques in this skill are language-agnostic; the tooling is not. Use this file to
translate a technique into a command/library for the stack at hand. Tools change — verify the
current recommendation for your version, and treat absences as "find the local equivalent,"
not "skip the technique."

A recurring reminder: **garbage-collected languages still leak** connections, threads/goroutines,
file handles, timers, and event listeners — leak detection (`references/fault-injection-and-resilience.md §4`)
is not a C-only concern.

---

## JavaScript / TypeScript

| Technique | Tool / approach |
|---|---|
| Test runner | Vitest, Jest, `node:test` |
| Branch coverage | `c8` / Istanbul (`nyc`) — enable `branches` thresholds, not just `lines` |
| Property-based / fuzz-with-oracle | `fast-check` (excellent shrinking; supports model-based & metamorphic) |
| Coverage-guided fuzzing | `jsfuzz`, `@jazzer.js/core` (libFuzzer-based) |
| Mutation testing | **Stryker** (`@stryker-mutator`) |
| Fault injection — HTTP/network | `msw`, `nock` (force timeouts, 5xx, connection resets) |
| Fault injection — time/clock | `@sinonjs/fake-timers`, `vi.useFakeTimers()` |
| Fault injection — filesystem | `mock-fs`, `memfs` |
| Leak detection | `--detectOpenHandles` (Jest), `why-is-node-running`, `wtfnode`, `leakage`/`weak-napi` for heap |
| Race / async ordering | deterministic scheduling via fake timers; `p-limit`-style controlled concurrency in tests |
| Coverage exclusion for defensive code | `/* istanbul ignore next */`, `/* c8 ignore next */` |
| Golden master / snapshot | built-in `toMatchSnapshot` (use sparingly; review diffs) |
| Static / type | `tsc --strict`, ESLint at strict settings, `typescript-eslint` |

## Python

| Technique | Tool / approach |
|---|---|
| Test runner | `pytest` |
| Branch coverage | `coverage.py --branch` / `pytest-cov --cov-branch` |
| Property-based / metamorphic | **Hypothesis** (stateful/rule-based machines, `@example`, shrinking) |
| Coverage-guided fuzzing | **Atheris** (libFuzzer for CPython), runs under ASan/UBSan |
| Mutation testing | `mutmut`, `cosmic-ray` |
| Fault injection — deps | `unittest.mock` / `monkeypatch` to raise on the seam; `responses`/`respx` for HTTP |
| Fault injection — filesystem | `pyfakefs` |
| Fault injection — time | `freezegun`, `time-machine` |
| Leak detection | `tracemalloc`, `pytest` fixtures asserting open fds/threads, `objgraph` |
| UB-ish / memory (C extensions) | run under Valgrind or compile extensions with ASan/UBSan |
| Coverage exclusion | `# pragma: no cover`, and `assert False, "unreachable"` for defensive code |
| Static / type | `mypy --strict` / `pyright`, `ruff`/`flake8` |

## Go

| Technique | Tool / approach |
|---|---|
| Test runner | `go test`, table-driven tests (idiomatic parameterization) |
| Coverage | `go test -cover` / `-coverprofile`; note Go reports statement coverage — reason about branches manually or via `-covermode=count` |
| Native fuzzing | `go test -fuzz` (built-in, corpus-persisting, coverage-guided) |
| Property-based | `gopter`, `pgregory.net/rapid` |
| Mutation testing | `go-mutesting`, `gremlins` |
| Race detection | **`go test -race`** (run it in CI; cheap and high-value) |
| Fault injection — deps | interface seams + hand-written failing fakes; `httptest` for HTTP failures |
| Goroutine-leak detection | `go.uber.org/goleak` (assert no leaked goroutines per test) |
| Fault injection — time | inject a `Clock` interface; `clockwork`, `benbjohnson/clock` |
| Coverage exclusion | structure code so defensive branches are isolated; `//go:` build tags for test-only checks |
| Static | `go vet`, `staticcheck`, `golangci-lint` |

## Rust

| Technique | Tool / approach |
|---|---|
| Test runner | built-in `cargo test`, `cargo nextest` |
| Coverage (incl. branch-ish) | `cargo llvm-cov` (region/line); `grcov` |
| Coverage-guided fuzzing | **`cargo-fuzz`** (libFuzzer), `afl.rs` |
| Property-based | **`proptest`**, `quickcheck` |
| Mutation testing | **`cargo-mutants`** |
| UB / memory | **Miri** (detects UB, data races, leaks in `unsafe`); ASan/UBSan/TSan via `-Zsanitizer` |
| Fault injection | trait seams + mock impls; `fail` crate (fault-injection points); `mockall` |
| Leak / resource | Miri leak checks; RAII makes most resource leaks structurally hard, but watch tasks/handles |
| Assertions / contracts | `assert!`, `debug_assert!` (debug-only, like SQLite's NDEBUG split), `unreachable!()` |
| Static | `cargo clippy` at `-D warnings` (review fixes carefully) |

## JVM (Java / Kotlin)

| Technique | Tool / approach |
|---|---|
| Test runner | JUnit 5, parameterized tests (`@ParameterizedTest`) |
| Branch coverage | **JaCoCo** (reports branch/instruction coverage) |
| Coverage-guided fuzzing | **Jazzer** (libFuzzer for JVM), JQF + Zest |
| Property-based | jqwik, junit-quickcheck |
| Mutation testing | **PIT (pitest)** — the reference-quality mutation tool |
| Fault injection | Mockito to throw on seams; WireMock for HTTP faults; Toxiproxy for network chaos |
| Leak / resource | assert closed resources in `@AfterEach`; heap-leak via JFR/async-profiler |
| Concurrency | `jcstress` (concurrency stress harness), tempus-fugit |
| Static | Error Prone, SpotBugs, NullAway |

## C / C++ (closest to the source material)

| Technique | Tool / approach |
|---|---|
| Branch coverage | **`gcov -b`** (+ `lcov`/`gcovr` for readable reports); `llvm-cov` |
| Coverage-guided fuzzing | **libFuzzer**, **AFL++**; enroll in **OSS-Fuzz** for OSS |
| Mutation testing | `mull`, `dextool mutate` |
| Memory / leaks | **Valgrind**, **AddressSanitizer** (`-fsanitize=address`) |
| Undefined behavior | **UBSan** (`-fsanitize=undefined`), `-ftrapv`, MSVC `/RTC1`, MSan (uninit reads) |
| Data races | **ThreadSanitizer** (`-fsanitize=thread`) |
| Assertions | `assert()` (gated by `NDEBUG`); a custom `ALWAYS()/NEVER()` pair for defensive code (see `references/coverage-and-mutation.md §2`) |
| Fault injection | pluggable allocator (`SQLITE_CONFIG_MALLOC`-style hook); a VFS/IO-shim interface; `LD_PRELOAD` malloc shims |
| Config matrix | `-funsigned-char`/`-fsigned-char`, 32/64-bit, big/little-endian, multiple compilers (GCC/Clang/MSVC) |
| Static | `-Wall -Wextra` clean, `clang-tidy`, `scan-build` (expect false positives) |

---

## Cross-language quick map (technique → category to search for)

If your language isn't above, search its ecosystem for these categories:
- **Branch coverage tool** (insist on *branch/decision*, not just line).
- **Property-based testing library** (the accessible front-door to fuzzing-with-an-oracle).
- **Coverage-guided fuzzer** (often a libFuzzer binding).
- **Mutation testing tool** (to validate the suite actually asserts).
- **Mocking / seam library + an HTTP-fault tool + a fake clock** (for fault injection).
- **Open-handle / leak detector** (yes, even with a GC).
- **A race detector or concurrency-stress harness** (if you have concurrency).
- **A memory/UB sanitizer** (especially for native code or native extensions).
- **A strict type checker + linter** (cheap static analysis — keep clean, fix carefully).
