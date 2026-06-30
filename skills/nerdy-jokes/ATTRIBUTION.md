# Joke corpus attribution

`references/jokes.json` is a **merged and reformatted** collection (702 jokes),
not a verbatim copy of any single upstream project. Each entry carries a
`source` field recording where it came from. The jokes were normalized into a
common schema (`content`, `lang`, `source`, `category`, `tags`) and re-tagged
for this skill; the original joke text is preserved.

## Sources

| `source` value | Count | Origin | License |
|---|---|---|---|
| `pyjokes` | 287 | [pyjokes/pyjokes](https://github.com/pyjokes/pyjokes) | BSD-3-Clause |
| `jokekappa-*` | 232 | [vinta/JokeKappa](https://github.com/vinta/JokeKappa) | MIT |
| `curated` | 183 | Original STEM collection written for this skill | MIT (this repo) |

`jokekappa-*` covers the `jokekappa-codetengu_weekly`,
`jokekappa-others`, `jokekappa-pyjokes`, and `jokekappa-kobeengineer`
sub-sources, all drawn from the JokeKappa dataset.

The full upstream license texts are bundled alongside this file, as their
redistribution terms require:

- pyjokes (BSD-3-Clause) — [`LICENSE-pyjokes.txt`](./LICENSE-pyjokes.txt)
- JokeKappa (MIT) — [`LICENSE-jokekappa.txt`](./LICENSE-jokekappa.txt)

### pyjokes — BSD-3-Clause

> Copyright 2014- Pyjokes Society

Redistributed under the [BSD 3-Clause License](./LICENSE-pyjokes.txt), whose
full text (including the required copyright notice, conditions, and disclaimer)
is bundled as `LICENSE-pyjokes.txt`. The joke text is redistributed unmodified;
only the surrounding data format and tags were added.

### JokeKappa — MIT

> Copyright (c) 2017 CodeTengu

Redistributed under the [MIT License](./LICENSE-jokekappa.txt), whose full text
is bundled as `LICENSE-jokekappa.txt`. The joke text is redistributed
unmodified.

### Curated STEM jokes

The 183 `curated` entries are classic folk humor in math, physics, chemistry,
and other STEM fields, written/compiled for this skill and covered by this
repository's [MIT license](../../LICENSE).
