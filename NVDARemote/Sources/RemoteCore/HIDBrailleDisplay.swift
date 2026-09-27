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
	/// Called when the display disappears (unplugged, Bluetooth lost, Mac asleep).
	public var onRemoval: (() -> Void)?
	public private(set) var isAcquired = false

	private let device: IOHIDDevice
	private let output: IOHIDElement
	/// Router key elements of router set 1, in cell order.
	private let routers: [IOHIDElement]
	private var cells: [UInt8]
	private var writtenCells: [UInt8]?

	/// A key held down: a braille-page usage, or the router key of a cell.
	private enum Key: Hashable {
		case usage(UInt32)
		case router(Int)
	}

	private var keysDown: Set<Key> = []
	private var ignoresReleases = false

	/// The first HID braille display connected to the Mac, if any.
	public static func connected() -> HIDBrailleDisplay? {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, brailleMatching())
		guard service != 0 else { return nil }
		defer { IOObjectRelease(service) }
		guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
		return HIDBrailleDisplay(device: device)
	}

	nonisolated static func brailleMatching() -> NSMutableDictionary {
		let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
		matching[kIOHIDDeviceUsagePageKey] = HIDUsagePage.braille
		return matching
	}

	private init?(device: IOHIDDevice) {
		let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
		func isBraille(_ element: IOHIDElement) -> Bool { IOHIDElementGetUsagePage(element) == HIDUsagePage.braille }
		func parentUsage(_ element: IOHIDElement) -> UInt32? { IOHIDElementGetParent(element).map(IOHIDElementGetUsage) }

		// As in NVDA: the cells are 8-dot or 6-dot cell outputs of a braille row.
		let outputs = elements.filter { IOHIDElementGetType($0) == kIOHIDElementTypeOutput && isBraille($0) }
		guard let output = outputs.first(where: {
			[HIDBrailleUsage.eightDotCell, HIDBrailleUsage.sixDotCell].contains(IOHIDElementGetUsage($0))
				&& parentUsage($0) == HIDBrailleUsage.brailleRow
		}) ?? outputs.first else { return nil }
		self.device = device
		self.output = output
		cellCount = Int(IOHIDElementGetReportCount(output))
		cells = Array(repeating: 0, count: cellCount)
		// Router keys are identical usages; within router set 1, report order is cell order.
		// A second row of routers (router set 2) is left out.
		let routerKeys = elements.filter { isBraille($0) && IOHIDElementGetUsage($0) == HIDBrailleKeys.Usage.routerKey }
		let firstSet = routerKeys.filter { parentUsage($0) == HIDBrailleUsage.routerSet1 }
		routers = (firstSet.isEmpty ? routerKeys : firstSet).sorted { IOHIDElementGetCookie($0) < IOHIDElementGetCookie($1) }
		name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? localized("Braille display")
	}

	// MARK: - Acquire and release

	/// Takes the display from VoiceOver. Fails when another program holds it
	/// exclusively, for example a VoiceOver brand driver that seizes its displays.
	public func acquire() throws(HIDBrailleDisplayError) {
		guard !isAcquired else { return }
		let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
		guard result == kIOReturnSuccess else { throw .unavailable(result) }
		isAcquired = true
		keysDown.removeAll()
		ignoresReleases = false
		writtenCells = nil
		let context = Unmanaged.passUnretained(self).toOpaque()
		IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		IOHIDDeviceRegisterInputValueCallback(device, hidInputCallback, context)
		IOHIDDeviceRegisterRemovalCallback(device, hidRemovalCallback, context)
		writeCells()
	}

	/// Gives the display back; VoiceOver takes it over again by itself.
	public func release() {
		guard isAcquired else { return }
		IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
		IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
		IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
		isAcquired = false
	}

	fileprivate func handleRemoval() {
		release()
		onRemoval?()
	}

	// MARK: - Output

	/// Shows a line of cells (bits = dots 1 to 8), padded or cut to the display width.
	public func show(_ line: [Int]) {
		cells = (0..<cellCount).map { $0 < line.count ? UInt8(line[$0] & 0xFF) : 0 }
		if isAcquired {
			writeCells()
		}
	}

	/// Writes only when the line changed: each write is a round trip to the display.
	private func writeCells() {
		guard cells != writtenCells else { return }
		let value = cells.withUnsafeBufferPointer {
			IOHIDValueCreateWithBytes(kCFAllocatorDefault, output, mach_absolute_time(), $0.baseAddress!, $0.count)
		}
		if let value, IOHIDDeviceSetValue(device, output, value) == kIOReturnSuccess {
			writtenCells = cells
		}
	}

	// MARK: - Input

	/// Same logic as NVDA's `hidBrailleStandard` driver: a press starts a new
	/// combination; the first release sends the keys held at that moment, and the
	/// following releases of the same combination are ignored. So space held with dot 4
	/// tapped three times gives three down arrows.
	fileprivate func handle(usagePage: UInt32, usage: UInt32, element: IOHIDElement, pressed: Bool) {
		// The display's keyboard emulation (page 7) and vendor buttons are not NVDA gestures.
		guard usagePage == HIDUsagePage.braille else { return }
		let key: Key
		if usage == HIDBrailleKeys.Usage.routerKey {
			guard let cell = routers.firstIndex(where: { $0 == element }) else { return }
			key = .router(cell)
		} else {
			key = .usage(usage)
		}
		var keys = keysDown
		if pressed { keys.insert(key) } else { keys.remove(key) }
		if keys.count > keysDown.count {
			ignoresReleases = false
		} else if keys.count < keysDown.count, !ignoresReleases {
			sendGesture(for: keysDown)
			ignoresReleases = true
		}
		keysDown = keys
	}

	private func sendGesture(for keys: Set<Key>) {
		var usages: Set<UInt32> = []
		var routerCells: [Int] = []
		for key in keys {
			switch key {
			case let .usage(usage): usages.insert(usage)
			case let .router(cell): routerCells.append(cell)
			}
		}
		if let gesture = HIDBrailleKeys.gesture(keys: usages, routerCells: routerCells) {
			onGesture?(gesture)
		}
	}
}

