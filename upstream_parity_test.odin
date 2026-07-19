package match_sorter

import "core:testing"

parity_strings :: proc(items: []string, query: string, options := Options{}, allocator := context.allocator) -> []string {
	values := make([]Value, len(items), context.temp_allocator)
	for value, index in items { values[index] = string_value(value) }
	search: Search_Context
	assert(search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	result_values := match_items_dynamic(&search, values, query, options, context.temp_allocator)
	result := make([]string, len(result_values), allocator)
	for value, index in result_values { result[index] = value.string }
	return result
}

parity_values :: proc(items: []Value, query: string, options := Options{}, allocator := context.allocator) -> []Value {
	search: Search_Context
	assert(search_context_init(&search) == nil)
	defer search_context_destroy(&search)
	return match_items_dynamic(&search, items, query, options, allocator)
}

expect_value_indices :: proc(t: ^testing.T, actual: []Value, original: []Value, expected: []int) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) { return }
	for value, index in actual {
		found := -1
		for candidate, candidate_index in original {
			if raw_data(value.object) == raw_data(candidate.object) && value.kind == candidate.kind { found = candidate_index; break }
		}
		testing.expect_value(t, found, expected[index])
	}
}

aliases_fixture :: proc() -> []Value {
	source := []Value{
		object(field("aliases", array(object(field("name", object(field("first", string_value("baz"))))), object(field("name", object(field("first", string_value("foo"))))), object(field("name", null_value()))))),
		object(field("aliases", array(object(field("name", object(field("first", string_value("foo"))))), object(field("name", object(field("first", string_value("bat"))))), null_value()))),
		object(field("aliases", array(object(field("name", object(field("first", string_value("foo"))))), object(field("name", object(field("first", string_value("foo")))))))),
		object(field("aliases", null_value())), object(), null_value(),
	}
	result := make([]Value, len(source), context.temp_allocator)
	copy(result, source)
	return result
}

ice_cream_fixture :: proc(nested := false) -> []Value {
	values := []Value{
		array(string_value("mint"), string_value("chocolate")),
		array(string_value("candy cane"), string_value("brownie")),
		array(string_value("birthday cake"), string_value("rocky road"), string_value("strawberry")),
	}
	result := make([]Value, 3, context.temp_allocator)
	for value, index in values {
		result[index] = object(field("favorite", object(field("iceCream", value)))) if nested else object(field("favoriteIceCream", value))
	}
	return result
}

deep_ice_cream_fixture :: proc() -> []Value {
	source := []Value{
		object(field("favorite", object(field("iceCream", array(object(field("tastes", array(string_value("vanilla"), string_value("mint")))), object(field("tastes", array(string_value("vanilla"), string_value("chocolate"))))))))),
		object(field("favorite", object(field("iceCream", array(object(field("tastes", array(string_value("vanilla"), string_value("candy cane")))), object(field("tastes", array(string_value("vanilla"), string_value("brownie"))))))))),
		object(field("favorite", object(field("iceCream", array(object(field("tastes", array(string_value("vanilla"), string_value("birthday cake")))), object(field("tastes", array(string_value("vanilla"), string_value("rocky road")))), object(field("tastes", array(string_value("strawberry"))))))))),
	}
	result := make([]Value, len(source), context.temp_allocator)
	copy(result, source)
	return result
}

