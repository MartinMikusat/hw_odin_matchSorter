package match_sorter

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import mem_virtual "core:mem/virtual"

MATCH_SORTER_BENCHMARK :: #config(MATCH_SORTER_BENCHMARK, false)

Ranking :: f64

NO_MATCH            :: Ranking(0)
MATCHES              :: Ranking(1)
ACRONYM              :: Ranking(2)
CONTAINS             :: Ranking(3)
WORD_STARTS_WITH     :: Ranking(4)
STARTS_WITH          :: Ranking(5)
EQUAL                :: Ranking(6)
CASE_SENSITIVE_EQUAL :: Ranking(7)

Search_Error :: enum {
	None,
	Invalid_UTF8,
}

Search_Context :: struct {
	scratch:     mem_virtual.Arena,
	initialized: bool,
}

Prepared_Query :: struct {
	original:    string,
	lower:       string,
	lower_runes: []rune,
}

Key_Attributes :: struct {
	has_threshold: bool,
	threshold:     Ranking,
	has_max:       bool,
	max_ranking:   Ranking,
	has_min:       bool,
	min_ranking:   Ranking,
}

Ranking_Info :: struct {
	ranked_value:      string,
	rank:              Ranking,
	key_index:         int,
	has_key_threshold: bool,
	key_threshold:     Ranking,
}

Ranked_Index :: struct {
	item_index:         int,
	ranked_value:       string,
	rank:               Ranking,
	key_index:          int,
	has_key_threshold: bool,
	key_threshold:     Ranking,
}

Ranked_Result :: struct {
	items:     []Ranked_Index,
	allocator: mem.Allocator,
}

Extracted_Values_Kind :: enum {
	None,
	Single,
	Many,
}

Extracted_Values :: struct {
	kind:   Extracted_Values_Kind,
	single: string,
	many:   []string,
}

Key :: struct($T: typeid) {
	getter:     proc(item: ^T) -> Extracted_Values,
	attributes: Key_Attributes,
}

Options :: struct($T: typeid) {
	keys:          []Key(T),
	has_threshold: bool,
	threshold:     Ranking,
	base_sort:     proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
	sorter:        proc(items: []T, ranked: ^[dynamic]Ranked_Index),
}

search_context_init :: proc(
	search: ^Search_Context,
	reserve_size := uint(mem.Gigabyte),
	commit_size := uint(mem.Megabyte),
) -> mem.Allocator_Error {
	if search.initialized {return nil}
	err := mem_virtual.arena_init_static(&search.scratch, reserve_size, commit_size)
	if err == nil {search.initialized = true}
	return err
}

search_context_destroy :: proc(search: ^Search_Context) {
	if search == nil || !search.initialized {return}
	mem_virtual.arena_destroy(&search.scratch)
	search^ = {}
}

search_scratch_allocator :: proc(search: ^Search_Context) -> mem.Allocator {
	assert(search != nil && search.initialized, "Search_Context must be initialized")
	return mem_virtual.arena_allocator(&search.scratch)
}

search_temp_allocator_guard_end :: proc(previous: mem.Allocator) {
	context.temp_allocator = previous
}

@(deferred_out=search_temp_allocator_guard_end)
search_temp_allocator_guard :: proc(scratch: mem.Allocator) -> mem.Allocator {
	previous := context.temp_allocator
	context.temp_allocator = scratch
	return previous
}

valid_utf8 :: proc(value: string) -> bool {
	offset := 0
	for offset < len(value) {
		r, width := utf8.decode_rune(value[offset:])
		if r == utf8.RUNE_ERROR && width == 1 {return false}
		offset += width
	}
	return true
}

single_value :: proc(value: string) -> Extracted_Values {
	return {kind = .Single, single = value}
}

many_values :: proc(values: []string) -> Extracted_Values {
	return {kind = .Many, many = values}
}

ranked_result_destroy :: proc(result: ^Ranked_Result) {
	if result == nil || result.items == nil {return}
	for item in result.items {delete(item.ranked_value, result.allocator)}
	delete(result.items, result.allocator)
	result^ = {}
}

match_indices :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Options(T),
	allocator := context.allocator,
) -> ([]int, Search_Error) {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	search_temp_allocator_guard(scratch)
	ranked, search_error := rank_items(items, query, options, scratch)
	if search_error != .None {return nil, search_error}
	result := make([]int, len(ranked), allocator)
	for candidate, index in ranked {result[index] = candidate.item_index}
	return result, .None
}

