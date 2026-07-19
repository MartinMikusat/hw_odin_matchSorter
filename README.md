# Odin Match Sorter

A macOS Odin port of Kent C. Dodds' [`match-sorter`](https://github.com/kentcdodds/match-sorter), pinned at upstream commit `3bfa8803d64a2c0fe4b532822e5abf8e956e37f8`.

## AI-assisted development disclosure

**This project was built using GPT-5.**

The port implements the complete upstream ranking and option surface and carries all 42 upstream tests as individually named Odin tests. It also tests Odin-specific ownership, a 100,000-item search, UTF-16-compatible scoring, and the complete `remove-accents@0.5.0` table.

## Typed API

The typed API borrows the input slice and its strings. It returns original indices, so searching never copies or relocates the dataset.

```odin
search: match_sorter.Search_Context
assert(match_sorter.search_context_init(&search) == nil)
defer match_sorter.search_context_destroy(&search)

items := []string{"hi", "hey", "hello", "sup", "yo"}
indices := match_sorter.match_indices(
	&search,
	items,
	"h",
	match_sorter.Typed_Options(string){},
)
defer delete(indices)
// indices == {2, 1, 0}; items[indices[0]] == "hello"
```

Structs provide typed key getters. A getter returns one borrowed string with `single_value`, multiple borrowed strings with `many_values`, or an empty `Extracted_Values` when the item has no value for that key.

```odin
Person :: struct {name: string, aliases: []string}

get_name :: proc(item: ^Person) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(item.name)
}

get_aliases :: proc(item: ^Person) -> match_sorter.Extracted_Values {
	return match_sorter.many_values(item.aliases)
}

keys := []match_sorter.Typed_Key(Person){
	{getter=get_name},
	{getter=get_aliases},
}
indices := match_sorter.match_indices(
	&search,
	people,
	"ada",
	match_sorter.Typed_Options(Person){keys=keys},
)
defer delete(indices)
```

`match_items` returns a shallow item copy when that shape is more convenient. `match_with_rank_info` returns owned `ranked_value` strings and must be released with `ranked_result_destroy`.

## Dynamic compatibility API

The tagged `Value` tree represents JavaScript-shaped null, undefined, scalar, array, and object data. `match_indices`, `match_items`, and `match_with_rank_info` select the dynamic overload when passed `[]Value` and `Options`. Dynamic keys support direct properties, dotted paths, numeric array indices, `*` wildcards, and callbacks.

The caller owns every input `Value`, nested slice, field name, and string. Search results borrow or shallow-copy those values; the matcher never destroys input storage.

## Memory ownership

`Search_Context` reserves 1 GiB of virtual address space by default and initially commits 1 MiB. A query allocates normalized strings, UTF-16 units, extracted values, merge-sort storage, and ranked candidates from that arena. At return, the query rewinds its arena checkpoint, retaining committed pages for the next search.

The input dataset remains in the caller's heap or arena. Index and item results use the result allocator passed to the matching procedure and must be deleted with that allocator. Ranked metadata clones its `ranked_value` strings into the result allocator and therefore uses `ranked_result_destroy` for complete teardown.

A context supports sequential reuse. Concurrent searches use one context per thread. `search_context_destroy` releases the virtual-memory reservation and the retained `en_US` CoreFoundation locale.

## Compatibility contract

- Ranking uses JavaScript-compatible UTF-16 code-unit length and indexing.
- Diacritic removal reproduces `remove-accents@0.5.0` exactly.
- Default tie sorting uses macOS CoreFoundation with a fixed `en_US` locale.
- Ranking uses a stable `O(n log n)` merge sort.
- Custom base and result sort callbacks override the default ordering paths.

This package is macOS-specific because the default comparator links CoreFoundation.

## Verification

```sh
odin test .
```

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for license terms and dependency attribution.
