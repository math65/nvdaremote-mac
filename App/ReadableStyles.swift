import AppKit
import SwiftUI

// Text colors with enough contrast. The system grey (`.secondary`) measured 3.08:1 on
// the grouped form background, and the system red about 3.3:1, below the 4.5:1 that
// WCAG AA asks for small text. Taken from the developer's DSMAccess, where the blend
// fractions were measured in both appearances.

extension ShapeStyle where Self == Color {
	/// Replaces `.secondary` for text that carries information.
	static var readableSecondary: Color { Color.primary.opacity(0.8) }

	static var readableRed: Color { .readable(.systemRed) }
	static var readableOrange: Color { .readable(.systemOrange) }
}

private extension Color {
	static let lightBlendFraction: CGFloat = 0.45
	static let darkBlendFraction: CGFloat = 0.25

	static func readable(_ base: NSColor) -> Color {
		Color(nsColor: NSColor(name: nil) { appearance in
			let blend = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
				? base.blended(withFraction: darkBlendFraction, of: .white)
				: base.blended(withFraction: lightBlendFraction, of: .black)
			return blend ?? base
		})
	}
}

/// An explanation shown under a control for sighted users. VoiceOver users get the
/// same text as the control's hint, so it is hidden from VoiceOver to avoid reading
/// it twice: pair it with `.accessibilityHint` on the control. When the text is said
/// nowhere else, pass `readByVoiceOver: true`.
struct HelpText: View {
	let text: LocalizedStringKey
	var readByVoiceOver = false

	init(_ text: LocalizedStringKey, readByVoiceOver: Bool = false) {
		self.text = text
		self.readByVoiceOver = readByVoiceOver
	}

	var body: some View {
		Text(text)
			.font(.callout)
			.foregroundStyle(.readableSecondary)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityHidden(!readByVoiceOver)
	}
}
