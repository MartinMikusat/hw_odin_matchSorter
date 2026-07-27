package match_sorter

import "core:mem"
import "core:testing"
import mem_virtual "core:mem/virtual"

expect_indices :: proc(t: ^testing.T, actual, expected: []int) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) {return}
	for value, index in actual {
		testing.expect_value(t, value, expected[index])
	}
}

expect_temp_allocator_identity :: proc(
	t: ^testing.T,
	expected: mem.Allocator,
) {
	testing.expect(t, context.temp_allocator.procedure == expected.procedure)
	testing.expect(t, context.temp_allocator.data == expected.data)
}

expect_rank :: proc(
	t: ^testing.T,
	value, query: string,
	expected: Ranking,
) {
	rank, search_error := get_match_ranking(value, query)
	testing.expect_value(t, search_error, Search_Error.None)
	testing.expect_value(t, rank, expected)
}

Search_Item :: struct {
	name:    string,
	aliases: []string,
	color:   string,
}

item_name :: proc(item: ^Search_Item) -> Extracted_Values {
	return single_value(item.name)
}

item_aliases :: proc(item: ^Search_Item) -> Extracted_Values {
	return many_values(item.aliases)
}

item_color :: proc(item: ^Search_Item) -> Extracted_Values {
	return single_value(item.color)
}

reverse_base_sort :: proc(
	a, b: ^string,
	a_info, b_info: ^Ranked_Index,
) -> int {
	if a_info.item_index == b_info.item_index {return 0}
	return -1 if a_info.item_index > b_info.item_index else 1
}

reverse_sorter :: proc(
	items: []string,
	ranked: ^[dynamic]Ranked_Index,
) {
	for left, right := 0, len(ranked)-1; left < right; left, right = left+1, right-1 {
		ranked[left], ranked[right] = ranked[right], ranked[left]
	}
}

error_sort_called: bool
error_base_sort_called: bool

error_sorter :: proc(
	items: []string,
	ranked: ^[dynamic]Ranked_Index,
) {
	error_sort_called = true
}

error_base_sort :: proc(
	a, b: ^string,
	a_info, b_info: ^Ranked_Index,
) -> int {
	error_base_sort_called = true
	return 0
}

@(test)
utf8_validation_distinguishes_encoded_replacement_rune_test :: proc(
	t: ^testing.T,
) {
	testing.expect(t, valid_utf8(""))
	testing.expect(t, valid_utf8("voice 😀 \uFFFD"))

	invalid_leading_bytes := []byte{0x80}
	invalid_truncated_bytes := []byte{0xe2, 0x82}
	invalid_overlong_bytes := []byte{0xc0, 0xaf}
	invalid_surrogate_bytes := []byte{0xed, 0xa0, 0x80}
	invalid_range_bytes := []byte{0xf4, 0x90, 0x80, 0x80}
	invalid_leading := transmute(string)invalid_leading_bytes
	invalid_truncated := transmute(string)invalid_truncated_bytes
	invalid_overlong := transmute(string)invalid_overlong_bytes
	invalid_surrogate := transmute(string)invalid_surrogate_bytes
	invalid_range := transmute(string)invalid_range_bytes
	testing.expect(t, !valid_utf8(invalid_leading))
	testing.expect(t, !valid_utf8(invalid_truncated))
	testing.expect(t, !valid_utf8(invalid_overlong))
	testing.expect(t, !valid_utf8(invalid_surrogate))
	testing.expect(t, !valid_utf8(invalid_range))
}

@(test)
ranking_categories_test :: proc(t: ^testing.T) {
	expect_rank(t, "hello", "hello", CASE_SENSITIVE_EQUAL)
	expect_rank(t, "HELLO", "hello", EQUAL)
	expect_rank(t, "hello world", "hell", STARTS_WITH)
	expect_rank(t, "fiji apple", "app", WORD_STARTS_WITH)
	expect_rank(t, "crabapple", "app", CONTAINS)
	expect_rank(t, "Hypertext Markup Language", "hml", ACRONYM)
	expect_rank(t, "abc", "ac", MATCHES+0.5)
	expect_rank(t, "abc", "z", NO_MATCH)
}

@(test)
rune_ranking_and_diacritic_distinction_test :: proc(t: ^testing.T) {
	expect_rank(t, "😀ab", "😀b", MATCHES+0.5)
	expect_rank(t, "café", "café", CASE_SENSITIVE_EQUAL)
	expect_rank(t, "café", "cafe", NO_MATCH)
}

