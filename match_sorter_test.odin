package match_sorter

import "core:testing"
import "core:math"
import "core:mem"
import mem_virtual "core:mem/virtual"

expect_strings :: proc(t: ^testing.T, actual, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) { return }
	for value, index in actual { testing.expect_value(t, value, expected[index]) }
}

expect_temp_allocator_identity :: proc(
	t: ^testing.T,
	expected: mem.Allocator,
) {
	testing.expect(t, context.temp_allocator.procedure == expected.procedure)
	testing.expect(t, context.temp_allocator.data == expected.data)
}

field :: proc(name: string, value: Value) -> Field { return {name, value} }
object :: proc(fields: ..Field) -> Value {
	owned := make([]Field, len(fields), context.temp_allocator)
	copy(owned, fields)
	return object_value(owned)
}
array :: proc(values: ..Value) -> Value {
	owned := make([]Value, len(values), context.temp_allocator)
	copy(owned, values)
	return array_value(owned)
}

object_string :: proc(value: Value, name: string) -> string {
	result, ok := object_get(value, name)
	if !ok { return "" }
	return value_to_string(result)
}

expect_object_field_order :: proc(t: ^testing.T, actual: []Value, field_name: string, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) { return }
	for value, index in actual { testing.expect_value(t, object_string(value, field_name), expected[index]) }
}

@(test)
basic_filter_and_best_order_test :: proc(t: ^testing.T) {
	items := []string{
		"The Tail of Two Cities 1", "tTOtc", "ttotc", "The 1-ttotc-2 container",
		"The Tail of Forty Cities", "The Tail of Two Cities", "kebab-ttotc-case",
		"Word starts with ttotc-first right?", "The Tail of Fifty Cities", "no match",
		"The second 3-ttotc-4 container", "ttotc-starts with",
		"Another word starts with ttotc-second, super!", "ttotc-2nd-starts with", "TTotc",
	}
	actual := match_sorter_strings(items, "ttotc")
	defer delete(actual)
	expect_strings(t, actual, []string{
		"ttotc", "tTOtc", "TTotc", "ttotc-2nd-starts with", "ttotc-starts with",
		"Another word starts with ttotc-second, super!", "Word starts with ttotc-first right?",
		"kebab-ttotc-case", "The 1-ttotc-2 container", "The second 3-ttotc-4 container",
		"The Tail of Two Cities", "The Tail of Two Cities 1", "The Tail of Fifty Cities",
		"The Tail of Forty Cities",
	})
}

@(test)
empty_no_match_and_single_character_test :: proc(t: ^testing.T) {
	actual := match_sorter_strings([]string{"Chakotay", "Charzard"}, "nomatch")
	defer delete(actual)
	testing.expect_value(t, len(actual), 0)
	single := match_sorter_strings([]string{"abc"}, "d")
	defer delete(single)
	testing.expect_value(t, len(single), 0)
}

@(test)
object_keys_multiple_keys_and_zero_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("name", string_value("baz")), field("reverse", string_value("zab"))),
		object(field("name", string_value("bat")), field("reverse", string_value("tab"))),
		object(field("name", string_value("foo")), field("reverse", string_value("oof"))),
		object(field("name", string_value("bag")), field("reverse", string_value("gab"))),
	}
	keys := []Key{{path="name"}, {path="reverse"}}
	actual := match_sorter(items, "ab", Options{keys=keys, has_keys=true})
	defer delete(actual)
	expect_object_field_order(t, actual, "name", []string{"bag", "bat", "baz"})

	ages := []Value{
		object(field("name", string_value("A")), field("age", number_value(0))),
		object(field("name", string_value("B")), field("age", number_value(1))),
	}
	age_results := match_sorter(ages, "0", Options{keys=[]Key{{path="age"}}, has_keys=true})
	defer delete(age_results)
	expect_object_field_order(t, age_results, "name", []string{"A"})
}

@(test)
key_index_precedes_alphabetical_tie_break_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("first", string_value("not")), field("second", string_value("not")), field("third", string_value("match"))),
		object(field("first", string_value("not")), field("second", string_value("not")), field("third", string_value("not")), field("fourth", string_value("match"))),
		object(field("first", string_value("not")), field("second", string_value("match"))),
		object(field("first", string_value("match")), field("second", string_value("not"))),
	}
	keys := []Key{{path="first"}, {path="second"}, {path="third"}, {path="fourth"}}
	actual := match_sorter_with_rank_info(items, "match", Options{keys=keys, has_keys=true})
	defer delete(actual)
	expected := []int{3, 2, 0, 1}
	for value, index in actual { testing.expect_value(t, value.index, expected[index]) }
}

