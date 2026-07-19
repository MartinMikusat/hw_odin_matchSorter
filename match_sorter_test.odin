package match_sorter

import "core:testing"

expect_strings :: proc(t: ^testing.T, actual, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) { return }
	for value, index in actual { testing.expect_value(t, value, expected[index]) }
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
