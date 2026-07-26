package match_sorter

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:unicode/utf16"
import "core:mem"
import "core:math"
import mem_virtual "core:mem/virtual"

Ranking :: f64

NO_MATCH            :: Ranking(0)
MATCHES              :: Ranking(1)
ACRONYM              :: Ranking(2)
CONTAINS             :: Ranking(3)
WORD_STARTS_WITH     :: Ranking(4)
STARTS_WITH          :: Ranking(5)
EQUAL                :: Ranking(6)
CASE_SENSITIVE_EQUAL :: Ranking(7)

Search_Context :: struct {
	scratch:      mem_virtual.Arena,
	initialized:  bool,
	locale:       Mac_Locale,
}

Prepared_Query :: struct {
	prepared:        string,
	prepared_units:  []u16,
	lower:           string,
	lower_units:     []u16,
	keep_diacritics: bool,
}

search_context_init :: proc(
	search: ^Search_Context,
	reserve_size := uint(mem.Gigabyte),
	commit_size := uint(mem.Megabyte),
) -> mem.Allocator_Error {
	if search.initialized { return nil }
	err := mem_virtual.arena_init_static(&search.scratch, reserve_size, commit_size)
	if err == nil {
		search.locale = mac_locale_create_en_us()
		search.initialized = true
	}
	return err
}

search_context_destroy :: proc(search: ^Search_Context) {
	if !search.initialized { return }
	mac_locale_destroy(search.locale)
	mem_virtual.arena_destroy(&search.scratch)
	search^ = {}
}

search_scratch_allocator :: proc(search: ^Search_Context) -> mem.Allocator {
	assert(search != nil && search.initialized, "Search_Context must be initialized")
	return mem_virtual.arena_allocator(&search.scratch)
}

Value_Kind :: enum {Null, Undefined, String, Number, Bool, Array, Object}

Value :: struct {
	kind:   Value_Kind,
	string: string,
	number: f64,
	boolean: bool,
	array:  []Value,
	object: []Field,
}

Field :: struct {name: string, value: Value}

null_value :: proc() -> Value { return {} }
undefined_value :: proc() -> Value { return {kind=.Undefined} }
string_value :: proc(value: string) -> Value { return {kind=.String, string=value} }
number_value :: proc(value: f64) -> Value { return {kind=.Number, number=value} }
bool_value :: proc(value: bool) -> Value { return {kind=.Bool, boolean=value} }
array_value :: proc(value: []Value) -> Value { return {kind=.Array, array=value} }
object_value :: proc(value: []Field) -> Value { return {kind=.Object, object=value} }

Key_Attributes :: struct {
	has_threshold: bool,
	threshold:     Ranking,
	has_max:       bool,
	max_ranking:   Ranking,
	has_min:       bool,
	min_ranking:   Ranking,
}

Value_Getter :: #type proc(item: Value, allocator := context.temp_allocator) -> []string

Key :: struct {
	path:       string,
	getter:     Value_Getter,
	attributes: Key_Attributes,
}

Ranking_Info :: struct {
	ranked_value:      string,
	rank:              Ranking,
	key_index:         int,
	has_key_threshold: bool,
	key_threshold:     Ranking,
}

Ranked_Item :: struct {
	item:              Value,
	ranked_value:      string,
	rank:              Ranking,
	key_index:         int,
	has_key_threshold: bool,
	key_threshold:     Ranking,
	index:              int,
}

Base_Sort :: #type proc(a, b: ^Ranked_Item) -> int
Sorter :: #type proc(items: ^[dynamic]Ranked_Item)

Options :: struct {
	keys:            []Key,
	has_keys:        bool,
	has_threshold:   bool,
	threshold:       Ranking,
	keep_diacritics: bool,
	base_sort:       Base_Sort,
	sorter:          Sorter,
	locale:          Mac_Locale,
}

Ranked_Index :: struct {
	item_index:         int,
	ranked_value:       string,
	rank:               Ranking,
	key_index:          int,
	has_key_threshold: bool,
	key_threshold:      Ranking,
}

Ranked_Result :: struct {
	items:     []Ranked_Index,
	allocator: mem.Allocator,
}