@(test)
nested_numeric_and_wildcard_paths_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("aliases", array(
			object(field("name", object(field("first", string_value("baz"))))),
			object(field("name", object(field("first", string_value("foo"))))),
		))),
		object(field("aliases", array(
			object(field("name", object(field("first", string_value("foo"))))),
			object(field("name", object(field("first", string_value("bat"))))),
		))),
	}
	numeric := match_sorter(items, "ba", Options{keys=[]Key{{path="aliases.0.name.first"}}, has_keys=true})
	defer delete(numeric)
	testing.expect_value(t, len(numeric), 1)
	wildcard := match_sorter(items, "ba", Options{keys=[]Key{{path="aliases.*.name.first"}}, has_keys=true})
	defer delete(wildcard)
	testing.expect_value(t, len(wildcard), 2)
}

underscore_getter :: proc(item: Value, allocator := context.temp_allocator) -> []string {
	name := object_string(item, "name")
	converted := make([]u8, len(name), allocator)
	copy(converted, transmute([]u8)name)
	for &byte in converted { if byte == '_' { byte = ' ' } }
	result := make([]string, 1, allocator)
	result[0] = string(converted)
	return result
}

@(test)
callback_key_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("name", string_value("Janice_Kurtis"))),
		object(field("name", string_value("Fred_Mertz"))),
		object(field("name", string_value("George_Foreman"))),
		object(field("name", string_value("Jen_Smith"))),
	}
	actual := match_sorter(items, "js", Options{keys=[]Key{{getter=underscore_getter}}, has_keys=true})
	defer delete(actual)
	expect_object_field_order(t, actual, "name", []string{"Jen_Smith", "Janice_Kurtis"})
}

@(test)
array_values_and_nested_wildcards_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("favorite", object(field("iceCream", array(string_value("mint"), string_value("chocolate")))))),
		object(field("favorite", object(field("iceCream", array(string_value("candy cane"), string_value("brownie")))))),
		object(field("favorite", object(field("iceCream", array(string_value("birthday cake"), string_value("rocky road"), string_value("strawberry")))))),
	}
	paths := []string{"favorite.iceCream", "favorite.iceCream.*"}
	for path in paths {
		actual := match_sorter_with_rank_info(items, "cc", Options{keys=[]Key{{path=path}}, has_keys=true})
		defer delete(actual)
		testing.expect_value(t, len(actual), 2)
		if len(actual) == 2 {
			testing.expect_value(t, actual[0].index, 1)
			testing.expect_value(t, actual[1].index, 0)
		}
	}
}

@(test)
two_wildcard_levels_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("favorite", object(field("iceCream", array(
			object(field("tastes", array(string_value("vanilla"), string_value("mint")))),
			object(field("tastes", array(string_value("vanilla"), string_value("chocolate")))),
		))))),
		object(field("favorite", object(field("iceCream", array(
			object(field("tastes", array(string_value("vanilla"), string_value("candy cane")))),
			object(field("tastes", array(string_value("vanilla"), string_value("brownie")))),
		))))),
	}
	paths := []string{"favorite.iceCream.*.tastes", "favorite.iceCream.*.tastes.*"}
	for path in paths {
		actual := match_sorter_with_rank_info(items, "cc", Options{keys=[]Key{{path=path}}, has_keys=true})
		defer delete(actual)
		testing.expect_value(t, len(actual), 2)
		if len(actual) == 2 { testing.expect_value(t, actual[0].index, 1) }
	}
}

@(test)
min_max_and_key_threshold_test :: proc(t: ^testing.T) {
	teas := []Value{
		object(field("tea", string_value("Earl Grey")), field("alias", string_value("A"))),
		object(field("tea", string_value("Assam")), field("alias", string_value("B"))),
		object(field("tea", string_value("Black")), field("alias", string_value("C"))),
	}
	keys := []Key{{path="tea"}, {path="alias", attributes=Key_Attributes{has_max=true, max_ranking=STARTS_WITH}}}
	actual := match_sorter(teas, "A", Options{keys=keys, has_keys=true})
	defer delete(actual)
	expect_object_field_order(t, actual, "tea", []string{"Assam", "Earl Grey", "Black"})
	min_items := []Value{
		object(field("tea", string_value("Milk")), field("alias", string_value("moo"))),
		object(field("tea", string_value("Oolong")), field("alias", string_value("B"))),
		object(field("tea", string_value("Green")), field("alias", string_value("C"))),
	}
	min_keys := []Key{{path="tea"}, {path="alias", attributes=Key_Attributes{has_min=true, min_ranking=EQUAL}}}
	min_result := match_sorter(min_items, "oo", Options{keys=min_keys, has_keys=true})
	defer delete(min_result)
	expect_object_field_order(t, min_result, "tea", []string{"Milk", "Oolong"})

	threshold_items := []Value{
		object(field("name", string_value("Fred")), field("color", string_value("Orange"))),
		object(field("name", string_value("Jen")), field("color", string_value("Red"))),
	}
	threshold_keys := []Key{
		{path="name", attributes=Key_Attributes{has_threshold=true, threshold=STARTS_WITH}},
		{path="color"},
	}
	threshold_result := match_sorter(threshold_items, "ed", Options{keys=threshold_keys, has_keys=true})
	defer delete(threshold_result)
	expect_object_field_order(t, threshold_result, "name", []string{"Jen"})
	lower_keys := []Key{{path="name"}, {path="color", attributes=Key_Attributes{has_threshold=true, threshold=CONTAINS}}}
	lower_result := match_sorter(threshold_items, "ed", Options{keys=lower_keys, has_keys=true, has_threshold=true, threshold=STARTS_WITH})
	defer delete(lower_result)
	expect_object_field_order(t, lower_result, "name", []string{"Jen"})
}

