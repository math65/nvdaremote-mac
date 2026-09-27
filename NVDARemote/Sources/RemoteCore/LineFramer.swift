import Foundation

/// Splits the TCP stream into messages: one JSON object per line, terminated by `\n`.
public struct LineFramer: Sendable {
	/// Beyond this, the peer is not following the protocol: discard rather than grow
	/// without bound. Large enough for any clipboard NVDA would send.
	public static let maximumLineLength = 64 * 1024 * 1024

	private var buffer = Data()
	/// How far the buffer has already been searched for a newline, so a long line
	/// arriving in many chunks is not rescanned from the start each time.
	private var scanned = 0

	public init() {}

	/// Appends received bytes and returns the complete lines, without the `\n`.
	/// Empty lines are skipped.
	public mutating func append(_ data: Data) -> [Data] {
		buffer.append(data)
		var lines: [Data] = []
		var start = buffer.startIndex
		var searchFrom = buffer.index(buffer.startIndex, offsetBy: scanned)
		while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
			if newline > start {
				lines.append(Data(buffer[start..<newline]))
			}
			start = buffer.index(after: newline)
			searchFrom = start
		}
		buffer.removeSubrange(buffer.startIndex..<start)
		scanned = buffer.count
		if buffer.count > Self.maximumLineLength {
			buffer.removeAll()
			scanned = 0
		}
		return lines
	}

	public mutating func reset() {
		buffer.removeAll()
		scanned = 0
	}
}