@(test)
string_search_uses_raw_utf8_tie_order_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	items := []string{"a", "á", "B", "A", "a"}
	indices, search_error := match_indices(
		&search,
		items,
		"",
		Options(string){},
	)
	defer delete(indices)
	testing.expect_value(t, search_error, Search_Error.None)
	expect_indices(t, indices, []int{3, 2, 0, 4, 1})
}

@(test)
typed_keys_and_rank_metadata_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	items := []Search_Item{
		{name = "Voice", aliases = []string{"lead", "warmup"}},
		{name = "Breath", aliases = []string{"voice", "support"}},
		{name = "Unrelated", aliases = []string{"exercise"}},
	}
	keys := []Key(Search_Item){
		{getter = item_name},
		{getter = item_aliases},
	}
	result, search_error := match_with_rank_info(
		&search,
		items,
		"voice",
		Options(Search_Item){keys = keys},
	)
	defer ranked_result_destroy(&result)
	testing.expect_value(t, search_error, Search_Error.None)
	testing.expect_value(t, len(result.items), 2)
	testing.expect_value(t, result.items[0].item_index, 1)
	testing.expect_value(t, result.items[0].rank, CASE_SENSITIVE_EQUAL)
	testing.expect_value(t, result.items[0].key_index, 1)
	testing.expect_value(t, result.items[1].item_index, 0)
	testing.expect_value(t, result.items[1].key_index, 0)
}

@(test)
global_and_per_key_thresholds_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	items := []Search_Item{
		{name = "Fred", color = "Orange"},
		{name = "Jen", color = "Red"},
	}
	keys := []Key(Search_Item){
		{
			getter = item_name,
			attributes = {
				has_threshold = true,
				threshold = STARTS_WITH,
			},
		},
		{getter = item_color},
	}
	indices, search_error := match_indices(
		&search,
		items,
		"ed",
		Options(Search_Item){
			keys = keys,
		},
	)
	defer delete(indices)
	testing.expect_value(t, search_error, Search_Error.None)
	expect_indices(t, indices, []int{1})

	global_indices, global_error := match_indices(
		&search,
		items,
		"ed",
		Options(Search_Item){
			keys = []Key(Search_Item){{getter = item_name}},
			has_threshold = true,
			threshold = STARTS_WITH,
		},
	)
	defer delete(global_indices)
	testing.expect_value(t, global_error, Search_Error.None)
	testing.expect_value(t, len(global_indices), 0)
}

@(test)
key_minimum_and_maximum_ranks_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	items := []Search_Item{
		{name = "Earl Grey", color = "A"},
		{name = "Assam", color = "B"},
	}
	keys := []Key(Search_Item){
		{getter = item_name},
		{
			getter = item_color,
			attributes = {
				has_max = true,
				max_ranking = STARTS_WITH,
			},
		},
	}
	result, search_error := match_with_rank_info(
		&search,
		items,
		"A",
		Options(Search_Item){keys = keys},
	)
	defer ranked_result_destroy(&result)
	testing.expect_value(t, search_error, Search_Error.None)
	testing.expect_value(t, result.items[0].item_index, 1)
	testing.expect_value(t, result.items[0].rank, STARTS_WITH)
}

@(test)
custom_sort_callbacks_override_default_ties_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []string{"A apple", "B apple", "C apple"}

	base_indices, base_error := match_indices(
		&search,
		items,
		"apple",
		Options(string){base_sort = reverse_base_sort},
	)
	defer delete(base_indices)
	testing.expect_value(t, base_error, Search_Error.None)
	expect_indices(t, base_indices, []int{2, 1, 0})

	sorted_indices, sorter_error := match_indices(
		&search,
		items,
		"apple",
		Options(string){sorter = reverse_sorter},
	)
	defer delete(sorted_indices)
	testing.expect_value(t, sorter_error, Search_Error.None)
	expect_indices(t, sorted_indices, []int{2, 1, 0})
}

@(test)
item_and_ranked_results_own_their_output_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []string{"hello", "hey", "sup"}

	matched, item_error := match_items(
		&search,
		items,
		"h",
		Options(string){},
	)
	defer delete(matched)
	testing.expect_value(t, item_error, Search_Error.None)
	testing.expect_value(t, matched[0], "hello")

	ranked, ranked_error := match_with_rank_info(
		&search,
		items,
		"h",
		Options(string){},
	)
	defer ranked_result_destroy(&ranked)
	testing.expect_value(t, ranked_error, Search_Error.None)
	other, other_error := match_indices(
		&search,
		items,
		"s",
		Options(string){},
	)
	defer delete(other)
	testing.expect_value(t, other_error, Search_Error.None)
	testing.expect_value(t, ranked.items[0].ranked_value, "hello")
	testing.expect_value(t, ranked.items[1].ranked_value, "hey")
}