match_indices_into :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Options(T),
	result: ^[dynamic]int,
) -> Search_Error {
	assert(result != nil, "Result buffer must not be nil")
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	search_temp_allocator_guard(scratch)
	ranked, search_error := rank_items(items, query, options, scratch)
	if search_error != .None {return search_error}
	clear(result)
	for candidate in ranked {append(result, candidate.item_index)}
	return .None
}

match_items :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Options(T),
	allocator := context.allocator,
) -> ([]T, Search_Error) {
	indices, search_error := match_indices(search, items, query, options, allocator)
	if search_error != .None {return nil, search_error}
	defer delete(indices, allocator)
	result := make([]T, len(indices), allocator)
	for item_index, index in indices {result[index] = items[item_index]}
	return result, .None
}

match_with_rank_info :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Options(T),
	allocator := context.allocator,
) -> (Ranked_Result, Search_Error) {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	search_temp_allocator_guard(scratch)
	ranked, search_error := rank_items(items, query, options, scratch)
	if search_error != .None {return {}, search_error}
	result := Ranked_Result{
		items = make([]Ranked_Index, len(ranked), allocator),
		allocator = allocator,
	}
	for candidate, index in ranked {
		result.items[index] = candidate
		result.items[index].ranked_value =
			strings.clone(candidate.ranked_value, allocator)
	}
	return result, .None
}

rank_items :: proc(
	items: []$T,
	query: string,
	options: Options(T),
	allocator: mem.Allocator,
) -> ([]Ranked_Index, Search_Error) {
	if !valid_utf8(query) {return nil, .Invalid_UTF8}
	prepared_query := prepare_query(query, context.temp_allocator)
	ranked := make([dynamic]Ranked_Index, 0, len(items), allocator)
	threshold := MATCHES
	if options.has_threshold {threshold = options.threshold}

	for &item, item_index in items {
		best := Ranking_Info{rank = NO_MATCH, key_index = -1}
		if len(options.keys) == 0 {
			when T == string {
				if !valid_utf8(item) {return nil, .Invalid_UTF8}
				best.ranked_value = item
				best.rank = get_match_ranking_prepared(item, &prepared_query)
			}
		} else {
			flattened_key_index := 0
			for key in options.keys {
				if key.getter == nil {continue}
				extracted := key.getter(&item)
				#partial switch extracted.kind {
				case .None:
					continue
				case .Single:
					if !valid_utf8(extracted.single) {
						return nil, .Invalid_UTF8
					}
					consider_ranking(
						extracted.single,
						&prepared_query,
						key.attributes,
						flattened_key_index,
						&best,
					)
					flattened_key_index += 1
				case .Many:
					for value in extracted.many {
						if !valid_utf8(value) {return nil, .Invalid_UTF8}
						consider_ranking(
							value,
							&prepared_query,
							key.attributes,
							flattened_key_index,
							&best,
						)
						flattened_key_index += 1
					}
				}
			}
		}

		item_threshold := threshold
		if best.has_key_threshold {item_threshold = best.key_threshold}
		if best.rank >= item_threshold {
			append(&ranked, Ranked_Index{
				item_index = item_index,
				ranked_value = best.ranked_value,
				rank = best.rank,
				key_index = best.key_index,
				has_key_threshold = best.has_key_threshold,
				key_threshold = best.key_threshold,
			})
		}
	}

	if options.sorter != nil {
		options.sorter(items, &ranked)
	} else {
		stable_sort(ranked[:], items, options.base_sort, allocator)
	}
	return ranked[:], .None
}

consider_ranking :: proc(
	value: string,
	query: ^Prepared_Query,
	attributes: Key_Attributes,
	key_index: int,
	best: ^Ranking_Info,
) {
	rank := get_match_ranking_prepared(value, query)
	if attributes.has_min && rank < attributes.min_ranking && rank >= MATCHES {
		rank = attributes.min_ranking
	} else if attributes.has_max && rank > attributes.max_ranking {
		rank = attributes.max_ranking
	}
	if rank > best.rank {
		best^ = {
			ranked_value = value,
			rank = rank,
			key_index = key_index,
			has_key_threshold = attributes.has_threshold,
			key_threshold = attributes.threshold,
		}
	}
}