@(test)
global_thresholds_test :: proc(t: ^testing.T) {
	items := []string{"google", "airbnb", "apple", "apply", "app", "aPp", "App"}
	equal := match_sorter_strings(items, "app", Options{has_threshold=true, threshold=EQUAL})
	defer delete(equal)
	expect_strings(t, equal, []string{"app", "aPp", "App"})
	case_equal := match_sorter_strings(items, "app", Options{has_threshold=true, threshold=CASE_SENSITIVE_EQUAL})
	defer delete(case_equal)
	expect_strings(t, case_equal, []string{"app"})
	word := match_sorter_strings([]string{"fiji apple", "google", "app", "crabapple", "apple", "apply", "snappy apple"}, "app", Options{has_threshold=true, threshold=WORD_STARTS_WITH})
	defer delete(word)
	expect_strings(t, word, []string{"app", "apple", "apply", "fiji apple", "snappy apple"})
}

@(test)
diacritics_closeness_and_unicode_case_test :: proc(t: ^testing.T) {
	items := []string{"jalapeño", "à la carte", "café", "papier-mâché", "à la mode"}
	ignored := match_sorter_strings(items, "aa")
	defer delete(ignored)
	expect_strings(t, ignored, []string{"jalapeño", "à la carte", "à la mode", "papier-mâché"})
	kept := match_sorter_strings(items, "aa", Options{keep_diacritics=true})
	defer delete(kept)
	expect_strings(t, kept, []string{"jalapeño", "à la carte"})
	close := match_sorter_strings([]string{"Antigua and Barbuda", "India", "Bosnia and Herzegovina", "Indonesia"}, "Ina")
	defer delete(close)
	expect_strings(t, close, []string{"Bosnia and Herzegovina", "India", "Indonesia", "Antigua and Barbuda"})
	cyrillic := match_sorter_strings([]string{"Привет", "Лед"}, "л")
	defer delete(cyrillic)
	expect_strings(t, cyrillic, []string{"Лед"})
}

Prepared_Query_Test_Case :: struct {
	value:            string,
	query:            string,
	keep_diacritics:  bool,
	expected:         Ranking,
}

@(test)
prepared_query_scoring_parity_test :: proc(t: ^testing.T) {
	cases := []Prepared_Query_Test_Case{
		{value="Ada", query="Ada", expected=CASE_SENSITIVE_EQUAL},
		{value="Ada", query="ada", expected=EQUAL},
		{value="Ada Lovelace", query="ada", expected=STARTS_WITH},
		{value="The Ada", query="ada", expected=WORD_STARTS_WITH},
		{value="Grenada", query="ada", expected=CONTAINS},
		{value="Amazing Grace", query="ag", expected=ACRONYM},
		{value="café", query="cafe", expected=CASE_SENSITIVE_EQUAL},
		{value="café", query="cafe", keep_diacritics=true, expected=NO_MATCH},
		{value="😀ab", query="😀b", expected=MATCHES+Ranking(1.0/3.0)},
		{value="", query="", expected=CASE_SENSITIVE_EQUAL},
	}
	for test_case in cases {
		prepared := prepare_query(
			test_case.query,
			test_case.keep_diacritics,
			context.temp_allocator,
		)
		prepared_rank := get_match_ranking_prepared(test_case.value, &prepared)
		public_rank := get_match_ranking(
			test_case.value,
			test_case.query,
			test_case.keep_diacritics,
		)
		testing.expect_value(t, prepared_rank, test_case.expected)
		testing.expect_value(t, public_rank, prepared_rank)
	}
}

reverse_base_sort :: proc(a, b: ^Ranked_Item) -> int {
	return -1 if a.index < b.index else 1
}