ranked_result_destroy :: proc(result: ^Ranked_Result) {
	if result == nil || result.items == nil { return }
	for item in result.items { delete(item.ranked_value, result.allocator) }
	delete(result.items, result.allocator)
	result^ = {}
}

Extracted_Values_Kind :: enum {None, Single, Many}
Extracted_Values :: struct {
	kind:   Extracted_Values_Kind,
	single: string,
	many:   []string,
}

single_value :: proc(value: string) -> Extracted_Values { return {kind=.Single, single=value} }
many_values :: proc(values: []string) -> Extracted_Values { return {kind=.Many, many=values} }

Typed_Key :: struct($T: typeid) {
	getter:     proc(item: ^T) -> Extracted_Values,
	attributes: Key_Attributes,
}

Typed_Options :: struct($T: typeid) {
	keys:            []Typed_Key(T),
	has_threshold:   bool,
	threshold:       Ranking,
	keep_diacritics: bool,
	base_sort:       proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
	sorter:          proc(items: []T, ranked: ^[dynamic]Ranked_Index),
	locale:          Mac_Locale,
}

match_indices_dynamic :: proc(
	search: ^Search_Context,
	items: []Value,
	query: string,
	options := Options{},
	allocator := context.allocator,
) -> []int {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	context.temp_allocator = scratch
	search_options := options
	search_options.locale = search.locale
	ranked := match_sorter_with_rank_info(items, query, search_options, scratch)
	result := make([]int, len(ranked), allocator)
	for candidate, index in ranked { result[index] = candidate.index }
	return result
}

match_items_dynamic :: proc(
	search: ^Search_Context,
	items: []Value,
	query: string,
	options := Options{},
	allocator := context.allocator,
) -> []Value {
	indices := match_indices_dynamic(search, items, query, options, allocator)
	defer delete(indices, allocator)
	result := make([]Value, len(indices), allocator)
	for item_index, index in indices { result[index] = items[item_index] }
	return result
}

match_with_rank_info_dynamic :: proc(
	search: ^Search_Context,
	items: []Value,
	query: string,
	options := Options{},
	allocator := context.allocator,
) -> Ranked_Result {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	context.temp_allocator = scratch
	search_options := options
	search_options.locale = search.locale
	ranked := match_sorter_with_rank_info(items, query, search_options, scratch)
	result := Ranked_Result{items=make([]Ranked_Index, len(ranked), allocator), allocator=allocator}
	for candidate, index in ranked {
		result.items[index] = {
			candidate.index,
			strings.clone(candidate.ranked_value, allocator),
			candidate.rank,
			candidate.key_index,
			candidate.has_key_threshold,
			candidate.key_threshold,
		}
	}
	return result
}

match_indices_typed :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Typed_Options(T),
	allocator := context.allocator,
) -> []int {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	context.temp_allocator = scratch
	search_options := options
	search_options.locale = search.locale
	ranked := rank_typed_items(items, query, search_options, scratch)
	result := make([]int, len(ranked), allocator)
	for candidate, index in ranked { result[index] = candidate.item_index }
	return result
}

match_items_typed :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Typed_Options(T),
	allocator := context.allocator,
) -> []T {
	indices := match_indices_typed(search, items, query, options, allocator)
	defer delete(indices, allocator)
	result := make([]T, len(indices), allocator)
	for item_index, index in indices { result[index] = items[item_index] }
	return result
}

match_with_rank_info_typed :: proc(
	search: ^Search_Context,
	items: []$T,
	query: string,
	options: Typed_Options(T),
	allocator := context.allocator,
) -> Ranked_Result {
	temp := mem_virtual.arena_temp_begin(&search.scratch)
	defer mem_virtual.arena_temp_end(temp)
	scratch := search_scratch_allocator(search)
	context.temp_allocator = scratch
	search_options := options
	search_options.locale = search.locale
	ranked := rank_typed_items(items, query, search_options, scratch)
	result := Ranked_Result{items=make([]Ranked_Index, len(ranked), allocator), allocator=allocator}
	for candidate, index in ranked {
		result.items[index] = candidate
		result.items[index].ranked_value = strings.clone(candidate.ranked_value, allocator)
	}
	return result
}

