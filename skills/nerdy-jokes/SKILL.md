---
name: nerdy-jokes
description: >
  Use when a bug is fixed, a deploy completes, tests go green, the user
  encounters a classic pitfall, the user explicitly asks for a joke, or
  the conversation calls for levity. Also fits when discussing math proofs,
  physics problems, data analysis, or any STEM topic where a well-placed
  joke would be welcome. Covers programming, math, physics, chemistry,
  biology, economics, philosophy, linguistics, engineering, astronomy,
  and statistics.
  Trigger phrases: 說個笑話、來個冷笑話、講笑話、tell me a joke, need a laugh.
  Do NOT use mid-explanation or when the user is frustrated and wants a solution.
---

# Nerdy Jokes

700 one-liner jokes (418 English, 282 Traditional Chinese) spanning programming
and STEM disciplines. Each joke is tagged by topic for contextual delivery.

Sources:
- [pyjokes](https://github.com/pyjokes/pyjokes) (BSD-3) — English programming jokes
- [JokeKappa](https://github.com/vinta/JokeKappa) (MIT) — Chinese programming jokes
- Curated STEM collection — classic folk humor in math, physics, chemistry, etc.

## When to tell a joke

**Transition moments** — right after a resolution, not during the struggle.
Tell at most one joke per session. Treat it like seasoning.

## Tags

### Programming (517 jokes)

| Tag | Count | Matches when... |
|---|---|---|
| `work-culture` | 90 | meetings, deadlines, overtime, scrum, career |
| `algorithms` | 85 | recursion, threads, data structures, complexity |
| `languages` | 73 | Java, Python, C++, type systems, compilers |
| `debugging` | 71 | bugs, errors, testing, fixing, QA |
| `general` | 57 | broad programmer humor |
| `tools` | 41 | vim, git, editors, dependencies, Stack Overflow |
| `os` | 38 | Windows, Linux, hardware |
| `ai` | 29 | machine learning, bots, singularity |
| `networking` | 27 | HTTP, TCP/UDP, APIs, Unicode |
| `devops` | 22 | deploy, CI/CD, servers, Docker |
| `security` | 19 | passwords, hacking, encryption |
| `databases` | 10 | SQL, queries, ORM |
| `frontend` | 4 | CSS, HTML, browsers |
| `legacy` | 4 | old code, technical debt |

### STEM (183 jokes)

| Tag | Count | Matches when... |
|---|---|---|
| `math` | 47 | proofs, topology, calculus, number theory |
| `physics` | 37 | quantum, relativity, thermodynamics |
| `chemistry` | 22 | elements, reactions, periodic table |
| `statistics` | 18 | p-values, correlation, sampling |
| `economics` | 18 | markets, economists, predictions |
| `philosophy` | 18 | logic, existence, paradoxes |
| `linguistics` | 15 | grammar, punctuation, etymology |
| `biology` | 13 | cells, DNA, evolution |
| `astronomy` | 12 | space, planets, gravity |
| `engineering` | 10 | mechanical, civil, design |

### Chuck Norris (category, not a tag)

103 Chuck Norris programmer jokes live under `--category chuck` (English) rather
than the topic tags above. They are exaggerated hero gags ("Chuck Norris can
divide by zero"), not tied to a specific STEM/programming topic — reach for them
only when the session tone is playful and a tall-tale punchline fits. Skip them
in a focused or serious thread.

## How to pick a joke

### Match language → match context

```bash
# Just fixed a bug
python3 scripts/joke.py --tag debugging --lang zh

# Discussing a math proof
python3 scripts/joke.py --tag math --lang en

# Physics rabbit hole
python3 scripts/joke.py --tag physics --lang zh

# Data analysis gone wrong
python3 scripts/joke.py --tag statistics --lang en

# Economics or policy discussion
python3 scripts/joke.py --tag economics --lang zh

# No specific context — random
python3 scripts/joke.py --lang zh
```

### Fallback

If `--tag X --lang Y` returns nothing, the script falls back to `--lang Y` only.

### CLI reference

```bash
python3 scripts/joke.py                            # random joke
python3 scripts/joke.py --lang zh                   # random Chinese joke
python3 scripts/joke.py --tag physics --lang en     # English physics joke
python3 scripts/joke.py --keyword Schrödinger       # search by keyword
python3 scripts/joke.py --category chuck            # Chuck Norris jokes
python3 scripts/joke.py --tags                      # list all tags + counts
python3 scripts/joke.py --count                     # count matching jokes
```

## Delivery style

- Drop the joke naturally after task wrap-up, don't announce it
- Use `>` blockquote to set it apart visually
- Don't explain the joke — if it needs explaining, pick another one
- Match the user's working language; don't default to 中文 if the session is in English

### Iron Laws — Rationalization Table

| What you'll be tempted to think | The rule |
|---|---|
| "Just one line of setup will make it land" | If it needs setup, pick another joke. No exceptions. |
| "The user smiled, a second one fits" | One per session. Diminishing returns are steep. |
| "User is stuck/frustrated but a joke might cheer them up" | No. Solve first, joke only after resolution. |
| "The punchline is subtle, a brief gloss helps" | Never explain. A gloss kills the joke and insults the reader. |
| "I should announce it so the user notices the tonal shift" | Don't. The blockquote is the signal. |

### Example

After a long debugging session involving quantum-level race conditions:

> 終於修好了。
>
> 海森堡超速被攔，警察問：「你知道你開多快嗎？」海森堡：「不知道，但我精確地知道我在哪。」

English session equivalent:

> All green.
>
> A SQL query walks into a bar, approaches two tables, and asks: "Mind if I join you?"

## Gotchas

- **Mid-struggle delivery** — telling a joke while the user is still debugging reads as tone-deaf. Wait for a clean resolution signal (tests pass, deploy completes, "got it", "fixed").
- **Language mismatch** — the CLI defaults to random language. Always pass `--lang` to match the session, otherwise a 中文 joke lands flat in an English debugging thread (and vice versa).
- **Silent empty result** — if `--tag X --lang Y` has zero matches, joke.py falls back to `--lang Y` only; if that's also empty, it picks from all jokes. Verify the printed joke actually matches the context before delivering — don't blindly forward an off-topic fallback.
- **Tag over-specificity** — narrow tags (`frontend`, `legacy`) have few jokes and recycle fast within a project. Prefer broader tags (`general`, `debugging`) for repeat sessions.
- **Explaining the punchline** — the single strongest failure mode. If you catch yourself typing "this works because…", delete the joke entirely and move on.
- **Stacking** — two jokes in one response dilutes both. Pick one, commit.
- **Sarcasm near frustration** — jokes about common pitfalls (`work-culture`, `debugging`) can read as mockery when the user just hit that exact pitfall. Use `general` or a STEM tag instead.