reverse_sorter :: proc(items: ^[dynamic]Ranked_Item) {
	for left, right := 0, len(items^)-1; left < right; left, right = left+1, right-1 {
		items[left], items[right] = items[right], items[left]
	}
}

@(test)
custom_sorting_and_original_order_test :: proc(t: ^testing.T) {
	base := match_sorter_strings([]string{"appl", "C apple", "B apple", "A apple", "app", "applebutter"}, "apple", Options{base_sort=reverse_base_sort})
	defer delete(base)
	expect_strings(t, base, []string{"applebutter", "C apple", "B apple", "A apple"})
	reversed := match_sorter_strings([]string{"appl", "C apple", "B apple", "A apple", "app", "applebutter"}, "", Options{sorter=reverse_sorter})
	defer delete(reversed)
	expect_strings(t, reversed, []string{"applebutter", "app", "A apple", "B apple", "C apple", "appl"})
}

@(test)
rank_metadata_test :: proc(t: ^testing.T) {
	actual := match_sorter_with_rank_info([]Value{string_value("hello"), string_value("hey"), string_value("sup")}, "h")
	defer delete(actual)
	testing.expect_value(t, len(actual), 2)
	testing.expect_value(t, actual[0].ranked_value, "hello")
	testing.expect_value(t, actual[0].rank, STARTS_WITH)
	testing.expect_value(t, actual[0].key_index, -1)
	testing.expect_value(t, actual[0].index, 0)
	testing.expect_value(t, actual[1].index, 1)
}

@(test)
no_match_and_acronym_thresholds_test :: proc(t: ^testing.T) {
	all := match_sorter_strings([]string{"orange", "apple", "grape", "banana"}, "ap", Options{has_threshold=true, threshold=NO_MATCH})
	defer delete(all)
	expect_strings(t, all, []string{"apple", "grape", "banana", "orange"})
	acronym := match_sorter_strings([]string{"apple", "atop", "alpaca", "vamped"}, "ap", Options{has_threshold=true, threshold=ACRONYM})
	defer delete(acronym)
	expect_strings(t, acronym, []string{"apple"})
}

@(test)
empty_query_and_punctuation_collation_test :: proc(t: ^testing.T) {
	empty := match_sorter_strings([]string{"Milk", "Oolong", "Green"}, "")
	defer delete(empty)
	expect_strings(t, empty, []string{"Green", "Milk", "Oolong"})
	punctuation := match_sorter_strings([]string{"a'd", "a-c", "a_b", "a a"}, "")
	defer delete(punctuation)
	expect_strings(t, punctuation, []string{"a a", "a_b", "a-c", "a'd"})
}

@(test)
stable_equal_objects_and_complete_accent_mapping_test :: proc(t: ^testing.T) {
	items := []Value{
		object(field("country", string_value("Italy")), field("counter", number_value(3))),
		object(field("country", string_value("Italy")), field("counter", number_value(2))),
		object(field("country", string_value("Italy")), field("counter", number_value(1))),
	}
	actual := match_sorter_with_rank_info(items, "Italy", Options{keys=[]Key{{path="country"}, {path="counter"}}, has_keys=true})
	defer delete(actual)
	for ranked, index in actual { testing.expect_value(t, ranked.index, index) }
	accents := prepare_value("Ǽ Œ Þ Ứ Й Ё", false)
	defer delete(accents)
	testing.expect_value(t, accents, "AE OE TH U И Е")
}

@(test)
null_paths_array_ties_and_diacritic_collation_test :: proc(t: ^testing.T) {
	nested := []Value{
		object(field("name", object(field("first", string_value("baz"))))),
		object(field("name", null_value())),
		null_value(),
		object(),
	}
	nested_result := match_sorter(nested, "ba", Options{keys=[]Key{{path="name.first"}}, has_keys=true})
	defer delete(nested_result)
	testing.expect_value(t, len(nested_result), 1)

	arrays := []Value{
		object(field("flavor", array(string_value("mint"), string_value("chocolate")))),
		object(field("flavor", array(string_value("chocolate"), string_value("brownie")))),
	}
	array_result := match_sorter_with_rank_info(arrays, "chocolate", Options{keys=[]Key{{path="flavor"}}, has_keys=true})
	defer delete(array_result)
	testing.expect_value(t, array_result[0].index, 1)

	diacritics := match_sorter_strings(
		[]string{"jalapeño", "anothernodiacritics", "à la carte", "nodiacritics", "café", "papier-mâché", "à la mode"},
		"z",
		Options{has_threshold=true, threshold=NO_MATCH},
	)
	defer delete(diacritics)
	expect_strings(t, diacritics, []string{"à la carte", "à la mode", "anothernodiacritics", "café", "jalapeño", "nodiacritics", "papier-mâché"})
}