match_indices :: proc{match_indices_typed, match_indices_dynamic}
match_items :: proc{match_items_typed, match_items_dynamic}
match_with_rank_info :: proc{match_with_rank_info_typed, match_with_rank_info_dynamic}

rank_typed_items :: proc(
	items: []$T,
	query: string,
	options: Typed_Options(T),
	allocator: mem.Allocator,
) -> []Ranked_Index {
	prepared_query := prepare_query(query, options.keep_diacritics, context.temp_allocator)
	ranked := make([dynamic]Ranked_Index, 0, len(items), allocator)
	threshold := MATCHES
	if options.has_threshold { threshold = options.threshold }
	for &item, item_index in items {
		best := Ranking_Info{rank=NO_MATCH, key_index=-1}
		if len(options.keys) == 0 {
			when T == string {
				best.ranked_value = item
				best.rank = get_match_ranking_prepared(item, &prepared_query)
			}
		} else {
			flattened_key_index := 0
			for key in options.keys {
				if key.getter == nil { continue }
				extracted := key.getter(&item)
				values := extracted.many
				if extracted.kind == .Single {
					values = make([]string, 1, allocator)
					values[0] = extracted.single
				} else if extracted.kind == .None {
					continue
				}
				for value in values {
					rank := get_match_ranking_prepared(value, &prepared_query)
					if key.attributes.has_min && rank < key.attributes.min_ranking && rank >= MATCHES {
						rank = key.attributes.min_ranking
					} else if key.attributes.has_max && rank > key.attributes.max_ranking {
						rank = key.attributes.max_ranking
					}
					if rank > best.rank {
						best = {value, rank, flattened_key_index, key.attributes.has_threshold, key.attributes.threshold}
					}
					flattened_key_index += 1
				}
			}
		}
		item_threshold := threshold
		if best.has_key_threshold { item_threshold = best.key_threshold }
		if best.rank >= item_threshold {
			append(&ranked, Ranked_Index{item_index, best.ranked_value, best.rank, best.key_index, best.has_key_threshold, best.key_threshold})
		}
	}
	if options.sorter != nil {
		options.sorter(items, &ranked)
	} else {
		stable_sort_typed(ranked[:], items, options.base_sort, options.locale, allocator)
	}
	return ranked[:]
}

stable_sort_typed :: proc(
	ranked: []Ranked_Index,
	items: []$T,
	base_sort: proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
	locale: Mac_Locale,
	allocator: mem.Allocator,
) {
	if len(ranked) < 2 { return }
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
				comparison := compare_typed_ranked(&source[left], &source[right], items, base_sort, locale)
				if comparison <= 0 { destination[output] = source[left]; left += 1 } else { destination[output] = source[right]; right += 1 }
				output += 1
			}
			for left < middle { destination[output] = source[left]; left += 1; output += 1 }
			for right < end { destination[output] = source[right]; right += 1; output += 1 }
		}
		source, destination = destination, source
		width *= 2
	}
	if raw_data(source) != raw_data(ranked) { copy(ranked, source) }
}

compare_typed_ranked :: proc(
	a, b: ^Ranked_Index,
	items: []$T,
	base_sort: proc(a, b: ^T, a_info, b_info: ^Ranked_Index) -> int,
	locale: Mac_Locale,
) -> int {
	if a.rank != b.rank { return -1 if a.rank > b.rank else 1 }
	if a.key_index != b.key_index { return -1 if a.key_index < b.key_index else 1 }
	if base_sort != nil { return base_sort(&items[a.item_index], &items[b.item_index], a, b) }
	if locale != Mac_Locale(nil) { return mac_compare_strings(a.ranked_value, b.ranked_value, locale) }
	return default_compare_strings(a.ranked_value, b.ranked_value)
}

match_sorter_strings :: proc(items: []string, query: string, options := Options{}, allocator := context.allocator) -> []string {
	values := make([]Value, len(items), context.temp_allocator)
	for item, i in items { values[i] = string_value(item) }
	ranked := match_sorter_with_rank_info(values, query, options, context.temp_allocator)
	result := make([]string, len(ranked), allocator)
	for item, i in ranked { result[i] = item.item.string }
	return result
}

