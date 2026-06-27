# Fault Injection & Resilience — testing the unhappy path

> The highest-leverage, most broadly applicable theme in the SQLite methodology. *"It is
> relatively easy to build a system that behaves correctly on well-formed inputs on a fully
> functional computer. It is more difficult to build a system that responds sanely to invalid
> inputs and continues to function following system malfunctions."* Error-handling and cleanup
> code is the least-exercised and most dangerous code you have, because it only runs when
> something already went wrong.

What SQLite does: simulated **OOM** (an instrumented `malloc` rigged to fail after N
allocations), simulated **I/O errors** (a Virtual File System that fails after N operations),
simulated **crashes/power loss** (a VFS that snapshots and then damages the filesystem), and
**compound failures** (a fault injected while recovering from a prior fault). After every
simulated failure it runs `PRAGMA integrity_check` to confirm no corruption.

---

## 1. Architect an injectable seam (the prerequisite)

You cannot inject a failure you can't intercept. Every external resource needs a seam — an
interface you can swap for a failing test double:

- **Memory / resource allocation** → a pluggable allocator or resource factory.
- **Filesystem / storage** → a storage interface (SQLite's VFS is exactly this).
- **Network / RPC / downstream services** → a client interface, or HTTP-level interception.
- **Database / queue / cache** → a repository/gateway interface.
- **Clock / randomness** → injectable, so timeouts and retries are testable deterministically.

If your code calls `fetch()` or `open()` or `malloc()` directly with no seam, the first
hardening task is to *introduce the seam*. This usually improves the design anyway.

(E) Even at Essential tier, you should be able to make at least your primary datastore call
fail and assert the code handles it.

## 2. The failure-point advancement loop (the signature technique)

A single "make it fail once" test only exercises one cleanup path. SQLite's insight: sweep the
injection point across **every** step of a multi-step operation, so every cleanup/rollback
branch runs. The loop:

```
n = 1
loop:
    arm the seam to fail on the n-th resource operation
    run the operation under test
    if the operation completed WITHOUT hitting the injected failure:
        break          # n is now past the last fallible step — done
    assert: a clean, typed error was returned (no crash/hang/UB)
    assert: durable/in-memory state is consistent (integrity check)
    assert: every resource acquired before the failure was released (no leak)
    n = n + 1
```

This guarantees coverage of the failure handling at *position 1, 2, 3, …* — including the
nasty ones deep inside a transaction. Run the whole loop **twice**:

- (A) **transient mode** — fail once, then let the resource recover (tests retry/resume).
- (A) **persistent mode** — keep failing after the first failure (tests give-up/rollback).

These two modes catch different bugs: transient catches broken retry logic; persistent catches
broken abort/cleanup logic.

## 3. Verify *integrity and atomicity after* failure — not just the return code

A correct error code is necessary but **insufficient**. After each injected failure assert:

- (E) **State consistency** — the equivalent of SQLite's `integrity_check`. For your domain:
  invariants still hold, no half-written records, indexes match data, counts reconcile.
- (E) **Atomicity (all-or-nothing)** — the interrupted operation left state equal to the
  *pre-state* OR the *fully-completed-state*, never a partial in-between. This is the property
  that makes a system safe to retry.
- (A) **No resource leak on the error path** — see §4. Cleanup code is where leaks hide.

## 4. Always-on, zero-setup resource-leak detection

SQLite's TCL and TH3 harnesses track system resources and **report leaks on every test run,
no configuration required**. The principle (philosophy #6): a leak check you have to opt into
gets skipped. Make it automatic in your test teardown / global hooks.

- (A) Track **all** resource types, not just memory: file descriptors, sockets, threads,
  goroutines, DB connections, locks/mutexes, temp files, timers, event listeners/subscriptions.
- (A) Assert zero leaks **especially on error paths** — combine §2's fault injection with a
  leak assertion so you prove cleanup happens even when the operation failed partway.
- GC'd languages are *not* exempt: they leak connections, threads, handles, and listeners just
  as readily as C leaks memory.

## 5. Crash / power-loss simulation (X — durability-critical systems)

For anything that must survive a crash with state intact (databases, write-ahead logs, file
formats, durable queues). You cannot pull the plug for real, so model the **post-crash on-disk
state** in a test double:

- Insert a storage shim that can **snapshot** the persisted bytes at a chosen point.
- Run the operation; revert to the snapshot to simulate "the crash happened here."
- **Model realistic crash semantics — this is the part intuition gets wrong:** only
  explicitly-`fsync`'d writes are guaranteed to survive. Unsynced writes may be **lost,
  reordered, or torn** (partially written). A naive "writes simply stop at the crash point"
  model is too optimistic and will pass code that is actually missing sync barriers. The
  simulation must reorder/drop/tear unsynced writes to be worth anything.
- Sweep the crash point across the whole operation (as in §2), and for each point apply
  **repeated randomized damage** — so you cover both *where* it crashed and *what* got
  corrupted.
- After each, open the artifact and assert it is well-formed and the transaction either fully
  committed or fully rolled back.

## 6. Protocol-monitoring shim for ordering/durability invariants (X)

SQLite's "journal-test VFS" watches all I/O between the database file and its rollback journal
and raises an assertion if anything is written to the database that wasn't *first written and
synced to the journal*. This makes a durability protocol **executable**: the invariant is
checked continuously on every I/O, not just spot-checked.

Generalize: wherever correctness depends on an ordering or durability contract — *journal
before data, persist before publish, write-ahead before apply, ack only after commit* — insert
a shim at the boundary that asserts the ordering on **every** operation. It catches violations
the moment they occur, with a precise location, instead of as mysterious downstream corruption.

## 7. Compound / stacked failures (A)

Real outages cascade. Test a **second fault injected while recovering from the first** — e.g.
an I/O error or OOM *during crash recovery*, a timeout *during a retry*, a disk-full *during
rollback*. Recovery code is itself rarely-run code, so a fault during recovery hits the
least-tested path in the entire system. These tests are cheap once §1's seams exist.

---

## Anti-patterns specific to this theme

- **Happy-path leak/assertion checks give false confidence.** The value is in checking cleanup
  *after* an injected failure. Passing leak checks on the success path tell you little.
- **Opt-in injection that never runs.** If the failure tests aren't part of the default suite,
  they rot. Tag them as their own category but keep them running.
- **An over-optimistic crash model** (writes stop cleanly at the crash point) is worse than no
  crash test — it passes code that's missing `fsync` barriers. Reorder/drop/tear unsynced
  writes or don't bother.
- **Asserting only the error code.** The bug that corrupts your database returns
  `SQLITE_OK`-looking success while leaving state inconsistent. Always check state, not just
  the return value.

→ Tools per language (allocator hooks, `msw`/`nock`, `pyfakefs`, fault-injection fixtures,
leak detectors, `-race`): `references/ecosystem-pointers.md`.