stable_sort :: proc(
	ranked: []Ranked_Index,
	items: []$T,
	base_sort: proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
	allocator: mem.Allocator,
) {
	if len(ranked) < 2 {return}
	buffer := make([]Ranked_Index, len(ranked), allocator)
	source := ranked
	destination := buffer
	width := 1
	for width < len(ranked) {
		for start := 0; start < len(ranked); start += width*2 {
			middle := min(start+width, len(ranked))
			end := min(start+width*2, len(ranked))
			left, right, output := start, middle, start
			for left < middle && right < end {
				comparison := compare_ranked(
					&source[left],
					&source[right],
					items,
					base_sort,
				)
				if comparison <= 0 {
					destination[output] = source[left]
					left += 1
				} else {
					destination[output] = source[right]
					right += 1
				}
				output += 1
			}
			for left < middle {
				destination[output] = source[left]
				left += 1
				output += 1
			}
			for right < end {
				destination[output] = source[right]
				right += 1
				output += 1
			}
		}
		source, destination = destination, source
		width *= 2
	}
	if raw_data(source) != raw_data(ranked) {copy(ranked, source)}
}

compare_ranked :: proc(
	a, b: ^Ranked_Index,
	items: []$T,
	base_sort: proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
) -> int {
	if a.rank != b.rank {return -1 if a.rank > b.rank else 1}
	if a.key_index != b.key_index {
		return -1 if a.key_index < b.key_index else 1
	}
	if base_sort != nil {
		return base_sort(
			&items[a.item_index],
			&items[b.item_index],
			a,
			b,
		)
	}
	return strings.compare(a.ranked_value, b.ranked_value)
}

get_match_ranking :: proc(test_value, query: string) -> (Ranking, Search_Error) {
	if !valid_utf8(test_value) || !valid_utf8(query) {
		return NO_MATCH, .Invalid_UTF8
	}
	prepared_query := prepare_query(query, context.temp_allocator)
	return get_match_ranking_prepared(test_value, &prepared_query), .None
}

get_match_ranking_prepared :: proc(
	test_value: string,
	query: ^Prepared_Query,
) -> Ranking {
	test_runes := utf8.string_to_runes(test_value, context.temp_allocator)
	if len(query.lower_runes) > len(test_runes) {return NO_MATCH}
	if test_value == query.original {return CASE_SENSITIVE_EQUAL}

	lower_test := strings.to_lower(test_value, context.temp_allocator)
	test_runes = utf8.string_to_runes(lower_test, context.temp_allocator)
	needle_runes := query.lower_runes
	first := index_of_runes(test_runes, needle_runes, 0)
	if len(test_runes) == len(needle_runes) && first == 0 {return EQUAL}
	if first == 0 {return STARTS_WITH}
	if first >= 0 {
		index := first
		for index >= 0 {
			if index > 0 && test_runes[index-1] == ' ' {
				return WORD_STARTS_WITH
			}
			index = index_of_runes(test_runes, needle_runes, index+1)
		}
		return CONTAINS
	}
	if len(needle_runes) == 1 {return NO_MATCH}
	acronym := get_acronym(test_runes, context.temp_allocator)
	if index_of_runes(acronym, needle_runes, 0) >= 0 {return ACRONYM}
	return get_closeness_ranking(test_runes, needle_runes)
}

prepare_query :: proc(
	query: string,
	allocator := context.allocator,
) -> Prepared_Query {
	lower := strings.to_lower(query, allocator)
	return {
		original = query,
		lower = lower,
		lower_runes = utf8.string_to_runes(lower, allocator),
	}
}

index_of_runes :: proc(haystack, needle: []rune, start: int) -> int {
	if len(needle) == 0 {return start if start <= len(haystack) else -1}
	for index := start; index+len(needle) <= len(haystack); index += 1 {
		matches := true
		for value, offset in needle {
			if haystack[index+offset] != value {
				matches = false
				break
			}
		}
		if matches {return index}
	}
	return -1
}

get_acronym :: proc(
	value: []rune,
	allocator := context.allocator,
) -> []rune {
	result := make([dynamic]rune, 0, len(value), allocator)
	previous: rune = ' '
	for current in value {
		previous_delimiter := previous == ' ' || previous == '-'
		current_delimiter := current == ' ' || current == '-'
		if previous_delimiter && !current_delimiter {append(&result, current)}
		previous = current
	}
	return result[:]
}

get_closeness_ranking :: proc(test, needle: []rune) -> Ranking {
	if len(needle) == 0 {return NO_MATCH}
	matched := 0
	find := proc(
		match: rune,
		value: []rune,
		start: int,
		matched: ^int,
	) -> int {
		for index := start; index < len(value); index += 1 {
			if value[index] == match {
				matched^ += 1
				return index+1
			}
		}
		return -1
	}
	first := find(needle[0], test, 0, &matched)
	if first < 0 {return NO_MATCH}
	character := first
	for index := 1; index < len(needle); index += 1 {
		character = find(needle[index], test, character, &matched)
		if character < 0 {return NO_MATCH}
	}
	spread := character-first
	return MATCHES +
		(Ranking(matched)/Ranking(len(needle))) / Ranking(spread)
}
