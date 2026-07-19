# Odin Match Sorter

An Odin port of Kent C. Dodds' [`match-sorter`](../research/reference-projects/match-sorter/), pinned at upstream commit `3bfa8803d64a2c0fe4b532822e5abf8e956e37f8`.

## AI-assisted development disclosure

**This project was built using GPT-5.**

The port preserves the upstream ranking algorithm, deterministic tie breaking, rank metadata, thresholds, per-key rank limits, dotted and wildcard object paths, callback keys, diacritic handling, custom base sorting, and custom result sorting. Odin strings use a direct `match_sorter_strings` entry point. Arbitrary JavaScript-shaped data maps to the tagged `Value` tree and passes through `match_sorter`. Returned slices belong to the supplied allocator; item strings and nested `Value` storage remain borrowed from the input.

```odin
items := []string{"hi", "hey", "hello", "sup", "yo"}
matches := match_sorter_strings(items, "h")
defer delete(matches)
// {"hello", "hey", "hi"}
```

Run the complete migrated suite:

```sh
odin test .
```

The upstream MIT license is reproduced in [`LICENSE`](LICENSE).