match_sorter :: proc(items: []Value, query: string, options := Options{}, allocator := context.allocator) -> []Value {
	ranked := match_sorter_with_rank_info(items, query, options, context.temp_allocator)
	result := make([]Value, len(ranked), allocator)
	for item, i in ranked { result[i] = item.item }
	return result
}

match_sorter_with_rank_info :: proc(items: []Value, query: string, options := Options{}, allocator := context.allocator) -> []Ranked_Item {
	prepared_query := prepare_query(query, options.keep_diacritics, context.temp_allocator)
	result := make([dynamic]Ranked_Item, 0, len(items), allocator)
	for item, index in items {
		info := get_highest_ranking_prepared(item, &prepared_query, options)
		threshold := MATCHES
		if options.has_threshold { threshold = options.threshold }
		if info.has_key_threshold { threshold = info.key_threshold }
		if info.rank >= threshold {
			append(&result, Ranked_Item{item, info.ranked_value, info.rank, info.key_index, info.has_key_threshold, info.key_threshold, index})
		}
	}
	if options.sorter != nil {
		options.sorter(&result)
	} else {
		insertion_sort(result[:], options.base_sort, options.locale)
	}
	return result[:]
}

get_highest_ranking :: proc(item: Value, query: string, options: Options) -> Ranking_Info {
	prepared_query := prepare_query(query, options.keep_diacritics, context.temp_allocator)
	return get_highest_ranking_prepared(item, &prepared_query, options)
}

get_highest_ranking_prepared :: proc(
	item: Value,
	query: ^Prepared_Query,
	options: Options,
) -> Ranking_Info {
	if !options.has_keys {
		value := value_to_string(item, context.temp_allocator)
		return {value, get_match_ranking_prepared(value, query), -1, false, 0}
	}
	best := Ranking_Info{value_to_string(item, context.temp_allocator), NO_MATCH, -1, false, 0}
	value_index := 0
	for key in options.keys {
		values := get_item_values(item, key, context.temp_allocator)
		for value in values {
			rank := get_match_ranking_prepared(value, query)
			if key.attributes.has_min && rank < key.attributes.min_ranking && rank >= MATCHES {
				rank = key.attributes.min_ranking
			} else if key.attributes.has_max && rank > key.attributes.max_ranking {
				rank = key.attributes.max_ranking
			}
			if rank > best.rank {
				best = {value, rank, value_index, key.attributes.has_threshold, key.attributes.threshold}
			}
			value_index += 1
		}
	}
	return best
}

get_match_ranking :: proc(test_value, query: string, keep_diacritics := false) -> Ranking {
	prepared_query := prepare_query(query, keep_diacritics, context.temp_allocator)
	return get_match_ranking_prepared(test_value, &prepared_query)
}

get_match_ranking_prepared :: proc(
	test_value: string,
	query: ^Prepared_Query,
) -> Ranking {
	test := prepare_value(test_value, query.keep_diacritics, context.temp_allocator)
	test_units := string_to_utf16(test, context.temp_allocator)
	if len(query.prepared_units) > len(test_units) { return NO_MATCH }
	if test == query.prepared { return CASE_SENSITIVE_EQUAL }
	lower_test := strings.to_lower(test, context.temp_allocator)
	test_units = string_to_utf16(lower_test, context.temp_allocator)
	needle_units := query.lower_units
	first := index_of_units(test_units, needle_units, 0)
	if len(test_units) == len(needle_units) && first == 0 { return EQUAL }
	if first == 0 { return STARTS_WITH }
	if first >= 0 {
		index := first
		for index >= 0 {
			if index > 0 && test_units[index-1] == ' ' { return WORD_STARTS_WITH }
			index = index_of_units(test_units, needle_units, index+1)
		}
		return CONTAINS
	}
	if len(needle_units) == 1 { return NO_MATCH }
	acronym := get_acronym(test_units, context.temp_allocator)
	if index_of_units(acronym, needle_units, 0) >= 0 { return ACRONYM }
	return get_closeness_ranking(test_units, needle_units)
}