Typed_Test_Item :: struct {name: string, aliases: []string}

typed_name_getter :: proc(item: ^Typed_Test_Item) -> Extracted_Values {
	return single_value(item.name)
}

typed_aliases_getter :: proc(item: ^Typed_Test_Item) -> Extracted_Values {
	return many_values(item.aliases)
}

@(test)
typed_and_dynamic_multifield_rank_parity_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	typed_items := []Typed_Test_Item{
		{name="Voice", aliases=[]string{"lead", "voice"}},
		{name="Breath", aliases=[]string{"voice", "support"}},
		{name="voice", aliases=[]string{"other", "voice"}},
		{name="Unrelated", aliases=[]string{"vocal exercise", "voice warmup"}},
		{name="Voice", aliases=[]string{"lead", "voice"}},
	}
	dynamic_items := []Value{
		object(field("name", string_value("Voice")), field("aliases", array(string_value("lead"), string_value("voice")))),
		object(field("name", string_value("Breath")), field("aliases", array(string_value("voice"), string_value("support")))),
		object(field("name", string_value("voice")), field("aliases", array(string_value("other"), string_value("voice")))),
		object(field("name", string_value("Unrelated")), field("aliases", array(string_value("vocal exercise"), string_value("voice warmup")))),
		object(field("name", string_value("Voice")), field("aliases", array(string_value("lead"), string_value("voice")))),
	}
	typed_keys := []Typed_Key(Typed_Test_Item){
		{getter=typed_name_getter},
		{getter=typed_aliases_getter},
	}
	dynamic_keys := []Key{{path="name"}, {path="aliases"}}
	typed_result := match_with_rank_info(
		&search,
		typed_items,
		"voice",
		Typed_Options(Typed_Test_Item){keys=typed_keys},
	)
	defer ranked_result_destroy(&typed_result)
	dynamic_result := match_with_rank_info(
		&search,
		dynamic_items,
		"voice",
		Options{keys=dynamic_keys, has_keys=true},
	)
	defer ranked_result_destroy(&dynamic_result)
	testing.expect_value(t, len(typed_result.items), len(dynamic_result.items))
	if len(typed_result.items) != len(dynamic_result.items) { return }
	for typed_item, index in typed_result.items {
		dynamic_item := dynamic_result.items[index]
		testing.expect_value(t, typed_item.item_index, dynamic_item.item_index)
		testing.expect_value(t, typed_item.ranked_value, dynamic_item.ranked_value)
		testing.expect_value(t, typed_item.rank, dynamic_item.rank)
		testing.expect_value(t, typed_item.key_index, dynamic_item.key_index)
	}
}

@(test)
typed_indices_borrow_input_and_reset_scratch_test :: proc(t: ^testing.T) {
	search: Search_Context
	err := search_context_init(&search)
	testing.expect(t, err == nil)
	defer search_context_destroy(&search)
	items := []Typed_Test_Item{
		{name="Ada", aliases=[]string{"Countess", "Enchantress of Numbers"}},
		{name="Grace", aliases=[]string{"Amazing Grace", "COBOL"}},
		{name="Edsger", aliases=[]string{"Dijkstra"}},
	}
	keys := []Typed_Key(Typed_Test_Item){
		{getter=typed_name_getter},
		{getter=typed_aliases_getter},
	}
	used_before := search.scratch.total_used
	indices := match_indices_typed(&search, items, "cob", Typed_Options(Typed_Test_Item){keys=keys, has_threshold=true, threshold=STARTS_WITH})
	defer delete(indices)
	testing.expect_value(t, len(indices), 1)
	testing.expect_value(t, indices[0], 1)
	testing.expect_value(t, search.scratch.total_used, used_before)
	testing.expect_value(t, items[1].name, "Grace")
}

@(test)
typed_indices_into_reuses_caller_buffer_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []string{"hello", "hey", "sup", "yo"}
	expected := match_indices(&search, items, "h", Typed_Options(string){})
	defer delete(expected)
	result := make([dynamic]int, 0, len(items))
	defer delete(result)
	match_indices_into_typed(&search, items, "h", Typed_Options(string){}, &result)
	testing.expect_value(t, len(result), len(expected))
	for value, index in result {
		testing.expect_value(t, value, expected[index])
	}
	buffer := raw_data(result[:])
	result_capacity := cap(result)
	match_indices_into_typed(&search, items, "z", Typed_Options(string){}, &result)
	testing.expect_value(t, len(result), 0)
	testing.expect_value(t, cap(result), result_capacity)
	match_indices_into_typed(&search, items, "he", Typed_Options(string){}, &result)
	testing.expect(t, raw_data(result[:]) == buffer)
	testing.expect_value(t, cap(result), result_capacity)
	testing.expect_value(t, search.scratch.total_used, uint(0))
}

