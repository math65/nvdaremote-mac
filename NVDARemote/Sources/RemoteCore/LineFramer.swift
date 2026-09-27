import Foundation

/// Découpe le flux TCP en messages : un objet JSON par ligne, terminé par `\n`.
public struct LineFramer: Sendable {
	/// Au-delà, le pair ne respecte pas le protocole : on jette plutôt que de grossir sans fin.
	public static let maximumLineLength = 16 * 1024 * 1024

	private var buffer = Data()

	public init() {}

	/// Ajoute des octets reçus et renvoie les lignes complètes, sans le `\n`.
	/// Les lignes vides sont ignorées.
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
