# Decision Framework — right-sizing test rigor

> The single most important judgment in this skill. SQLite's own authors write that 100%
> MC/DC is *"probably not cost effective for a typical application."* The skill is not "do
> what SQLite does" — it is "spend rigor where the cost of being wrong justifies it."

Score the **component**, not the repository. Most real systems mix tiers: an Extreme-tier
storage engine living next to an Essential-tier settings page.

## The four axes (score each 1–5, then sum)

### 1. Criticality / blast radius — *who is hurt, and how many, if this is wrong?*
- **1–2:** internal dev tool, throwaway script, one team's convenience.
- **3:** internal product feature; a bug annoys users but is quickly patched.
- **4–5:** public library / SDK / API, shared platform service, anything embedded in
  thousands of downstream systems you can't reach to patch. *This is SQLite's whole
  justification for extreme rigor: it is one of the [most-deployed](https://sqlite.org/mostdeployed.html)
  pieces of software in existence, so a bug ships everywhere and can't be recalled.*

### 2. Complexity — *how intricate is the logic?*
- **1–2:** straight-line CRUD, config plumbing, thin wrappers.
- **3:** non-trivial branching, several interacting features.
- **4–5:** parsers, state machines, query/optimization planners, concurrency, schedulers,
  money/auth/permission logic, serialization formats. High complexity means more *interaction
  bugs* that only independent oracles and fuzzing surface.

### 3. Persistence — *"does it remember its mistakes?"*
This is the heuristic the article singles out databases for. A pure computation that returns a
wrong answer is bad; a system that **writes corrupt durable state** is far worse, because the
damage outlives the bug, spreads through replication/backups, and may be irrecoverable.
- **1–2:** ephemeral compute, stateless request handling.
- **3:** caches / derived state that can be rebuilt.
- **4–5:** primary storage, migrations, ledgers, event logs, anything writing durable,
  replicated, or hard-to-recall state. A bug here is a *latent landmine*.

### 4. Change frequency — *how often is this refactored or extended, by whom?*
- **1–2:** frozen, rarely touched.
- **3:** steady maintenance.
- **4–5:** high churn, many contributors, people who don't hold the full context. High churn
  raises the value of a regression net that enables *fearless change* — the payoff SQLite
  credits for making aggressive refactoring and new features possible at all.

## Map the sum to a tier (per component)

| Sum | Tier | What to do |
|---|---|---|
| **~4–9** | **Essential** | Regression-test every bug; test malformed input & boundaries; branch coverage where it's free; fast suite; assertions enabled in tests; basic CI matrix; a lightweight written checklist. **Stop there** — fuzzing, mutation testing, and 100% coverage are over-engineering at this tier. |
| **~10–15** | **Essential + selected Advanced** | Add fault injection at your dependency seams; always-on leak detection; coverage-guided fuzzing on any untrusted-input surface; a differential/metamorphic oracle for wrong-answer-sensitive logic; sanitizer runs pre-release; mutation testing on the trickiest modules. |
| **~16–20** | **Essential + Advanced + selected Extreme** | Reserve 100% branch / MC-DC, crash-state simulation, multiple independent harnesses, protocol-monitoring shims, and continuous dedicated-core fuzzing for ubiquitous, persistent, or irrecoverable software. Each Extreme item should have an explicit written justification. |

## Two overrides — promote a component regardless of its sum

1. **Attack surface for untrusted input** (parses user/network/file input, deserializes
   anything): fuzzing + malformed-input tests become **mandatory**, even if the sum is low.
   An input boundary is an attack surface whether or not the logic behind it is complex.
2. **Persists or replicates hard-to-recall state**: integrity + atomicity + crash testing
   become **mandatory**. Corrupt durable state is the failure mode you cannot walk back.

## Allocate effort empirically, not by reputation

Track **where your bugs are actually caught** and shift investment toward the highest-yield
techniques *for your codebase*. SQLite found static analysis low-yield and fuzzing extremely
high-yield — but a suite with weak dynamic testing might find the opposite. Reputation is a
poor allocator; your own escaped-bug postmortems are a good one.

## Worked examples

| Component | C / Cx / P / Cf | Sum | Tier | Notes |
|---|---|---|---|---|
| One-off data-cleanup script | 1 / 1 / 1 / 1 | 4 | Essential (minimal) | A couple of happy-path + a malformed-row test. Anything more is waste. |
| Internal CRUD admin service | 2 / 2 / 3 / 3 | 10 | Essential + light Advanced | Add fault injection on the DB call and leak checks; skip fuzzing/MC-DC. |
| Public OSS library / SDK | 5 / 4 / 2 / 4 | 15 | Essential + full Advanced | Blast radius dominates → coverage-guided fuzzing of the public API, differential vs prior version, mutation testing. |
| File-format parser (untrusted input) | 3 / 4 / 2 / 3 | 12 **+override 1** | Advanced, fuzzing mandatory | Override forces fuzzing + malformed-artifact tests regardless of sum. |
| DB migration / storage layer | 4 / 4 / 5 / 3 | 16 **+override 2** | Extreme on integrity | Crash-state simulation, atomicity assertions, protocol shim, integrity checks after every injected fault. |
| Payments ledger / auth core | 5 / 5 / 5 / 4 | 19 **+both overrides** | Extreme, justified | The rare component that earns the full toolkit, including a second independent harness. |

## Rules of thumb

- **Per module, not per repo.** Apply tiers surgically; document which module is which tier.
- **When torn between two tiers, lean low on cost, high on the overrides.** Essential items are
  almost never the wrong call; Extreme items are wrong far more often than right for typical
  apps — *except* where an override applies, where the cost of skipping is catastrophic.
- **Write the tier down.** A one-line note ("storage = Extreme-integrity; UI = Essential")
  in the test README keeps the next person from both over- and under-investing.