@(test)
context_apis_restore_caller_temp_allocator_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	caller_arena: mem_virtual.Arena
	caller_error := mem_virtual.arena_init_growing(&caller_arena)
	testing.expect_value(t, caller_error, nil)
	if caller_error != nil {
		return
	}
	defer mem_virtual.arena_destroy(&caller_arena)

	previous := context.temp_allocator
	defer context.temp_allocator = previous
	caller_allocator := mem_virtual.arena_allocator(&caller_arena)
	context.temp_allocator = caller_allocator

	dynamic_items := []Value{string_value("hello"), string_value("hey")}
	dynamic_indices := match_indices_dynamic(
		&search,
		dynamic_items,
		"h",
	)
	delete(dynamic_indices)
	expect_temp_allocator_identity(t, caller_allocator)
	context.temp_allocator = caller_allocator

	dynamic_ranked := match_with_rank_info_dynamic(
		&search,
		dynamic_items,
		"h",
	)
	ranked_result_destroy(&dynamic_ranked)
	expect_temp_allocator_identity(t, caller_allocator)
	context.temp_allocator = caller_allocator

	typed_items := []string{"hello", "hey"}
	typed_indices := match_indices_typed(
		&search,
		typed_items,
		"h",
		Typed_Options(string){},
	)
	delete(typed_indices)
	expect_temp_allocator_identity(t, caller_allocator)
	context.temp_allocator = caller_allocator

	typed_into := make([dynamic]int)
	match_indices_into_typed(
		&search,
		typed_items,
		"h",
		Typed_Options(string){},
		&typed_into,
	)
	delete(typed_into)
	expect_temp_allocator_identity(t, caller_allocator)
	context.temp_allocator = caller_allocator

	typed_ranked := match_with_rank_info_typed(
		&search,
		typed_items,
		"h",
		Typed_Options(string){},
	)
	ranked_result_destroy(&typed_ranked)
	expect_temp_allocator_identity(t, caller_allocator)
}

@(test)
caller_temporaries_stay_out_of_search_scratch_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)

	caller_arena: mem_virtual.Arena
	caller_error := mem_virtual.arena_init_growing(&caller_arena)
	testing.expect_value(t, caller_error, nil)
	if caller_error != nil {
		return
	}
	defer mem_virtual.arena_destroy(&caller_arena)

	previous := context.temp_allocator
	defer context.temp_allocator = previous
	caller_allocator := mem_virtual.arena_allocator(&caller_arena)
	context.temp_allocator = caller_allocator

	items := []string{"hello", "hey"}
	first := match_indices_typed(
		&search,
		items,
		"h",
		Typed_Options(string){},
	)
	delete(first)

	caller_data := make([]byte, 4, context.temp_allocator)
	caller_data[0] = 0x12
	caller_data[1] = 0x34
	caller_data[2] = 0x56
	caller_data[3] = 0x78

	second := match_indices_typed(
		&search,
		items,
		"he",
		Typed_Options(string){},
	)
	delete(second)

	expect_temp_allocator_identity(t, caller_allocator)
	testing.expect_value(t, caller_data[0], byte(0x12))
	testing.expect_value(t, caller_data[1], byte(0x34))
	testing.expect_value(t, caller_data[2], byte(0x56))
	testing.expect_value(t, caller_data[3], byte(0x78))
	testing.expect_value(t, search.scratch.total_used, uint(0))
}

@(test)
context_uses_fixed_en_us_collation_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []Value{string_value("a'd"), string_value("a-c"), string_value("a_b"), string_value("a a")}
	indices := match_indices(&search, items, "", Options{})
	defer delete(indices)
	testing.expect_value(t, len(indices), 4)
	expected := []int{3, 2, 1, 0}
	for value, index in indices { testing.expect_value(t, value, expected[index]) }
	typed_items := []string{"a'd", "a-c", "a_b", "a a"}
	typed_indices := match_indices(
		&search,
		typed_items,
		"",
		Typed_Options(string){},
	)
	defer delete(typed_indices)
	testing.expect_value(t, len(typed_indices), len(expected))
	for value, index in typed_indices {
		testing.expect_value(t, value, expected[index])
	}
}