get_acronym :: proc(value: []u16, allocator := context.allocator) -> []u16 {
	result := make([dynamic]u16, 0, len(value), allocator)
	previous: u16 = ' '
	for current in value {
		previous_delimiter := previous == ' ' || previous == '-'
		current_delimiter := current == ' ' || current == '-'
		if previous_delimiter && !current_delimiter { append(&result, current) }
		previous = current
	}
	return result[:]
}

get_closeness_ranking :: proc(test, needle: []u16) -> Ranking {
	if len(needle) == 0 { return NO_MATCH }
	matched := 0
	find := proc(match: u16, value: []u16, start: int, matched: ^int) -> int {
		for index := start; index < len(value); index += 1 {
			if value[index] == match { matched^ += 1; return index+1 }
		}
		return -1
	}
	first := find(needle[0], test, 0, &matched)
	if first < 0 { return NO_MATCH }
	character := first
	for index := 1; index < len(needle); index += 1 {
		character = find(needle[index], test, character, &matched)
		if character < 0 { return NO_MATCH }
	}
	spread := character-first
	return MATCHES + (Ranking(matched)/Ranking(len(needle))) / Ranking(spread)
}

get_item_values :: proc(item: Value, key: Key, allocator := context.allocator) -> []string {
	if key.getter != nil { return key.getter(item, allocator) }
	if key.path == "" { return nil }
	if item.kind == .Object {
		if value, ok := object_get(item, key.path); ok { return flatten_strings(value, allocator) }
	}
	if strings.contains(key.path, ".") { return get_nested_values(item, key.path, allocator) }
	return nil
}

get_nested_values :: proc(item: Value, path: string, allocator := context.allocator) -> []string {
	parts := strings.split(path, ".", context.temp_allocator)
	values := make([dynamic]Value, 0, 4, context.temp_allocator)
	append(&values, item)
	for part in parts {
		next := make([dynamic]Value, 0, 4, context.temp_allocator)
		for value in values {
			if part == "*" && value.kind == .Array {
				append(&next, ..value.array)
			} else if value.kind == .Object {
				if nested, ok := object_get(value, part); ok { append(&next, nested) }
			} else if value.kind == .Array {
				if index, ok := strconv.parse_int(part); ok && index >= 0 && index < len(value.array) { append(&next, value.array[index]) }
			}
		}
		values = next
	}
	result := make([dynamic]string, 0, len(values), allocator)
	for value in values { append(&result, ..flatten_strings(value, allocator)) }
	return result[:]
}

flatten_strings :: proc(value: Value, allocator := context.allocator) -> []string {
	if value.kind == .Null { return nil }
	if value.kind == .Array {
		result := make([dynamic]string, 0, len(value.array), allocator)
		for child in value.array {
			if child.kind != .Null { append(&result, value_to_string(child, allocator)) }
		}
		return result[:]
	}
	result := make([]string, 1, allocator)
	result[0] = value_to_string(value, allocator)
	return result
}

object_get :: proc(item: Value, name: string) -> (Value, bool) {
	if item.kind != .Object { return {}, false }
	for field in item.object { if field.name == name { return field.value, true } }
	return {}, false
}

value_to_string :: proc(value: Value, allocator := context.allocator) -> string {
	#partial switch value.kind {
	case .String: return value.string
	case .Number:
		if value.number == 0 { return "0" }
		if math.is_nan(value.number) { return "NaN" }
		if math.is_inf(value.number, 1) { return "Infinity" }
		if math.is_inf(value.number, -1) { return "-Infinity" }
		builder: strings.Builder
		strings.builder_init(&builder, allocator)
		strings.write_float(&builder, value.number, 'g', -1, 64)
		return strings.to_string(builder)
	case .Bool: return "true" if value.boolean else "false"
	case .Null: return "null"
	case .Undefined: return "undefined"
	case .Array:
		builder: strings.Builder
		strings.builder_init(&builder, allocator)
		for child, index in value.array {
			if index > 0 { strings.write_byte(&builder, ',') }
			if child.kind == .Null || child.kind == .Undefined { continue }
			child_string := value_to_string(child, context.temp_allocator)
			strings.write_string(&builder, child_string)
		}
		return strings.to_string(builder)
	case .Object: return "[object Object]"
	}
	return ""
}

