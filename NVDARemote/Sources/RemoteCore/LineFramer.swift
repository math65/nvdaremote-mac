import Foundation

/// Splits the TCP stream into messages: one JSON object per line, terminated by `\n`.
public struct LineFramer: Sendable {
	/// Beyond this, the peer is not following the protocol: discard rather than grow without bound.
	public static let maximumLineLength = 16 * 1024 * 1024

	private var buffer = Data()

	public init() {}

	/// Appends received bytes and returns the complete lines, without the `\n`.
	/// Empty lines are skipped.
	public mutating func append(_ data: Data) -> [Data] {
		buffer.append(data)
		var lines: [Data] = []
		var start = buffer.startIndex
		while let newline = buffer[start...].firstIndex(of: 0x0A) {
			if newline > start {
				lines.append(Data(buffer[start..<newline]))
			}
			start = buffer.index(after: newline)
		}
		buffer.removeSubrange(buffer.startIndex..<start)
		if buffer.count > Self.maximumLineLength {
			buffer.removeAll()
		}
		return lines
	}

	public mutating func reset() {
		buffer.removeAll()
	}
}
