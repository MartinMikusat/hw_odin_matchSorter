package match_sorter

import CF "core:sys/darwin/CoreFoundation"

Mac_Locale :: distinct CF.TypeRef

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

mac_compare_strings :: proc(a, b: string, locale: Mac_Locale) -> int {
	a_string := mac_string_create(a)
	defer CF.Release(a_string)
	b_string := mac_string_create(b)
	defer CF.Release(b_string)
	result := StringCompareWithOptionsAndLocale(
		a_string,
		b_string,
		{0, CF.StringGetLength(a_string)},
		CF.OptionFlags(0),
		locale,
	)
	return int(result)
}