default_base_sort :: proc(a, b: ^Ranked_Item) -> int {
	return default_compare_strings(a.ranked_value, b.ranked_value)
}

default_compare_strings :: proc(a, b: string) -> int {
	a_prepared := prepare_value(a, false, context.temp_allocator)
	b_prepared := prepare_value(b, false, context.temp_allocator)
	a_lower := strings.to_lower(a_prepared, context.temp_allocator)
	b_lower := strings.to_lower(b_prepared, context.temp_allocator)
	a_value := utf8.string_to_runes(a_lower, context.temp_allocator)
	b_value := utf8.string_to_runes(b_lower, context.temp_allocator)
	count := min(len(a_value), len(b_value))
	for index in 0..<count {
		a_weight := collation_weight(a_value[index])
		b_weight := collation_weight(b_value[index])
		if a_weight < b_weight { return -1 }
		if a_weight > b_weight { return 1 }
	}
	if len(a_value) < len(b_value) { return -1 }
	if len(a_value) > len(b_value) { return 1 }
	return 0
}

collation_weight :: proc(r: rune) -> int {
	switch r {
	case ' ': return 1
	case '_': return 2
	case '-': return 3
	case '\'': return 4
	}
	return int(r)+16
}

insertion_sort :: proc(items: []Ranked_Item, base_sort: Base_Sort, locale: Mac_Locale) {
	compare := base_sort
	if len(items) < 2 { return }
	buffer := make([]Ranked_Item, len(items), context.temp_allocator)
	source := items
	destination := buffer
	width := 1
	for width < len(items) {
		for start := 0; start < len(items); start += width*2 {
			middle := min(start+width, len(items))
			end := min(start+width*2, len(items))
			left, right, output := start, middle, start
			for left < middle && right < end {
				comparison := compare_ranked(&source[left], &source[right], compare, locale)
				if comparison <= 0 { destination[output] = source[left]; left += 1 } else { destination[output] = source[right]; right += 1 }
				output += 1
			}
			for left < middle { destination[output] = source[left]; left += 1; output += 1 }
			for right < end { destination[output] = source[right]; right += 1; output += 1 }
		}
		source, destination = destination, source
		width *= 2
	}
	if raw_data(source) != raw_data(items) { copy(items, source) }
}

compare_ranked :: proc(a, b: ^Ranked_Item, base_sort: Base_Sort, locale: Mac_Locale) -> int {
	if a.rank != b.rank { return -1 if a.rank > b.rank else 1 }
	if a.key_index != b.key_index { return -1 if a.key_index < b.key_index else 1 }
	if base_sort != nil { return base_sort(a, b) }
	if locale != Mac_Locale(nil) { return mac_compare_strings(a.ranked_value, b.ranked_value, locale) }
	return default_base_sort(a, b)
}

index_of_units :: proc(haystack, needle: []u16, start: int) -> int {
	if len(needle) == 0 { return start if start <= len(haystack) else -1 }
	for i := start; i+len(needle) <= len(haystack); i += 1 {
		matches := true
		for unit, j in needle { if haystack[i+j] != unit { matches = false; break } }
		if matches { return i }
	}
	return -1
}

string_to_utf16 :: proc(value: string, allocator := context.allocator) -> []u16 {
	buffer := make([]u16, len(value), allocator)
	count := utf16.encode_string(buffer, value)
	return buffer[:count]
}

prepare_query :: proc(
	query: string,
	keep_diacritics: bool,
	allocator := context.allocator,
) -> Prepared_Query {
	prepared := prepare_value(query, keep_diacritics, allocator)
	lower := strings.to_lower(prepared, allocator)
	return Prepared_Query{
		prepared = prepared,
		prepared_units = string_to_utf16(prepared, allocator),
		lower = lower,
		lower_units = string_to_utf16(lower, allocator),
		keep_diacritics = keep_diacritics,
	}
}