@(test)
invalid_utf8_returns_no_owned_results_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	invalid_query_bytes := []byte{0xff}
	invalid_query := transmute(string)invalid_query_bytes
	items := []string{"valid"}

	indices, indices_error := match_indices(
		&search,
		items,
		invalid_query,
		Options(string){},
	)
	testing.expect_value(t, indices_error, Search_Error.Invalid_UTF8)
	testing.expect(t, indices == nil)

	matched, items_error := match_items(
		&search,
		items,
		invalid_query,
		Options(string){},
	)
	testing.expect_value(t, items_error, Search_Error.Invalid_UTF8)
	testing.expect(t, matched == nil)

	ranked, ranked_error := match_with_rank_info(
		&search,
		items,
		invalid_query,
		Options(string){},
	)
	testing.expect_value(t, ranked_error, Search_Error.Invalid_UTF8)
	testing.expect(t, ranked.items == nil)

	into := make([dynamic]int)
	defer delete(into)
	append(&into, 7)
	into_error := match_indices_into(
		&search,
		items,
		invalid_query,
		Options(string){},
		&into,
	)
	testing.expect_value(t, into_error, Search_Error.Invalid_UTF8)
	expect_indices(t, into[:], []int{7})

	rank, rank_error := get_match_ranking("valid", invalid_query)
	testing.expect_value(t, rank_error, Search_Error.Invalid_UTF8)
	testing.expect_value(t, rank, NO_MATCH)

	invalid_item_bytes := []byte{0xe2, 0x82}
	invalid_items := []string{transmute(string)invalid_item_bytes}
	item_indices, item_search_error := match_indices(
		&search,
		invalid_items,
		"v",
		Options(string){},
	)
	testing.expect_value(
		t,
		item_search_error,
		Search_Error.Invalid_UTF8,
	)
	testing.expect(t, item_indices == nil)
}

Invalid_Item :: struct {
	single: string,
	many:   []string,
}

invalid_single_getter :: proc(item: ^Invalid_Item) -> Extracted_Values {
	return single_value(item.single)
}

invalid_many_getter :: proc(item: ^Invalid_Item) -> Extracted_Values {
	return many_values(item.many)
}

@(test)
invalid_getter_values_preserve_into_buffer_and_skip_sort_test :: proc(
	t: ^testing.T,
) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	invalid_bytes := []byte{0xe2, 0x82}
	invalid := transmute(string)invalid_bytes
	single_items := []Invalid_Item{{single = invalid}}
	single_keys := []Key(Invalid_Item){{getter = invalid_single_getter}}
	result := make([dynamic]int)
	defer delete(result)
	append(&result, 9, 8)
	search_error := match_indices_into(
		&search,
		single_items,
		"x",
		Options(Invalid_Item){keys = single_keys},
		&result,
	)
	testing.expect_value(t, search_error, Search_Error.Invalid_UTF8)
	expect_indices(t, result[:], []int{9, 8})

	many_items := []Invalid_Item{{many = []string{"valid", invalid}}}
	many_keys := []Key(Invalid_Item){{getter = invalid_many_getter}}
	many_result, many_error := match_indices(
		&search,
		many_items,
		"v",
		Options(Invalid_Item){keys = many_keys},
	)
	testing.expect_value(t, many_error, Search_Error.Invalid_UTF8)
	testing.expect(t, many_result == nil)

	error_sort_called = false
	error_base_sort_called = false
	string_result, string_error := match_indices(
		&search,
		[]string{"valid", invalid},
		"v",
		Options(string){sorter = error_sorter},
	)
	testing.expect_value(t, string_error, Search_Error.Invalid_UTF8)
	testing.expect(t, string_result == nil)
	testing.expect(t, !error_sort_called)

	base_result, base_error := match_indices(
		&search,
		[]string{"valid", invalid},
		"v",
		Options(string){base_sort = error_base_sort},
	)
	testing.expect_value(t, base_error, Search_Error.Invalid_UTF8)
	testing.expect(t, base_result == nil)
	testing.expect(t, !error_base_sort_called)
}

