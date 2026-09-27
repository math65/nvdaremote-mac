import Foundation
import IOKit
import IOKit.hid

/// Drives a HID braille display (usage page 0x41) directly, USB or Bluetooth, while
/// VoiceOver keeps running.
///
/// VoiceOver's generic HID braille driver opens the display in shared mode. Opening it
/// once with `kIOHIDOptionsTypeSeizeDevice` makes the kernel set VoiceOver's handle
/// aside: its writes fail and its keys are dropped, but VoiceOver keeps running. When
/// the display is released, or if this process dies, the kernel gives it back and
/// VoiceOver drives it again by itself. See docs/braille-research.md.
///
/// The device must be opened exactly once, directly with seize: a shared open first
/// (such as `IOHIDManagerOpen`) turns the seize into a silent no-op.
@MainActor
public final class HIDBrailleDisplay {
	public let name: String
	public let cellCount: Int
	/// Called with each NVDA gesture made on the display.
	public var onGesture: ((BrailleGesture) -> Void)?
	public private(set) var isAcquired = false

	private let device: IOHIDDevice
	private let output: IOHIDElement
	/// Router key elements in cell order.
	private let routers: [IOHIDElement]
	private var cells: [UInt8]

	/// Keys held down since the chord started, and router cells pressed in it.
	private var pressedKeys: Set<UInt32> = []
	private var chordKeys: Set<UInt32> = []
	private var pressedRouters: Set<Int> = []
	private var chordRouters: [Int] = []

	/// The first HID braille display connected to the Mac, if any.
	public static func connected() -> HIDBrailleDisplay? {
		let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
		matching[kIOHIDDeviceUsagePageKey] = HIDUsagePage.braille
		let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
		guard service != 0 else { return nil }
		defer { IOObjectRelease(service) }
		guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
		return HIDBrailleDisplay(device: device)
	}

	private init?(device: IOHIDDevice) {
		let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
		guard let output = elements.first(where: {
			IOHIDElementGetType($0) == kIOHIDElementTypeOutput && IOHIDElementGetUsagePage($0) == HIDUsagePage.braille
		}) else { return nil }
		self.device = device
		self.output = output
		cellCount = Int(IOHIDElementGetReportCount(output))
		cells = Array(repeating: 0, count: cellCount)
		// The router keys are identical usages; their order in the report is the cell order.
		routers = elements
			.filter { IOHIDElementGetUsagePage($0) == HIDUsagePage.braille && IOHIDElementGetUsage($0) == HIDBrailleKeys.Usage.routerKey }
			.sorted { IOHIDElementGetCookie($0) < IOHIDElementGetCookie($1) }
		name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Braille display"
	}

	// MARK: - Acquire and release

	/// Takes the display from VoiceOver. Fails when another program holds it
	/// exclusively, for example a VoiceOver brand driver that seizes its displays.
	public func acquire() throws(HIDBrailleDisplayError) {
		guard !isAcquired else { return }
		let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
		guard result == kIOReturnSuccess else { throw .unavailable(result) }
		isAcquired = true
		resetChord()
		IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		IOHIDDeviceRegisterInputValueCallback(device, hidInputCallback, Unmanaged.passUnretained(self).toOpaque())
		writeCells()
	}

	/// Gives the display back; VoiceOver takes it over again by itself.
	public func release() {
		guard isAcquired else { return }
		IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
		IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
		isAcquired = false
	}

	// MARK: - Output

	/// Shows a line of cells (bits = dots 1 to 8), padded or cut to the display width.
	public func show(_ line: [Int]) {
		cells = (0..<cellCount).map { $0 < line.count ? UInt8(line[$0] & 0xFF) : 0 }
		if isAcquired {
			writeCells()
		}
	}

	private func writeCells() {
		let value = cells.withUnsafeBufferPointer {
			IOHIDValueCreateWithBytes(kCFAllocatorDefault, output, mach_absolute_time(), $0.baseAddress!, $0.count)
		}
		if let value {
			IOHIDDeviceSetValue(device, output, value)
		}
	}

	// MARK: - Input

	fileprivate func handle(usagePage: UInt32, usage: UInt32, element: IOHIDElement, pressed: Bool) {
		// The display's keyboard emulation (page 7) and vendor buttons are not NVDA gestures.
		guard usagePage == HIDUsagePage.braille else { return }
		if usage == HIDBrailleKeys.Usage.routerKey {
			guard let cell = routers.firstIndex(where: { $0 == element }) else { return }
			if pressed {
				pressedRouters.insert(cell)
				if !chordRouters.contains(cell) { chordRouters.append(cell) }
			} else {
				pressedRouters.remove(cell)
			}
		} else if pressed {
			pressedKeys.insert(usage)
			chordKeys.insert(usage)
		} else {
			pressedKeys.remove(usage)
		}
		// As in NVDA, a chord becomes a gesture once every key is released.
		if pressedKeys.isEmpty, pressedRouters.isEmpty, !(chordKeys.isEmpty && chordRouters.isEmpty) {
			if let gesture = HIDBrailleKeys.gesture(keys: chordKeys, routerCells: chordRouters) {
				onGesture?(gesture)
			}
			resetChord()
		}
	}

	private func resetChord() {
		pressedKeys.removeAll()
		chordKeys.removeAll()
		pressedRouters.removeAll()
		chordRouters.removeAll()
	}
}

public enum HIDBrailleDisplayError: Error, LocalizedError {
	case unavailable(IOReturn)

	public var errorDescription: String? {
		localized("The braille display is held by another program and cannot be used for the PC.")
	}
}

enum HIDUsagePage {
	static let braille = 0x41
}

/// Scheduled on the main run loop: this callback runs on the main thread.
private func hidInputCallback(
	context: UnsafeMutableRawPointer?,
	result: IOReturn,
	sender: UnsafeMutableRawPointer?,
	value: IOHIDValue,
) {
	guard let context else { return }
	let display = Unmanaged<HIDBrailleDisplay>.fromOpaque(context).takeUnretainedValue()
	let element = IOHIDValueGetElement(value)
	let usagePage = IOHIDElementGetUsagePage(element)
	let usage = IOHIDElementGetUsage(element)
	let pressed = IOHIDValueGetIntegerValue(value) != 0
	nonisolated(unsafe) let unsafeElement = element
	MainActor.assumeIsolated {
		display.handle(usagePage: usagePage, usage: usage, element: unsafeElement, pressed: pressed)
	}
}
