import Foundation
import PhoneNumberKit

/// Country-aware phone number formatting (brackets, spaces, hyphens) via PhoneNumberKit.
/// Formatting is for display only: `dialString(_:)` turns it back into plain digits for calling.
@MainActor
enum PhoneFormat {
    private static let utility = PhoneNumberUtility()
    private static var partialFormatter: (region: String, formatter: PartialFormatter)?

    /// Two-letter region code from the Account page, or "" for automatic.
    static var regionSetting = ""

    /// The Mac's region (System Settings › General › Language & Region), if PhoneNumberKit knows it.
    static var automaticRegion: String {
        let code = Locale.current.region?.identifier ?? "US"
        return utility.countryCode(for: code) != nil ? code : "US"
    }

    static var region: String { regionSetting.isEmpty ? automaticRegion : regionSetting }

    /// All regions PhoneNumberKit can format, with localized names, sorted by name.
    static let countries: [(code: String, name: String)] = utility.allCountries()
        .filter { $0 != "001" } // non-geographic numbers
        .map { ($0, Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Phone-number-ish input (digits and formatting), as opposed to a SIP address.
    static func looksLikeNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.contains(where: \.isNumber)
            && t.allSatisfy { "0123456789+()-. *#".contains($0) }
    }

    /// Formatted for display: national format for numbers in your country, international
    /// (+CC …) for others. nil if it isn't a parseable phone number.
    static func display(_ raw: String) -> String? {
        guard looksLikeNumber(raw),
              let number = try? utility.parse(raw, withRegion: region, ignoreType: true) else { return nil }
        let home = utility.countryCode(for: region)
        return utility.format(number, toType: number.countryCode == home ? .national : .international)
    }

    /// As-you-type formatting for the number field. SIP addresses are left alone.
    static func partial(_ raw: String) -> String {
        guard looksLikeNumber(raw) else { return raw }
        if partialFormatter?.region != region {
            partialFormatter = (region, PartialFormatter(utility: utility, defaultRegion: region, withPrefix: true))
        }
        return partialFormatter!.formatter.formatPartial(raw)
    }

    /// What to actually dial: formatting stripped. A +number in your own country is dialled in
    /// national form (e.g. +1 431-334-7050 → 4313347050), which providers like voip.ms accept.
    static func dialString(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard looksLikeNumber(trimmed) else { return trimmed }
        let plain = trimmed.filter { "0123456789+*#".contains($0) }
        if plain.hasPrefix("+"),
           let number = try? utility.parse(plain, withRegion: region, ignoreType: true),
           number.countryCode == utility.countryCode(for: region) {
            return utility.format(number, toType: .national).filter { "0123456789".contains($0) }
        }
        return plain
    }
}
