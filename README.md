# Odin Match Sorter

A macOS Odin port of Kent C. Dodds' [`match-sorter`](https://github.com/kentcdodds/match-sorter), pinned at upstream commit `3bfa8803d64a2c0fe4b532822e5abf8e956e37f8`.

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

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

`match_indices_into_typed` clears and fills a caller-owned dynamic index buffer. Initialize the buffer with the required allocator before the first call. The procedure retains its capacity across searches.

## Dynamic compatibility API

The tagged `Value` tree represents JavaScript-shaped null, undefined, scalar, array, and object data. `match_indices`, `match_items`, and `match_with_rank_info` select the dynamic overload when passed `[]Value` and `Options`. Dynamic keys support direct properties, dotted paths, numeric array indices, `*` wildcards, and callbacks.

The caller owns every input `Value`, nested slice, field name, and string. Search results borrow or shallow-copy those values; the matcher never destroys input storage.

## Memory ownership

`Search_Context` reserves 1 GiB of virtual address space by default and initially commits 1 MiB. Each search prepares its query once in this arena. The prepared query contains its normalized text, lowercase text, and UTF-16 units.

The ranking loop transforms each candidate value in scratch storage. It reuses the prepared query for every candidate and extracted field. At return, the search rewinds its arena checkpoint and retains committed pages for the next search.

Each search restores the caller's temporary allocator before it returns. Caller
temporary allocations do not become part of the search arena.

The input dataset remains in the caller's heap or arena. Index and item results use the result allocator passed to the matching procedure and must be deleted with that allocator. `match_indices_into_typed` uses the allocator stored in the caller's dynamic buffer. Ranked metadata clones its `ranked_value` strings into the result allocator and therefore uses `ranked_result_destroy` for complete teardown.

A context supports sequential reuse. Concurrent searches use one context per thread. `search_context_destroy` releases the virtual-memory reservation and the retained `en_US` CoreFoundation locale.

## Compatibility contract

- Ranking uses JavaScript-compatible UTF-16 code-unit length and indexing.
- Diacritic removal reproduces `remove-accents@0.5.0` exactly.
- Default tie sorting uses macOS CoreFoundation with a fixed `en_US` locale.
- Ranking uses a stable `O(n log n)` merge sort.
- Custom base and result sort callbacks override the default ordering paths.

This package is macOS-specific because the default comparator links CoreFoundation.

## Sorting implementation

The default sorter preserves upstream `String.localeCompare` tie behavior with a fixed `en_US` CoreFoundation locale. Before sorting, it creates one `CFString` for each ranked candidate. The stable sort reuses these objects for every comparison, then releases the complete batch.

Context-backed searches retain one locale across calls. Direct compatibility procedures create and release a locale when they run the default tie sort.

This design takes inspiration from [FFF at commit `fde8c52`](https://github.com/dmtrKovalenko/fff/blob/fde8c52a298a2fa4375edf626e0c37b0400f5a8b/crates/fff-core/src/score.rs#L993-L1041). FFF calculates complete numeric score records before sorting, so its comparator only reads prepared metadata. This package applies the same preparation boundary but retains locale-aware text comparison to preserve `match-sorter` parity.

## Verification

```sh
odin test .
```

Run the optional query benchmark with:

```sh
odin test . -o:speed \
  -define:MATCH_SORTER_BENCHMARK=true \
  -define:ODIN_TEST_NAMES=prepared_query_benchmark \
  -define:ODIN_TEST_THREADS=1
```

The benchmark ranks 10,000 candidates with four extracted values each. It reports the candidate count, extracted value count, scratch bytes, elapsed time, and match count.

Run the optional collation benchmark with:

```sh
odin test . -o:speed \
  -define:MATCH_SORTER_BENCHMARK=true \
  -define:ODIN_TEST_NAMES=collation_allocation_benchmark \
  -define:ODIN_TEST_THREADS=1
```

The benchmark ranks 10,000 equal-rank candidates. It verifies one CoreFoundation string per candidate and reports the comparison count and elapsed time.

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for license terms and dependency attribution.