@(test)
remove_accents_0_5_0_complete_mapping_test :: proc(t: ^testing.T) {
	input := "À|Á|Â|Ã|Ä|Å|Ấ|Ắ|Ẳ|Ẵ|Ặ|Æ|Ầ|Ằ|Ȃ|Ả|Ạ|Ẩ|Ẫ|Ậ|Ç|Ḉ|È|É|Ê|Ë|Ế|Ḗ|Ề|Ḕ|Ḝ|Ȇ|Ẻ|Ẽ|Ẹ|Ể|Ễ|Ệ|Ì|Í|Î|Ï|Ḯ|Ȋ|Ỉ|Ị|Ð|Ñ|Ò|Ó|Ô|Õ|Ö|Ø|Ố|Ṍ|Ṓ|Ȏ|Ỏ|Ọ|Ổ|Ỗ|Ộ|Ờ|Ở|Ỡ|Ớ|Ợ|Ù|Ú|Û|Ü|Ủ|Ụ|Ử|Ữ|Ự|Ý|à|á|â|ã|ä|å|ấ|ắ|ẳ|ẵ|ặ|æ|ầ|ằ|ȃ|ả|ạ|ẩ|ẫ|ậ|ç|ḉ|è|é|ê|ë|ế|ḗ|ề|ḕ|ḝ|ȇ|ẻ|ẽ|ẹ|ể|ễ|ệ|ì|í|î|ï|ḯ|ȋ|ỉ|ị|ð|ñ|ò|ó|ô|õ|ö|ø|ố|ṍ|ṓ|ȏ|ỏ|ọ|ổ|ỗ|ộ|ờ|ở|ỡ|ớ|ợ|ù|ú|û|ü|ủ|ụ|ử|ữ|ự|ý|ÿ|Ā|ā|Ă|ă|Ą|ą|Ć|ć|Ĉ|ĉ|Ċ|ċ|Č|č|C̆|c̆|Ď|ď|Đ|đ|Ē|ē|Ĕ|ĕ|Ė|ė|Ę|ę|Ě|ě|Ĝ|Ǵ|ĝ|ǵ|Ğ|ğ|Ġ|ġ|Ģ|ģ|Ĥ|ĥ|Ħ|ħ|Ḫ|ḫ|Ĩ|ĩ|Ī|ī|Ĭ|ĭ|Į|į|İ|ı|Ĳ|ĳ|Ĵ|ĵ|Ķ|ķ|Ḱ|ḱ|K̆|k̆|Ĺ|ĺ|Ļ|ļ|Ľ|ľ|Ŀ|ŀ|Ł|ł|Ḿ|ḿ|M̆|m̆|Ń|ń|Ņ|ņ|Ň|ň|ŉ|N̆|n̆|Ō|ō|Ŏ|ŏ|Ő|ő|Œ|œ|P̆|p̆|Ŕ|ŕ|Ŗ|ŗ|Ř|ř|R̆|r̆|Ȓ|ȓ|Ś|ś|Ŝ|ŝ|Ş|Ș|ș|ş|Š|š|Ţ|ţ|ț|Ț|Ť|ť|Ŧ|ŧ|T̆|t̆|Ũ|ũ|Ū|ū|Ŭ|ŭ|Ů|ů|Ű|ű|Ų|ų|Ȗ|ȗ|V̆|v̆|Ŵ|ŵ|Ẃ|ẃ|X̆|x̆|Ŷ|ŷ|Ÿ|Y̆|y̆|Ź|ź|Ż|ż|Ž|ž|ſ|ƒ|Ơ|ơ|Ư|ư|Ǎ|ǎ|Ǐ|ǐ|Ǒ|ǒ|Ǔ|ǔ|Ǖ|ǖ|Ǘ|ǘ|Ǚ|ǚ|Ǜ|ǜ|Ứ|ứ|Ṹ|ṹ|Ǻ|ǻ|Ǽ|ǽ|Ǿ|ǿ|Þ|þ|Ṕ|ṕ|Ṥ|ṥ|X́|x́|Ѓ|ѓ|Ќ|ќ|A̋|a̋|E̋|e̋|I̋|i̋|Ǹ|ǹ|Ồ|ồ|Ṑ|ṑ|Ừ|ừ|Ẁ|ẁ|Ỳ|ỳ|Ȁ|ȁ|Ȅ|ȅ|Ȉ|ȉ|Ȍ|ȍ|Ȑ|ȑ|Ȕ|ȕ|B̌|b̌|Č̣|č̣|Ê̌|ê̌|F̌|f̌|Ǧ|ǧ|Ȟ|ȟ|J̌|ǰ|Ǩ|ǩ|M̌|m̌|P̌|p̌|Q̌|q̌|Ř̩|ř̩|Ṧ|ṧ|V̌|v̌|W̌|w̌|X̌|x̌|Y̌|y̌|A̧|a̧|B̧|b̧|Ḑ|ḑ|Ȩ|ȩ|Ɛ̧|ɛ̧|Ḩ|ḩ|I̧|i̧|Ɨ̧|ɨ̧|M̧|m̧|O̧|o̧|Q̧|q̧|U̧|u̧|X̧|x̧|Z̧|z̧|й|Й|ё|Ё"
	expected := "A|A|A|A|A|A|A|A|A|A|A|AE|A|A|A|A|A|A|A|A|C|C|E|E|E|E|E|E|E|E|E|E|E|E|E|E|E|E|I|I|I|I|I|I|I|I|D|N|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|O|U|U|U|U|U|U|U|U|U|Y|a|a|a|a|a|a|a|a|a|a|a|ae|a|a|a|a|a|a|a|a|c|c|e|e|e|e|e|e|e|e|e|e|e|e|e|e|e|e|i|i|i|i|i|i|i|i|d|n|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|o|u|u|u|u|u|u|u|u|u|y|y|A|a|A|a|A|a|C|c|C|c|C|c|C|c|C|c|D|d|D|d|E|e|E|e|E|e|E|e|E|e|G|G|g|g|G|g|G|g|G|g|H|h|H|h|H|h|I|i|I|i|I|i|I|i|I|i|IJ|ij|J|j|K|k|K|k|K|k|L|l|L|l|L|l|L|l|l|l|M|m|M|m|N|n|N|n|N|n|n|N|n|O|o|O|o|O|o|OE|oe|P|p|R|r|R|r|R|r|R|r|R|r|S|s|S|s|S|S|s|s|S|s|T|t|t|T|T|t|T|t|T|t|U|u|U|u|U|u|U|u|U|u|U|u|U|u|V|v|W|w|W|w|X|x|Y|y|Y|Y|y|Z|z|Z|z|Z|z|s|f|O|o|U|u|A|a|I|i|O|o|U|u|U|u|U|u|U|u|U|u|U|u|U|u|A|a|AE|ae|O|o|TH|th|P|p|S|s|X|x|Г|г|К|к|A|a|E|e|I|i|N|n|O|o|O|o|U|u|W|w|Y|y|A|a|E|e|I|i|O|o|R|r|U|u|B|b|C|c|E|e|F|f|G|g|H|h|J|j|K|k|M|m|P|p|Q|q|R|r|S|s|V|v|W|w|X|x|Y|y|A|a|B|b|D|d|E|e|E|e|H|h|I|i|I|i|M|m|O|o|Q|q|U|u|X|x|Z|z|и|И|е|Е"
	actual := prepare_value(input, false)
	defer delete(actual)
	testing.expect_value(t, actual, expected)
}

