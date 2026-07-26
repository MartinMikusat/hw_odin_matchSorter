package match_sorter

import "core:fmt"
import "core:testing"
import "core:time"

COLLATION_BENCHMARK_CANDIDATES :: 10_000
COLLATION_BENCHMARK_VALUES := [?]string{
	"Zulu transcript",
	"Álpha source",
	"omega exercise",
	"Beta command",
	"delta playback",
	"Écho register",
	"Gamma palette",
	"theta segment",
}

@(test)
collation_allocation_benchmark :: proc(t: ^testing.T) {
	if !MATCH_SORTER_BENCHMARK { return }
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := make([]string, COLLATION_BENCHMARK_CANDIDATES)
	defer delete(items)
	for &item, index in items {
		item = COLLATION_BENCHMARK_VALUES[(index*5)%len(COLLATION_BENCHMARK_VALUES)]
	}
	benchmark_mac_sort_reset()
	started := time.now()
	indices := match_indices(
		&search,
		items,
		"",
		Typed_Options(string){},
	)
	elapsed := time.since(started)
	defer delete(indices)
	creations, comparisons := benchmark_mac_sort_stats()
	testing.expect_value(t, creations, len(indices))
	testing.expect(t, comparisons > 0)
	fmt.printf(
		"[collation-benchmark] candidates=%d cf_strings=%d comparisons=%d elapsed_ns=%d matches=%d\n",
		len(items),
		creations,
		comparisons,
		time.duration_nanoseconds(elapsed),
		len(indices),
	)
}