@(test)
indices_into_reuses_caller_buffer_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []string{"hello", "hey", "sup", "yo"}
	expected, expected_error := match_indices(
		&search,
		items,
		"h",
		Options(string){},
	)
	defer delete(expected)
	testing.expect_value(t, expected_error, Search_Error.None)

	result := make([dynamic]int, 0, len(items))
	defer delete(result)
	search_error := match_indices_into(
		&search,
		items,
		"h",
		Options(string){},
		&result,
	)
	testing.expect_value(t, search_error, Search_Error.None)
	expect_indices(t, result[:], expected)
	buffer := raw_data(result[:])
	result_capacity := cap(result)

	search_error = match_indices_into(
		&search,
		items,
		"z",
		Options(string){},
		&result,
	)
	testing.expect_value(t, search_error, Search_Error.None)
	testing.expect_value(t, len(result), 0)
	testing.expect_value(t, cap(result), result_capacity)

	search_error = match_indices_into(
		&search,
		items,
		"he",
		Options(string){},
		&result,
	)
	testing.expect_value(t, search_error, Search_Error.None)
	testing.expect(t, raw_data(result[:]) == buffer)
	testing.expect_value(t, search.scratch.total_used, uint(0))
}

@(test)
search_apis_restore_caller_temp_allocator_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	caller_arena: mem_virtual.Arena
	caller_error := mem_virtual.arena_init_growing(&caller_arena)
	testing.expect_value(t, caller_error, nil)
	if caller_error != nil {return}
	defer mem_virtual.arena_destroy(&caller_arena)

	previous := context.temp_allocator
	defer context.temp_allocator = previous
	caller_allocator := mem_virtual.arena_allocator(&caller_arena)
	context.temp_allocator = caller_allocator
	items := []string{"hello", "hey"}

	indices, indices_error := match_indices(
		&search,
		items,
		"h",
		Options(string){},
	)
	delete(indices)
	testing.expect_value(t, indices_error, Search_Error.None)
	expect_temp_allocator_identity(t, caller_allocator)

	into := make([dynamic]int)
	into_error := match_indices_into(
		&search,
		items,
		"h",
		Options(string){},
		&into,
	)
	delete(into)
	testing.expect_value(t, into_error, Search_Error.None)
	expect_temp_allocator_identity(t, caller_allocator)

	matched, item_error := match_items(
		&search,
		items,
		"h",
		Options(string){},
	)
	delete(matched)
	testing.expect_value(t, item_error, Search_Error.None)
	expect_temp_allocator_identity(t, caller_allocator)

	ranked, ranked_error := match_with_rank_info(
		&search,
		items,
		"h",
		Options(string){},
	)
	ranked_result_destroy(&ranked)
	testing.expect_value(t, ranked_error, Search_Error.None)
	expect_temp_allocator_identity(t, caller_allocator)
}

@(test)
caller_temporaries_survive_later_searches_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	caller_arena: mem_virtual.Arena
	caller_error := mem_virtual.arena_init_growing(&caller_arena)
	testing.expect_value(t, caller_error, nil)
	if caller_error != nil {return}
	defer mem_virtual.arena_destroy(&caller_arena)

	previous := context.temp_allocator
	defer context.temp_allocator = previous
	caller_allocator := mem_virtual.arena_allocator(&caller_arena)
	context.temp_allocator = caller_allocator
	items := []string{"hello", "hey"}

	first, first_error := match_indices(
		&search,
		items,
		"h",
		Options(string){},
	)
	delete(first)
	testing.expect_value(t, first_error, Search_Error.None)
	caller_data := make([]byte, 4, context.temp_allocator)
	copy(caller_data, []byte{0x12, 0x34, 0x56, 0x78})

	second, second_error := match_indices(
		&search,
		items,
		"he",
		Options(string){},
	)
	delete(second)
	testing.expect_value(t, second_error, Search_Error.None)
	expect_temp_allocator_identity(t, caller_allocator)
	testing.expect_value(t, caller_data[0], byte(0x12))
	testing.expect_value(t, caller_data[3], byte(0x78))
	testing.expect_value(t, search.scratch.total_used, uint(0))
}

@(test)
hundred_thousand_items_reuse_scratch_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := make([]string, 100_000)
	defer delete(items)
	for &item in items {item = "record"}
	input_address := raw_data(items)

	first, first_error := match_indices(
		&search,
		items,
		"z",
		Options(string){},
	)
	defer delete(first)
	testing.expect_value(t, first_error, Search_Error.None)
	committed_after_first := search.scratch.curr_block.committed
	second, second_error := match_indices(
		&search,
		items,
		"z",
		Options(string){},
	)
	defer delete(second)
	testing.expect_value(t, second_error, Search_Error.None)

	testing.expect_value(t, len(first), 0)
	testing.expect_value(t, len(second), 0)
	testing.expect(t, raw_data(items) == input_address)
	testing.expect_value(t, search.scratch.total_used, uint(0))
	testing.expect_value(
		t,
		search.scratch.curr_block.committed,
		committed_after_first,
	)
}