/// Tells when a HID braille display appears or disappears, without opening it: an open
/// here would turn a later seize into a no-op.
@MainActor
public final class HIDBrailleDisplayMonitor {
	public var onChange: (() -> Void)?

	private let port: IONotificationPortRef
	private var iterators: [io_iterator_t] = []

	public init() {
		port = IONotificationPortCreate(kIOMainPortDefault)
		CFRunLoopAddSource(
			CFRunLoopGetMain(),
			IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
			.commonModes,
		)
		let context = Unmanaged.passUnretained(self).toOpaque()
		for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
			var iterator: io_iterator_t = 0
			let result = IOServiceAddMatchingNotification(
				port, notification, HIDBrailleDisplay.brailleMatching(), monitorCallback, context, &iterator)
			guard result == KERN_SUCCESS else { continue }
			// The iterator must be drained once to arm the notification.
			Self.drain(iterator)
			iterators.append(iterator)
		}
	}

	nonisolated static func drain(_ iterator: io_iterator_t) {
		while case let service = IOIteratorNext(iterator), service != 0 {
			IOObjectRelease(service)
		}
	}

	fileprivate func changed() {
		onChange?()
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

/// Collection and output usages of the braille page, as used by NVDA.
enum HIDBrailleUsage {
	static let brailleRow: UInt32 = 0x02
	static let eightDotCell: UInt32 = 0x03
	static let sixDotCell: UInt32 = 0x04
	static let routerSet1: UInt32 = 0xFA
}

// These callbacks are scheduled on the main run loop: they run on the main thread.

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

private func hidRemovalCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?) {
	guard let context else { return }
	let display = Unmanaged<HIDBrailleDisplay>.fromOpaque(context).takeUnretainedValue()
	MainActor.assumeIsolated {
		display.handleRemoval()
	}
}

private func monitorCallback(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
	HIDBrailleDisplayMonitor.drain(iterator)
	guard let context else { return }
	let monitor = Unmanaged<HIDBrailleDisplayMonitor>.fromOpaque(context).takeUnretainedValue()
	MainActor.assumeIsolated {
		monitor.changed()
	}
}
