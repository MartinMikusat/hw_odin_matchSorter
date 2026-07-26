package match_sorter

import CF "core:sys/darwin/CoreFoundation"

MATCH_SORTER_BENCHMARK :: #config(MATCH_SORTER_BENCHMARK, false)

Mac_Locale :: distinct CF.TypeRef
Mac_Sort_String :: CF.String

benchmark_cf_string_creations: int
benchmark_cf_string_comparisons: int

foreign import CoreFoundation "system:CoreFoundation.framework"

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	StringCreateWithBytes :: proc(
		allocator: CF.TypeRef,
		bytes: [^]u8,
		byte_count: CF.Index,
		encoding: CF.StringEncoding,
		external_representation: b8,
	) -> CF.String ---
	LocaleCreate :: proc(allocator: CF.TypeRef, identifier: CF.String) -> Mac_Locale ---
	StringCompareWithOptionsAndLocale :: proc(
		a, b: CF.String,
		range: CF.Range,
		options: CF.OptionFlags,
		locale: Mac_Locale,
	) -> i32 ---
}

mac_string_create :: proc(value: string) -> CF.String {
	when MATCH_SORTER_BENCHMARK {
		benchmark_cf_string_creations += 1
	}
	return StringCreateWithBytes(
		CF.TypeRef(nil),
		raw_data(value),
		CF.Index(len(value)),
		CF.StringEncoding(CF.StringBuiltInEncodings.UTF8),
		false,
	)
}

mac_locale_create_en_us :: proc() -> Mac_Locale {
	identifier := mac_string_create("en_US")
	defer CF.Release(identifier)
	return LocaleCreate(CF.TypeRef(nil), identifier)
}

mac_locale_destroy :: proc(locale: Mac_Locale) {
	if locale != Mac_Locale(nil) { CF.Release(CF.TypeRef(locale)) }
}

mac_sort_string_create :: proc(value: string) -> Mac_Sort_String {
	return mac_string_create(value)
}

mac_sort_strings_destroy :: proc(values: []Mac_Sort_String) {
	for value in values {
		if value != Mac_Sort_String(nil) { CF.Release(value) }
	}
}

mac_compare_sort_strings :: proc(
	a, b: Mac_Sort_String,
	locale: Mac_Locale,
) -> int {
	when MATCH_SORTER_BENCHMARK {
		benchmark_cf_string_comparisons += 1
	}
	result := StringCompareWithOptionsAndLocale(
		a,
		b,
		{0, CF.StringGetLength(a)},
		CF.OptionFlags(0),
		locale,
	)
	return int(result)
}

benchmark_mac_sort_reset :: proc() {
	when MATCH_SORTER_BENCHMARK {
		benchmark_cf_string_creations = 0
		benchmark_cf_string_comparisons = 0
	}
}

benchmark_mac_sort_stats :: proc() -> (creations, comparisons: int) {
	when MATCH_SORTER_BENCHMARK {
		return benchmark_cf_string_creations, benchmark_cf_string_comparisons
	}
	return 0, 0
}
