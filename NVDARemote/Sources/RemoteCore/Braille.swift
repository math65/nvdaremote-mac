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
	/// Several router keys pressed together: NVDA selects from the first to the last cell.
	case selectRange(cells: [Int])
	/// Any other NVDA global command, or a key emulation such as `kb:upArrow`, with the
	/// display's gesture name (such as `space+dot1`), shown by NVDA's input help.
	case command(String, id: String)

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
		case .selectRange: "braille_selectRange"
		case let .command(name, _): name
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
		case let .selectRange(cells):
			// NVDA only sends routingIndex for single-cell presses.
			fields["id"] = "routerSet1_multiRouterKey"
			fields["cellIndexes"] = cells
		case let .command(_, id):
			fields["id"] = id
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

	/// Other keys, by NVDA script, as in NVDA's `hidBrailleStandard` gesture map.
	static let singleKeys: [UInt32: String] = [
		Usage.panLeft: "braille_scrollBack",
		Usage.rockerUp: "braille_scrollBack",
		Usage.panRight: "braille_scrollForward",
		Usage.rockerDown: "braille_scrollForward",
		Usage.joystickUp: "kb:upArrow",
		Usage.dpadUp: "kb:upArrow",
		Usage.joystickDown: "kb:downArrow",
		Usage.dpadDown: "kb:downArrow",
		Usage.joystickLeft: "kb:leftArrow",
		Usage.dpadLeft: "kb:leftArrow",
		Usage.joystickRight: "kb:rightArrow",
		Usage.dpadRight: "kb:rightArrow",
		Usage.joystickCenter: "kb:enter",
		Usage.dpadCenter: "kb:enter",
	]

	/// NVDA's name for a key of the braille page, as its driver derives it from the usage.
	static let keyNames: [UInt32: String] = [
		Usage.space: "space", Usage.leftSpace: "leftSpace", Usage.rightSpace: "rightSpace",
		Usage.joystickCenter: "joystickCenter", Usage.joystickUp: "joystickUp", Usage.joystickDown: "joystickDown",
		Usage.joystickLeft: "joystickLeft", Usage.joystickRight: "joystickRight",
		Usage.dpadCenter: "dpadCenter", Usage.dpadUp: "dpadUp", Usage.dpadDown: "dpadDown",
		Usage.dpadLeft: "dpadLeft", Usage.dpadRight: "dpadRight",
		Usage.panLeft: "panLeft", Usage.panRight: "panRight", Usage.rockerUp: "rockerUp", Usage.rockerDown: "rockerDown",
	]

	static func gestureName(_ keys: Set<UInt32>) -> String {
		keys.sorted().map { usage in
			(Usage.dot1...Usage.dot8).contains(usage) ? "dot\(usage - Usage.dot1 + 1)" : keyNames[usage] ?? "brailleUsage\(usage)"
		}.joined(separator: "+")
	}

	/// The gesture for a chord: the keys held when the first of them was released.
	/// - Parameters:
	///   - keys: braille-page usages other than router keys.
	///   - routerCells: cells whose router key was held.
	/// - Returns: `nil` when NVDA has no binding for the chord.
	public static func gesture(keys: Set<UInt32>, routerCells: [Int]) -> BrailleGesture? {
		if !routerCells.isEmpty {
			guard keys.isEmpty else { return nil }
			let cells = routerCells.sorted()
			return cells.count == 1 ? .routing(cell: cells[0]) : .selectRange(cells: cells)
		}
		let dots = keys.reduce(0) { result, usage in
			(Usage.dot1...Usage.dot8).contains(usage) ? result | 1 << Int(usage - Usage.dot1) : result
		}
		let spaces: Set<UInt32> = [Usage.space, Usage.leftSpace, Usage.rightSpace]
		let hasSpace = !keys.isDisjoint(with: spaces)
		let others = keys.subtracting(spaces).filter { !(Usage.dot1...Usage.dot8).contains($0) }

		if !others.isEmpty {
			guard others.count == 1, dots == 0, !hasSpace, let script = singleKeys[others.first!] else { return nil }
			return .command(script, id: gestureName(keys))
		}
		if hasSpace {
			if dots == 0 { return .space }
			return spaceChords[dots].map { .command($0, id: gestureName(keys)) }
		}
		return dots == 0 ? nil : .typed(dots: dots)
	}
}