prepare_value :: proc(value: string, keep_diacritics: bool, allocator := context.allocator) -> string {
	if keep_diacritics { return value }
	input := utf8.string_to_runes(value, context.temp_allocator)
	output := make([dynamic]rune, 0, len(input), context.temp_allocator)
	for index := 0; index < len(input); index += 1 {
		r := input[index]
		if index+1 < len(input) && is_remove_accents_pair(r, input[index+1]) {
			append(&output, remove_accent_pair_base(r))
			index += 1
			continue
		}
		switch r {
		case 'Æ','Ǽ': append(&output, 'A', 'E')
		case 'æ','ǽ': append(&output, 'a', 'e')
		case 'Ĳ': append(&output, 'I', 'J')
		case 'ĳ': append(&output, 'i', 'j')
		case 'Œ': append(&output, 'O', 'E')
		case 'œ': append(&output, 'o', 'e')
		case 'Þ': append(&output, 'T', 'H')
		case 'þ': append(&output, 't', 'h')
		case: append(&output, remove_accent(r))
		}
	}
	return utf8.runes_to_string(output[:], allocator)
}

is_remove_accents_pair :: proc(base, mark: rune) -> bool {
	switch mark {
	case 0x0306: return base == 'C' || base == 'c' || base == 'K' || base == 'k' || base == 'M' || base == 'm' || base == 'N' || base == 'n' || base == 'P' || base == 'p' || base == 'R' || base == 'r' || base == 'T' || base == 't' || base == 'V' || base == 'v' || base == 'X' || base == 'x' || base == 'Y' || base == 'y'
	case 0x0301: return base == 'X' || base == 'x'
	case 0x030b: return base == 'A' || base == 'a' || base == 'E' || base == 'e' || base == 'I' || base == 'i'
	case 0x030c: return base == 'B' || base == 'b' || base == 'Ê' || base == 'ê' || base == 'F' || base == 'f' || base == 'J' || base == 'j' || base == 'M' || base == 'm' || base == 'P' || base == 'p' || base == 'Q' || base == 'q' || base == 'V' || base == 'v' || base == 'W' || base == 'w' || base == 'X' || base == 'x' || base == 'Y' || base == 'y'
	case 0x0323: return base == 'Č' || base == 'č'
	case 0x0329: return base == 'Ř' || base == 'ř'
	case 0x0327: return base == 'A' || base == 'a' || base == 'B' || base == 'b' || base == 'Ɛ' || base == 'ɛ' || base == 'H' || base == 'h' || base == 'I' || base == 'i' || base == 'Ɨ' || base == 'ɨ' || base == 'M' || base == 'm' || base == 'O' || base == 'o' || base == 'Q' || base == 'q' || base == 'U' || base == 'u' || base == 'X' || base == 'x' || base == 'Z' || base == 'z'
	}
	return false
}

remove_accent_pair_base :: proc(base: rune) -> rune {
	switch base {
	case 'Ɛ': return 'E'; case 'ɛ': return 'e'
	case 'Ɨ': return 'I'; case 'ɨ': return 'i'
	}
	return remove_accent(base)
}

