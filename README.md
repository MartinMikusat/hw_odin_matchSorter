# Odin Match Sorter

An Odin-native fuzzy ranking library derived from Kent C. Dodds' [`match-sorter`](https://github.com/kentcdodds/match-sorter).

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

The package searches typed slices through borrowed strings.
It returns original item indices, copied items, or owned rank metadata.

## Basic search

Initialize one reusable context for each thread that performs searches:

```odin
search: match_sorter.Search_Context
assert(match_sorter.search_context_init(&search) == nil)
defer match_sorter.search_context_destroy(&search)

items := []string{"hi", "hey", "hello", "sup", "yo"}
indices, search_error := match_sorter.match_indices(
	&search,
	items,
	"h",
	match_sorter.Options(string){},
)
assert(search_error == .None)
defer delete(indices)
// indices == {2, 1, 0}; items[indices[0]] == "hello"
```

`match_items` returns shallow item copies.
`match_with_rank_info` returns owned ranked strings and must be released with `ranked_result_destroy`.

`match_indices_into` fills a caller-owned dynamic index buffer.
It retains the buffer capacity across successful searches.

## Typed keys

Struct searches use typed getter procedures.
A getter returns one borrowed string, multiple borrowed strings, or no value.

```odin
Person :: struct {
	name:    string,
	aliases: []string,
}

get_name :: proc(item: ^Person) -> match_sorter.Extracted_Values {
	return match_sorter.single_value(item.name)
}

get_aliases :: proc(item: ^Person) -> match_sorter.Extracted_Values {
	return match_sorter.many_values(item.aliases)
}

keys := []match_sorter.Key(Person){
	{getter = get_name},
	{getter = get_aliases},
}
indices, search_error := match_sorter.match_indices(
	&search,
	people,
	"ada",
	match_sorter.Options(Person){keys = keys},
)
```

Each key can define minimum, maximum, or acceptance threshold ranks.
A custom base sorter resolves equal ranks.
A custom result sorter can replace the complete default sort.

## UTF-8 contract

Queries and every string returned by a key getter must contain valid UTF-8.
Search procedures return `Search_Error.Invalid_UTF8` when either boundary is malformed.

An error returns no owned result.
`match_indices_into` leaves its caller-owned buffer unchanged.
Sorting callbacks do not run after validation fails.

`valid_utf8` lets consumers validate snapshots before they mutate application state.
An encoded `U+FFFD` replacement character is valid.

## Ranking and sorting

The matcher evaluates Unicode scalar values.
Accented and unaccented values remain distinct.

The ranking order is:

1. Case-sensitive equality
2. Case-insensitive equality
3. Prefix
4. Word prefix
5. Substring
6. Acronym
7. Ordered closeness

The default stable merge sort compares equal-rank strings by raw UTF-8 bytes.
For valid UTF-8, this produces deterministic Unicode scalar order without locale state.

## Memory ownership

`Search_Context` reserves 1 GiB of virtual address space by default and initially commits 1 MiB.
Each search prepares its query once and rewinds the arena before returning.

The input slice and extracted strings remain caller-owned.
Index and item results use the supplied result allocator.
Rank metadata clones each `ranked_value` into that allocator.

Each search restores the caller's temporary allocator.
A context supports sequential reuse and retains committed arena pages.
Concurrent searches use one context per thread.

## Verification

```sh
odin check . -no-entry-point
odin test .
```

Run the optional query benchmark with:

```sh
odin test . -o:speed \
  -define:MATCH_SORTER_BENCHMARK=true \
  -define:ODIN_TEST_NAMES=prepared_query_benchmark \
  -define:ODIN_TEST_THREADS=1
```

The benchmark ranks 10,000 candidates with four extracted strings each.

See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for license terms.