@(test) upstream_01_returns_empty_for_no_match :: proc(t: ^testing.T) {
	r := parity_strings([]string{"Chakotay", "Charzard"}, "nomatch"); defer delete(r); expect_strings(t, r, []string{})
}
@(test) upstream_02_returns_matching_items :: proc(t: ^testing.T) {
	r := parity_strings([]string{"Chakotay", "Brunt", "Charzard"}, "Ch"); defer delete(r); expect_strings(t, r, []string{"Chakotay", "Charzard"})
}
@(test) upstream_03_best_ranking_order :: proc(t: ^testing.T) {
	items:=[]string{"The Tail of Two Cities 1","tTOtc","ttotc","The 1-ttotc-2 container","The Tail of Forty Cities","The Tail of Two Cities","kebab-ttotc-case","Word starts with ttotc-first right?","The Tail of Fifty Cities","no match","The second 3-ttotc-4 container","ttotc-starts with","Another word starts with ttotc-second, super!","ttotc-2nd-starts with","TTotc"}
	r:=parity_strings(items,"ttotc"); defer delete(r); expect_strings(t,r,[]string{"ttotc","tTOtc","TTotc","ttotc-2nd-starts with","ttotc-starts with","Another word starts with ttotc-second, super!","Word starts with ttotc-first right?","kebab-ttotc-case","The 1-ttotc-2 container","The second 3-ttotc-4 container","The Tail of Two Cities","The Tail of Two Cities 1","The Tail of Fifty Cities","The Tail of Forty Cities"})
}
@(test) upstream_04_single_character_no_match :: proc(t: ^testing.T) {
	r := parity_strings([]string{"abc"}, "d"); defer delete(r); expect_strings(t, r, []string{})
}
@(test) upstream_05_object_key :: proc(t: ^testing.T) {
	items := []Value{object(field("name", string_value("baz"))), object(field("name", string_value("bat"))), object(field("name", string_value("foo")))}
	r := parity_values(items, "ba", Options{keys=[]Key{{path="name"}}, has_keys=true}); defer delete(r); expect_value_indices(t, r, items, []int{1,0})
}
@(test) upstream_06_multiple_keys :: proc(t: ^testing.T) {
	items:=[]Value{object(field("name",string_value("baz")),field("reverse",string_value("zab"))),object(field("name",string_value("bat")),field("reverse",string_value("tab"))),object(field("name",string_value("foo")),field("reverse",string_value("oof"))),object(field("name",string_value("bag")),field("reverse",string_value("gab")))}
	r:=parity_values(items,"ab",Options{keys=[]Key{{path="name"},{path="reverse"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{3,1,0})
}
@(test) upstream_07_key_index_before_alphabetical :: proc(t: ^testing.T) {
	items:=[]Value{object(field("first",string_value("not")),field("second",string_value("not")),field("third",string_value("match"))),object(field("first",string_value("not")),field("second",string_value("not")),field("third",string_value("not")),field("fourth",string_value("match"))),object(field("first",string_value("not")),field("second",string_value("match"))),object(field("first",string_value("match")),field("second",string_value("not")))}
	r:=parity_values(items,"match",Options{keys=[]Key{{path="first"},{path="second"},{path="third"},{path="fourth"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{3,2,0,1})
}
@(test) upstream_08_number_zero_property :: proc(t: ^testing.T) {
	items := []Value{object(field("name", string_value("A")),field("age",number_value(0))),object(field("name",string_value("B")),field("age",number_value(1))),object(field("name",string_value("C")),field("age",number_value(2))),object(field("name",string_value("D")),field("age",number_value(3)))}
	r := parity_values(items,"0",Options{keys=[]Key{{path="age"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{0})
}
@(test) upstream_09_nested_key_with_nulls :: proc(t: ^testing.T) {
	items := []Value{object(field("name",object(field("first",string_value("baz"))))),object(field("name",object(field("first",string_value("bat"))))),object(field("name",object(field("first",string_value("foo"))))),object(field("name",null_value())),object(),null_value()}
	r := parity_values(items,"ba",Options{keys=[]Key{{path="name.first"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_10_nested_array_numeric_index :: proc(t: ^testing.T) {
	items:=aliases_fixture(); r:=parity_values(items,"ba",Options{keys=[]Key{{path="aliases.0.name.first"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{0})
}
@(test) upstream_11_nested_array_wildcard :: proc(t: ^testing.T) {
	items:=aliases_fixture(); r:=parity_values(items,"ba",Options{keys=[]Key{{path="aliases.*.name.first"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{0,1})
}

parity_nested_name_getter :: proc(item: Value, allocator := context.temp_allocator) -> []string {
	name, ok := object_get(item,"name"); if !ok { return nil }; first, first_ok := object_get(name,"first"); if !first_ok { return nil }
	r:=make([]string,1,allocator); r[0]=value_to_string(first,allocator); return r
}

@(test) upstream_12_property_callback :: proc(t: ^testing.T) {
	items:=[]Value{object(field("name",object(field("first",string_value("baz"))))),object(field("name",object(field("first",string_value("bat"))))),object(field("name",object(field("first",string_value("foo")))))}
	r:=parity_values(items,"ba",Options{keys=[]Key{{getter=parity_nested_name_getter}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_13_array_valued_key :: proc(t: ^testing.T) {
	items:=ice_cream_fixture(); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favoriteIceCream"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_14_array_valued_key_wildcard :: proc(t: ^testing.T) {
	items:=ice_cream_fixture(); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favoriteIceCream.*"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_15_nested_array_valued_key :: proc(t: ^testing.T) {
	items:=ice_cream_fixture(true); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favorite.iceCream"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_16_nested_array_valued_key_wildcard :: proc(t: ^testing.T) {
	items:=ice_cream_fixture(true); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favorite.iceCream.*"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_17_nested_objects_single_wildcard :: proc(t: ^testing.T) {
	items:=deep_ice_cream_fixture(); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favorite.iceCream.*.tastes"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_18_nested_objects_two_wildcards :: proc(t: ^testing.T) {
	items:=deep_ice_cream_fixture(); r:=parity_values(items,"cc",Options{keys=[]Key{{path="favorite.iceCream.*.tastes.*"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
tea_alias_fixture :: proc(first_tea, first_alias, second_tea, second_alias, third_tea, third_alias: string) -> []Value {
	source:=[]Value{object(field("tea",string_value(first_tea)),field("alias",string_value(first_alias))),object(field("tea",string_value(second_tea)),field("alias",string_value(second_alias))),object(field("tea",string_value(third_tea)),field("alias",string_value(third_alias)))}
	result:=make([]Value,len(source),context.temp_allocator); copy(result,source); return result
}
@(test) upstream_19_max_ranking :: proc(t: ^testing.T) {
	items:=tea_alias_fixture("Earl Grey","A","Assam","B","Black","C"); keys:=[]Key{{path="tea"},{path="alias",attributes=Key_Attributes{has_max=true,max_ranking=STARTS_WITH}}}; r:=parity_values(items,"A",Options{keys=keys,has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0,2})
}
@(test) upstream_20_min_ranking :: proc(t: ^testing.T) {
	items:=tea_alias_fixture("Milk","moo","Oolong","B","Green","C"); keys:=[]Key{{path="tea"},{path="alias",attributes=Key_Attributes{has_min=true,min_ranking=EQUAL}}}; r:=parity_values(items,"oo",Options{keys=keys,has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{0,1})
}
@(test) upstream_21_array_tie_uses_higher_value_index :: proc(t: ^testing.T) {
	items:=[]Value{object(field("favoriteIceCream",array(string_value("mint"),string_value("chocolate")))),object(field("favoriteIceCream",array(string_value("chocolate"),string_value("brownie"))))}
	r:=parity_values(items,"chocolate",Options{keys=[]Key{{path="favoriteIceCream"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1,0})
}
@(test) upstream_22_no_match_threshold_returns_all :: proc(t: ^testing.T) { r:=parity_strings([]string{"orange","apple","grape","banana"},"ap",Options{has_threshold=true,threshold=NO_MATCH}); defer delete(r); expect_strings(t,r,[]string{"apple","grape","banana","orange"}) }
@(test) upstream_23_equal_threshold :: proc(t: ^testing.T) { r:=parity_strings([]string{"google","airbnb","apple","apply","app"},"app",Options{has_threshold=true,threshold=EQUAL}); defer delete(r); expect_strings(t,r,[]string{"app"}) }
@(test) upstream_24_case_sensitive_threshold :: proc(t: ^testing.T) { r:=parity_strings([]string{"google","airbnb","apple","apply","app","aPp","App"},"app",Options{has_threshold=true,threshold=CASE_SENSITIVE_EQUAL}); defer delete(r); expect_strings(t,r,[]string{"app"}) }
@(test) upstream_25_word_starts_threshold :: proc(t: ^testing.T) { r:=parity_strings([]string{"fiji apple","google","app","crabapple","apple","apply"},"app",Options{has_threshold=true,threshold=WORD_STARTS_WITH}); defer delete(r); expect_strings(t,r,[]string{"app","apple","apply","fiji apple"}) }
@(test) upstream_26_word_starts_after_suffix :: proc(t: ^testing.T) { r:=parity_strings([]string{"fiji apple","google","app","crabapple","apple","apply","snappy apple"},"app",Options{has_threshold=true,threshold=WORD_STARTS_WITH}); defer delete(r); expect_strings(t,r,[]string{"app","apple","apply","fiji apple","snappy apple"}) }
@(test) upstream_27_acronym_threshold :: proc(t: ^testing.T) { r:=parity_strings([]string{"apple","atop","alpaca","vamped"},"ap",Options{has_threshold=true,threshold=ACRONYM}); defer delete(r); expect_strings(t,r,[]string{"apple"}) }
@(test) upstream_28_ignore_diacritics_default :: proc(t: ^testing.T) { r:=parity_strings([]string{"jalapeño","à la carte","café","papier-mâché","à la mode"},"aa"); defer delete(r); expect_strings(t,r,[]string{"jalapeño","à la carte","à la mode","papier-mâché"}) }
@(test) upstream_29_keep_diacritics :: proc(t: ^testing.T) { r:=parity_strings([]string{"jalapeño","à la carte","papier-mâché","à la mode"},"aa",Options{keep_diacritics=true}); defer delete(r); expect_strings(t,r,[]string{"jalapeño","à la carte"}) }
@(test) upstream_30_closeness_order :: proc(t: ^testing.T) { r:=parity_strings([]string{"Antigua and Barbuda","India","Bosnia and Herzegovina","Indonesia"},"Ina"); defer delete(r); expect_strings(t,r,[]string{"Bosnia and Herzegovina","India","Indonesia","Antigua and Barbuda"}) }
@(test) upstream_31_empty_query_sorts :: proc(t: ^testing.T) { items:=tea_alias_fixture("Milk","moo","Oolong","B","Green","C"); r:=parity_values(items,"",Options{keys=[]Key{{path="tea"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{2,0,1}) }
@(test) upstream_32_per_key_threshold :: proc(t: ^testing.T) { items:=[]Value{object(field("name",string_value("Fred")),field("color",string_value("Orange"))),object(field("name",string_value("Jen")),field("color",string_value("Red")))}; keys:=[]Key{{path="name",attributes=Key_Attributes{has_threshold=true,threshold=STARTS_WITH}},{path="color"}}; r:=parity_values(items,"ed",Options{keys=keys,has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{1}) }
@(test) upstream_33_key_threshold_below_global :: proc(t: ^testing.T) { items:=[]Value{object(field("name",string_value("Fred")),field("color",string_value("Orange"))),object(field("name",string_value("Jen")),field("color",string_value("Red")))}; keys:=[]Key{{path="name"},{path="color",attributes=Key_Attributes{has_threshold=true,threshold=CONTAINS}}}; r:=parity_values(items,"ed",Options{keys=keys,has_keys=true,has_threshold=true,threshold=STARTS_WITH}); defer delete(r); expect_value_indices(t,r,items,[]int{1}) }
@(test) upstream_34_cyrillic_case_insensitive :: proc(t: ^testing.T) { r:=parity_strings([]string{"Привет","Лед"},"л"); defer delete(r); expect_strings(t,r,[]string{"Лед"}) }
@(test) upstream_35_diacritic_alphabetical_sort :: proc(t: ^testing.T) { r:=parity_strings([]string{"jalapeño","anothernodiacritics","à la carte","nodiacritics","café","papier-mâché","à la mode"},"z",Options{has_threshold=true,threshold=NO_MATCH}); defer delete(r); expect_strings(t,r,[]string{"à la carte","à la mode","anothernodiacritics","café","jalapeño","nodiacritics","papier-mâché"}) }
@(test) upstream_36_equal_objects_keep_input_order :: proc(t: ^testing.T) { items:=[]Value{object(field("country",string_value("Italy")),field("counter",number_value(3))),object(field("country",string_value("Italy")),field("counter",number_value(2))),object(field("country",string_value("Italy")),field("counter",number_value(1)))}; r:=parity_values(items,"Italy",Options{keys=[]Key{{path="country"},{path="counter"}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{0,1,2}) }
@(test) upstream_37_custom_base_sort :: proc(t: ^testing.T) { r:=parity_strings([]string{"appl","C apple","B apple","A apple","app","applebutter"},"apple",Options{base_sort=reverse_base_sort}); defer delete(r); expect_strings(t,r,[]string{"applebutter","C apple","B apple","A apple"}) }
@(test) upstream_38_punctuation_alphabetical_sort :: proc(t: ^testing.T) { r:=parity_strings([]string{"a'd","a-c","a_b","a a"},""); defer delete(r); expect_strings(t,r,[]string{"a a","a_b","a-c","a'd"}) }
@(test) upstream_39_non_space_words_callback :: proc(t: ^testing.T) { items:=[]Value{object(field("name",string_value("Janice_Kurtis"))),object(field("name",string_value("Fred_Mertz"))),object(field("name",string_value("George_Foreman"))),object(field("name",string_value("Jen_Smith")))}; r:=parity_values(items,"js",Options{keys=[]Key{{getter=underscore_getter}},has_keys=true}); defer delete(r); expect_value_indices(t,r,items,[]int{3,0}) }
@(test) upstream_40_custom_result_sorter :: proc(t: ^testing.T) { r:=parity_strings([]string{"appl","C apple","B apple","A apple","app","applebutter"},"",Options{sorter=reverse_sorter}); defer delete(r); expect_strings(t,r,[]string{"applebutter","app","A apple","B apple","C apple","appl"}) }

@(test) upstream_41_full_rank_metadata :: proc(t: ^testing.T) {
	items:=[]Value{object(field("tea",string_value("Earl Grey")),field("alias",string_value("A"))),object(field("tea",string_value("Assam")),field("alias",string_value("B"))),object(field("tea",string_value("Black")),field("alias",string_value("C")))}
	search:Search_Context; testing.expect(t,search_context_init(&search)==nil); defer search_context_destroy(&search)
	result:=match_with_rank_info_dynamic(&search,items,"A",Options{keys=[]Key{{path="tea"},{path="alias",attributes=Key_Attributes{has_max=true,max_ranking=STARTS_WITH}}},has_keys=true}); defer ranked_result_destroy(&result)
	testing.expect_value(t,len(result.items),3)
	expected_indices:=[]int{1,0,2}; expected_values:=[]string{"Assam","A","Black"}; expected_ranks:=[]Ranking{STARTS_WITH,STARTS_WITH,CONTAINS}; expected_keys:=[]int{0,1,0}
	for item,index in result.items { testing.expect_value(t,item.item_index,expected_indices[index]); testing.expect_value(t,item.ranked_value,expected_values[index]); testing.expect_value(t,item.rank,expected_ranks[index]); testing.expect_value(t,item.key_index,expected_keys[index]); testing.expect(t,!item.has_key_threshold) }
}

@(test) upstream_42_rank_metadata_without_options :: proc(t: ^testing.T) {
	items:=[]Value{string_value("hello"),string_value("hey"),string_value("sup")}; search:Search_Context; testing.expect(t,search_context_init(&search)==nil); defer search_context_destroy(&search)
	result:=match_with_rank_info_dynamic(&search,items,"h"); defer ranked_result_destroy(&result); testing.expect_value(t,len(result.items),2)
	testing.expect_value(t,result.items[0],Ranked_Index{0,"hello",STARTS_WITH,-1,false,0}); testing.expect_value(t,result.items[1],Ranked_Index{1,"hey",STARTS_WITH,-1,false,0})
}
