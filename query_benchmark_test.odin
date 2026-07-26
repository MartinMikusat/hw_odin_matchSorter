package match_sorter

import "core:fmt"
import "core:testing"
import "core:time"
import mem_virtual "core:mem/virtual"

MATCH_SORTER_BENCHMARK :: #config(MATCH_SORTER_BENCHMARK, false)
QUERY_BENCHMARK_CANDIDATES :: 10_000
QUERY_BENCHMARK_EXTRACTED_VALUES :: 4

Query_Benchmark_Item :: struct {
	values: [QUERY_BENCHMARK_EXTRACTED_VALUES]string,
}

query_benchmark_values :: proc(item: ^Query_Benchmark_Item) -> Extracted_Values {
	return many_values(item.values[:])
}

@(test)
prepared_query_benchmark :: proc(t: ^testing.T) {
	if !MATCH_SORTER_BENCHMARK { return }
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := make([]Query_Benchmark_Item, QUERY_BENCHMARK_CANDIDATES)
	defer delete(items)
	for &item in items {
		item.values = {
			"voice warmup routine",
			"timed transcript segment",
			"command palette action",
			"exercise playback control",
		}
	}
	keys := []Typed_Key(Query_Benchmark_Item){{getter=query_benchmark_values}}
	options := Typed_Options(Query_Benchmark_Item){keys=keys, locale=search.locale}
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(&search)
	previous_temp := context.temp_allocator
	defer context.temp_allocator = previous_temp
	context.temp_allocator = scratch
	used_before := search.scratch.total_used
	started := time.now()
	ranked := rank_typed_items(
		items,
		"žltý warmup 😀",
		options,
		scratch,
	)
	elapsed := time.since(started)
	fmt.printf(
		"[query-benchmark] candidates=%d extracted_values=%d scratch_bytes=%d elapsed_ns=%d matches=%d\n",
		len(items),
		len(items) * QUERY_BENCHMARK_EXTRACTED_VALUES,
		search.scratch.total_used - used_before,
		time.duration_nanoseconds(elapsed),
		len(ranked),
	)
}
