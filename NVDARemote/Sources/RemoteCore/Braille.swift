import Foundation

/// A gesture from the Mac's braille display, sent to NVDA as `braille_input`.
///
/// Each one names the NVDA command to run (`scriptPath`): the PC resolves it in its own
/// global commands, so it does not need to know the display model.
public enum BrailleGesture: Equatable, Sendable {
	case routing(cell: Int)
	case scrollBack
	case scrollForward
	/// One cell typed on the braille keyboard.
	case dots(Int)
	case space
	case enter
	case eraseLastCell
	case translate
	/// Any other NVDA global command, or a key emulation such as `kb:upArrow`.
	case command(String)

	/// Maps a typed cell the way NVDA's braille keyboard bindings do:
	/// dot 7 alone erases, dot 8 alone presses Enter, dots 7 and 8 translate.
	public static func typed(dots: Int) -> BrailleGesture {
		switch dots {
		case 0: .space
		case 0x40: .eraseLastCell
		case 0x80: .enter
		case 0xC0: .translate
		default: .dots(dots)
		}
	}

	var script: String {
		switch self {
		case .routing: "braille_routeTo"
		case .scrollBack: "braille_scrollBack"
		case .scrollForward: "braille_scrollForward"
		case .dots, .space: "braille_dots"
		case .enter: "braille_enter"
		case .eraseLastCell: "braille_eraseLastCell"
		case .translate: "braille_translate"
		case let .command(name): name
		}
	}

	/// The flat dictionary NVDA's `BrailleInputGesture` is rebuilt from on the PC.
	/// `source`, `model` and `id` must be present: the PC reads them to name the gesture.
	var fields: [String: Any] {
		var fields: [String: Any] = [
			"source": "mac",
			"model": "hidBrailleStandard",
			"scriptPath": ["globalCommands", "GlobalCommands", script],
		]
		switch self {
		case let .routing(cell):
			fields["id"] = "routerSet1_routerKey"
			fields["cellIndexes"] = [cell]
			// Legacy field for older NVDA versions that only know routingIndex.
			fields["routingIndex"] = cell
		case .scrollBack:
			fields["id"] = "panLeft"
		case .scrollForward:
			fields["id"] = "panRight"
		case let .dots(dots):
			fields["id"] = "dots"
			fields["dots"] = dots
			fields["space"] = false
		case .space:
			fields["id"] = "space"
			fields["dots"] = 0
			fields["space"] = true
		case .enter:
			fields["id"] = "dot8"
			fields["dots"] = 0x80
			fields["space"] = false
		case .eraseLastCell:
			fields["id"] = "dot7"
			fields["dots"] = 0x40
			fields["space"] = false
		case .translate:
			fields["id"] = "dot7+dot8"
			fields["dots"] = 0xC0
			fields["space"] = false
		case let .command(name):
			fields["id"] = name
		}
		return fields
	}
}

/// Turns key presses on a HID braille display into NVDA gestures, with the bindings of
/// NVDA's own `hidBrailleStandard` driver, so the display does on the PC what it would
/// do plugged into NVDA.
public enum HIDBrailleKeys {
	/// Usages of the HID braille page (0x41) that matter here.
	public enum Usage {
		public static let routerKey: UInt32 = 0x100
		public static let dot1: UInt32 = 0x201
		public static let dot8: UInt32 = 0x208
		public static let space: UInt32 = 0x209
		public static let leftSpace: UInt32 = 0x20A
		public static let rightSpace: UInt32 = 0x20B
		public static let joystickCenter: UInt32 = 0x210
		public static let joystickUp: UInt32 = 0x211
		public static let joystickDown: UInt32 = 0x212
		public static let joystickLeft: UInt32 = 0x213
		public static let joystickRight: UInt32 = 0x214
		public static let dpadCenter: UInt32 = 0x215
		public static let dpadUp: UInt32 = 0x216
		public static let dpadDown: UInt32 = 0x217
		public static let dpadLeft: UInt32 = 0x218
		public static let dpadRight: UInt32 = 0x219
		public static let panLeft: UInt32 = 0x21A
		public static let panRight: UInt32 = 0x21B
		public static let rockerUp: UInt32 = 0x21C
		public static let rockerDown: UInt32 = 0x21D
	}

	/// Space with dots, as in NVDA's `hidBrailleStandard` gesture map.
	static let spaceChords: [Int: String] = [
		0b0000_0001: "kb:upArrow",
		0b0000_1000: "kb:downArrow",
		0b0000_0100: "kb:leftArrow",
		0b0010_0000: "kb:rightArrow",
		0b0001_1101: "showGui",
		0b0000_0101: "kb:shift+tab",
		0b0010_1000: "kb:tab",
		0b0000_1101: "kb:alt",
		0b0001_0001: "kb:escape",
		0b0001_1001: "kb:windows+d",
		0b0000_1100: "kb:windows",
		0b0001_1110: "kb:alt+tab",
		0b0011_1111: "sayAll",
	]

	static let singleKeys: [UInt32: BrailleGesture] = [
		Usage.panLeft: .scrollBack,
		Usage.rockerUp: .scrollBack,
		Usage.panRight: .scrollForward,
		Usage.rockerDown: .scrollForward,
		Usage.joystickUp: .command("kb:upArrow"),
		Usage.dpadUp: .command("kb:upArrow"),
		Usage.joystickDown: .command("kb:downArrow"),
		Usage.dpadDown: .command("kb:downArrow"),
		Usage.joystickLeft: .command("kb:leftArrow"),
		Usage.dpadLeft: .command("kb:leftArrow"),
		Usage.joystickRight: .command("kb:rightArrow"),
		Usage.dpadRight: .command("kb:rightArrow"),
		Usage.joystickCenter: .command("kb:enter"),
		Usage.dpadCenter: .command("kb:enter"),
	]

	/// The gesture for a chord: every key pressed before all of them were released.
	/// - Parameters:
	///   - keys: braille-page usages other than router keys.
	///   - routerCells: cells whose router key was pressed.
	/// - Returns: `nil` when NVDA has no binding for the chord.
	public static func gesture(keys: Set<UInt32>, routerCells: [Int]) -> BrailleGesture? {
		if !routerCells.isEmpty {
			guard keys.isEmpty else { return nil }
			return routerCells.count == 1
				? .routing(cell: routerCells[0])
				: nil
		}
		let dots = keys.reduce(0) { result, usage in
			(Usage.dot1...Usage.dot8).contains(usage) ? result | 1 << Int(usage - Usage.dot1) : result
		}
		let spaces: Set<UInt32> = [Usage.space, Usage.leftSpace, Usage.rightSpace]
		let hasSpace = !keys.isDisjoint(with: spaces)
		let others = keys.subtracting(spaces).filter { !(Usage.dot1...Usage.dot8).contains($0) }

		if !others.isEmpty {
			guard others.count == 1, dots == 0, !hasSpace else { return nil }
			return singleKeys[others.first!]
		}
		if hasSpace {
			return dots == 0 ? .space : spaceChords[dots].map(BrailleGesture.command)
		}
		return dots == 0 ? nil : .typed(dots: dots)
	}
}
