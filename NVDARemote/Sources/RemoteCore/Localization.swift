import Foundation

/// Text translated from the package's string catalog (`Localizable.xcstrings`).
/// The code is written in English, the fallback language; French comes from the catalog.
func localized(_ value: String.LocalizationValue) -> String {
	String(localized: value, bundle: .module)
}
