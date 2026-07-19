package match_sorter

import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Ranking :: f64

NO_MATCH            :: Ranking(0)
MATCHES              :: Ranking(1)
ACRONYM              :: Ranking(2)
CONTAINS             :: Ranking(3)
WORD_STARTS_WITH     :: Ranking(4)
STARTS_WITH          :: Ranking(5)
EQUAL                :: Ranking(6)
CASE_SENSITIVE_EQUAL :: Ranking(7)

Value_Kind :: enum {Null, String, Number, Bool, Array, Object}

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
	result := make([dynamic]Ranked_Item, 0, len(items), allocator)
	for item, index in items {
		info := get_highest_ranking(item, query, options)
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
		insertion_sort(result[:], options.base_sort)
	}
	return result[:]
}

get_highest_ranking :: proc(item: Value, query: string, options: Options) -> Ranking_Info {
	if !options.has_keys {
		value := value_to_string(item, context.temp_allocator)
		return {value, get_match_ranking(value, query, options.keep_diacritics), -1, false, 0}
	}
	best := Ranking_Info{value_to_string(item, context.temp_allocator), NO_MATCH, -1, false, 0}
	value_index := 0
	for key in options.keys {
		values := get_item_values(item, key, context.temp_allocator)
		for value in values {
			rank := get_match_ranking(value, query, options.keep_diacritics)
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
	test := prepare_value(test_value, keep_diacritics, context.temp_allocator)
	needle := prepare_value(query, keep_diacritics, context.temp_allocator)
	test_runes := utf8.string_to_runes(test, context.temp_allocator)
	needle_runes := utf8.string_to_runes(needle, context.temp_allocator)
	if len(needle_runes) > len(test_runes) { return NO_MATCH }
	if test == needle { return CASE_SENSITIVE_EQUAL }
	for &r in test_runes { r = to_lower(r) }
	for &r in needle_runes { r = to_lower(r) }
	first := index_of_runes(test_runes, needle_runes, 0)
	if len(test_runes) == len(needle_runes) && first == 0 { return EQUAL }
	if first == 0 { return STARTS_WITH }
	if first >= 0 {
		index := first
		for index >= 0 {
			if index > 0 && test_runes[index-1] == ' ' { return WORD_STARTS_WITH }
			index = index_of_runes(test_runes, needle_runes, index+1)
		}
		return CONTAINS
	}
	if len(needle_runes) == 1 { return NO_MATCH }
	acronym := get_acronym(test_runes, context.temp_allocator)
	if index_of_runes(acronym, needle_runes, 0) >= 0 { return ACRONYM }
	return get_closeness_ranking(test_runes, needle_runes)
}

get_acronym :: proc(value: []rune, allocator := context.allocator) -> []rune {
	result := make([dynamic]rune, 0, len(value), allocator)
	previous: rune = ' '
	for current in value {
		previous_delimiter := previous == ' ' || previous == '-'
		current_delimiter := current == ' ' || current == '-'
		if previous_delimiter && !current_delimiter { append(&result, current) }
		previous = current
	}
	return result[:]
}

get_closeness_ranking :: proc(test, needle: []rune) -> Ranking {
	if len(needle) == 0 { return NO_MATCH }
	matched := 0
	find := proc(match: rune, value: []rune, start: int, matched: ^int) -> int {
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
		builder: strings.Builder
		strings.builder_init(&builder, allocator)
		strings.write_float(&builder, value.number, 'g', -1, 64)
		return strings.to_string(builder)
	case .Bool: return "true" if value.boolean else "false"
	case .Null: return "null"
	case: return "[object Object]"
	}
}

default_base_sort :: proc(a, b: ^Ranked_Item) -> int {
	a_value := utf8.string_to_runes(prepare_value(a.ranked_value, false, context.temp_allocator), context.temp_allocator)
	b_value := utf8.string_to_runes(prepare_value(b.ranked_value, false, context.temp_allocator), context.temp_allocator)
	for &r in a_value { r = to_lower(r) }
	for &r in b_value { r = to_lower(r) }
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

insertion_sort :: proc(items: []Ranked_Item, base_sort: Base_Sort) {
	compare := base_sort
	if compare == nil { compare = default_base_sort }
	for i := 1; i < len(items); i += 1 {
		value := items[i]
		j := i
		for j > 0 && compare_ranked(&value, &items[j-1], compare) < 0 {
			items[j] = items[j-1]
			j -= 1
		}
		items[j] = value
	}
}

compare_ranked :: proc(a, b: ^Ranked_Item, base_sort: Base_Sort) -> int {
	if a.rank != b.rank { return -1 if a.rank > b.rank else 1 }
	if a.key_index != b.key_index { return -1 if a.key_index < b.key_index else 1 }
	return base_sort(a, b)
}

index_of_runes :: proc(haystack, needle: []rune, start: int) -> int {
	if len(needle) == 0 { return start if start <= len(haystack) else -1 }
	for i := start; i+len(needle) <= len(haystack); i += 1 {
		matches := true
		for rune_value, j in needle { if haystack[i+j] != rune_value { matches = false; break } }
		if matches { return i }
	}
	return -1
}

to_lower :: proc(r: rune) -> rune { return unicode.to_lower(r) }

prepare_value :: proc(value: string, keep_diacritics: bool, allocator := context.allocator) -> string {
	if keep_diacritics { return value }
	input := utf8.string_to_runes(value, context.temp_allocator)
	output := make([dynamic]rune, 0, len(input), context.temp_allocator)
	for r in input {
		switch r {
		case 'Æ','Ǽ': append(&output, 'A', 'E')
		case 'æ','ǽ': append(&output, 'a', 'e')
		case 'Œ': append(&output, 'O', 'E')
		case 'œ': append(&output, 'o', 'e')
		case 'Þ': append(&output, 'T', 'H')
		case 'þ': append(&output, 't', 'h')
		case 0x0300..=0x036f: // remove combining marks used by decomposed accents
		case: append(&output, remove_accent(r))
		}
	}
	return utf8.runes_to_string(output[:], allocator)
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
	case 'Ķ','Ḱ','Ǩ','Ќ': return 'K'; case 'ķ','ḱ','ǩ','ќ': return 'k'
	case 'Ĺ','Ļ','Ľ','Ŀ','Ł': return 'L'; case 'ĺ','ļ','ľ','ŀ','ł': return 'l'
	case 'Ḿ': return 'M'; case 'ḿ': return 'm'
	case 'Ñ','Ń','Ņ','Ň','Ǹ': return 'N'; case 'ñ','ń','ņ','ň','ŉ','ǹ': return 'n'
	case 'Ò','Ó','Ô','Õ','Ö','Ø','Ố','Ṍ','Ṓ','Ȏ','Ỏ','Ọ','Ổ','Ỗ','Ộ','Ờ','Ở','Ỡ','Ớ','Ợ','Ō','Ŏ','Ő','Ơ','Ǒ','Ǿ','Ồ','Ṑ','Ȍ': return 'O'
	case 'ò','ó','ô','õ','ö','ø','ố','ṍ','ṓ','ȏ','ỏ','ọ','ổ','ỗ','ộ','ờ','ở','ỡ','ớ','ợ','ō','ŏ','ő','ơ','ǒ','ǿ','ồ','ṑ','ȍ': return 'o'
	case 'Ṕ': return 'P'; case 'ṕ': return 'p'
	case 'Ŕ','Ŗ','Ř','Ȓ': return 'R'; case 'ŕ','ŗ','ř','ȓ': return 'r'
	case 'Ś','Ŝ','Ş','Ș','Š','Ṥ','Ṧ': return 'S'; case 'ś','ŝ','ș','ş','š','ṥ','ṧ','ſ': return 's'
	case 'Ţ','Ț','Ť','Ŧ': return 'T'; case 'ţ','ț','ť','ŧ': return 't'
	case 'Ù','Ú','Û','Ü','Ủ','Ụ','Ử','Ữ','Ự','Ũ','Ū','Ŭ','Ů','Ű','Ų','Ȗ','Ư','Ǔ','Ǖ','Ǘ','Ǚ','Ǜ','Ứ','Ṹ','Ừ','Ȕ': return 'U'
	case 'ù','ú','û','ü','ủ','ụ','ử','ữ','ự','ũ','ū','ŭ','ů','ű','ų','ȗ','ư','ǔ','ǖ','ǘ','ǚ','ǜ','ứ','ṹ','ừ','ȕ': return 'u'
	case 'Ŵ','Ẃ','Ẁ': return 'W'; case 'ŵ','ẃ','ẁ': return 'w'
	case 'Ý','Ÿ','Ŷ','Ỳ': return 'Y'; case 'ý','ÿ','ŷ','ỳ': return 'y'
	case 'Ź','Ż','Ž': return 'Z'; case 'ź','ż','ž': return 'z'
	case 'ƒ': return 'f'; case 'Ѓ': return 'Г'; case 'ѓ': return 'г'; case 'Й': return 'И'; case 'й': return 'и'; case 'Ё': return 'Е'; case 'ё': return 'е'
	}
	return r
}