remove_accent :: proc(r: rune) -> rune {
	switch r {
	case 'À','Á','Â','Ã','Ä','Å','Ấ','Ắ','Ẳ','Ẵ','Ặ','Ầ','Ằ','Ȃ','Ả','Ạ','Ẩ','Ẫ','Ậ','Ā','Ă','Ą','Ǎ','Ǻ','Ȁ': return 'A'
	case 'à','á','â','ã','ä','å','ấ','ắ','ẳ','ẵ','ặ','ầ','ằ','ȃ','ả','ạ','ẩ','ẫ','ậ','ā','ă','ą','ǎ','ǻ','ȁ': return 'a'
	case 'Ç','Ḉ','Ć','Ĉ','Ċ','Č': return 'C'; case 'ç','ḉ','ć','ĉ','ċ','č': return 'c'
	case 'Ð','Ď','Đ','Ḑ': return 'D'; case 'ð','ď','đ','ḑ': return 'd'
	case 'È','É','Ê','Ë','Ế','Ḗ','Ề','Ḕ','Ḝ','Ȇ','Ẻ','Ẽ','Ẹ','Ể','Ễ','Ệ','Ē','Ĕ','Ė','Ę','Ě','Ȩ','Ȅ': return 'E'
	case 'è','é','ê','ë','ế','ḗ','ề','ḕ','ḝ','ȇ','ẻ','ẽ','ẹ','ể','ễ','ệ','ē','ĕ','ė','ę','ě','ȩ','ȅ': return 'e'
	case 'Ĝ','Ǵ','Ğ','Ġ','Ģ','Ǧ': return 'G'; case 'ĝ','ǵ','ğ','ġ','ģ','ǧ': return 'g'
	case 'Ĥ','Ħ','Ḫ','Ḩ','Ȟ': return 'H'; case 'ĥ','ħ','ḫ','ḩ','ȟ': return 'h'
	case 'Ì','Í','Î','Ï','Ḯ','Ȋ','Ỉ','Ị','Ĩ','Ī','Ĭ','Į','İ','Ǐ','Ȉ': return 'I'
	case 'ì','í','î','ï','ḯ','ȋ','ỉ','ị','ĩ','ī','ĭ','į','ı','ǐ','ȉ': return 'i'
	case 'Ĵ': return 'J'; case 'ĵ','ǰ': return 'j'
	case 'Ķ','Ḱ','Ǩ': return 'K'; case 'ķ','ḱ','ǩ': return 'k'
	case 'Ĺ','Ļ','Ľ','Ŀ': return 'L'; case 'Ł','ĺ','ļ','ľ','ŀ','ł': return 'l'
	case 'Ḿ': return 'M'; case 'ḿ': return 'm'
	case 'Ñ','Ń','Ņ','Ň','Ǹ': return 'N'; case 'ñ','ń','ņ','ň','ŉ','ǹ': return 'n'
	case 'Ò','Ó','Ô','Õ','Ö','Ø','Ố','Ṍ','Ṓ','Ȏ','Ỏ','Ọ','Ổ','Ỗ','Ộ','Ờ','Ở','Ỡ','Ớ','Ợ','Ō','Ŏ','Ő','Ơ','Ǒ','Ǿ','Ồ','Ṑ','Ȍ': return 'O'
	case 'ò','ó','ô','õ','ö','ø','ố','ṍ','ṓ','ȏ','ỏ','ọ','ổ','ỗ','ộ','ờ','ở','ỡ','ớ','ợ','ō','ŏ','ő','ơ','ǒ','ǿ','ồ','ṑ','ȍ': return 'o'
	case 'Ṕ': return 'P'; case 'ṕ': return 'p'
	case 'Ŕ','Ŗ','Ř','Ȓ','Ȑ': return 'R'; case 'ŕ','ŗ','ř','ȓ','ȑ': return 'r'
	case 'Ś','Ŝ','Ş','Ș','Š','Ṥ','Ṧ': return 'S'; case 'ś','ŝ','ș','ş','š','ṥ','ṧ','ſ': return 's'
	case 'Ţ','Ț','Ť','Ŧ': return 'T'; case 'ţ','ț','ť','ŧ': return 't'
	case 'Ù','Ú','Û','Ü','Ủ','Ụ','Ử','Ữ','Ự','Ũ','Ū','Ŭ','Ů','Ű','Ų','Ȗ','Ư','Ǔ','Ǖ','Ǘ','Ǚ','Ǜ','Ứ','Ṹ','Ừ','Ȕ': return 'U'
	case 'ù','ú','û','ü','ủ','ụ','ử','ữ','ự','ũ','ū','ŭ','ů','ű','ų','ȗ','ư','ǔ','ǖ','ǘ','ǚ','ǜ','ứ','ṹ','ừ','ȕ': return 'u'
	case 'Ŵ','Ẃ','Ẁ': return 'W'; case 'ŵ','ẃ','ẁ': return 'w'
	case 'Ý','Ÿ','Ŷ','Ỳ': return 'Y'; case 'ý','ÿ','ŷ','ỳ': return 'y'
	case 'Ź','Ż','Ž': return 'Z'; case 'ź','ż','ž': return 'z'
	case 'ƒ': return 'f'; case 'Ѓ': return 'Г'; case 'ѓ': return 'г'; case 'Ќ': return 'К'; case 'ќ': return 'к'; case 'Й': return 'И'; case 'й': return 'и'; case 'Ё': return 'Е'; case 'ё': return 'е'
	}
	return r
}