@(test)
javascript_value_coercion_and_utf16_scoring_test :: proc(t: ^testing.T) {
	values := []Value{
		undefined_value(), null_value(), bool_value(true), number_value(-0.0),
		number_value(math.inf_f64(1)), number_value(math.inf_f64(-1)), number_value(math.nan_f64()),
		array_value([]Value{string_value("a"), null_value(), number_value(2), object()}),
	}
	expected := []string{"undefined", "null", "true", "0", "Infinity", "-Infinity", "NaN", "a,,2,[object Object]"}
	for value, index in values {
		actual := value_to_string(value)
		if value.kind == .Array { defer delete(actual) }
		testing.expect_value(t, actual, expected[index])
	}
	rank := get_match_ranking("😀ab", "😀b")
	testing.expect_value(t, rank, MATCHES+Ranking(1.0/3.0))
	unlisted := prepare_value("A\u0301", false)
	defer delete(unlisted)
	testing.expect_value(t, unlisted, "A\u0301")
}

@(test)
ranked_result_survives_scratch_rewind_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := []Value{string_value("hello"), string_value("hey"), string_value("sup")}
	result := match_with_rank_info(&search, items, "h", Options{})
	defer ranked_result_destroy(&result)
	other := match_indices(&search, items, "s", Options{})
	defer delete(other)
	testing.expect_value(t, result.items[0].ranked_value, "hello")
	testing.expect_value(t, result.items[1].ranked_value, "hey")
}

@(test)
hundred_thousand_items_reuse_scratch_without_copying_input_test :: proc(t: ^testing.T) {
	search: Search_Context
	testing.expect(t, search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	items := make([]string, 100_000)
	defer delete(items)
	for &item in items { item = "record" }
	input_address := raw_data(items)
	first := match_indices(&search, items, "z", Typed_Options(string){})
	defer delete(first)
	committed_after_first := search.scratch.curr_block.committed
	second := match_indices(&search, items, "z", Typed_Options(string){})
	defer delete(second)
	testing.expect_value(t, len(first), 0)
	testing.expect_value(t, len(second), 0)
	testing.expect(t, raw_data(items) == input_address)
	testing.expect_value(t, search.scratch.total_used, uint(0))
	testing.expect_value(t, search.scratch.curr_block.committed, committed_after_first)
}
