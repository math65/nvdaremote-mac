import Foundation

/// HTTP client for the developer's shared backend (https://mathieumartin.ovh):
/// contact messages, problem reports and launch announcements. The full contract
/// is `docs/API.md` in the app-backend repository.
///
/// The Bearer secret is not versioned (public repository): it is read from
/// `AppBackendSecret.plist` (git-ignored, bundled by the synchronized App group).
/// Without that file the app still builds, `isConfigured` is false and the
/// contact commands are hidden.
final class AppBackendClient {
	enum ContactType: String, CaseIterable, Identifiable {
		// The raw values are the `contact_type` values the server expects.
		case bug
		case suggestion
		case question
		case other

		var id: Self { self }

		var title: LocalizedStringResource {
			switch self {
			case .bug: "Problem"
			case .suggestion: "Suggestion"
			case .question: "Question"
			case .other: "Other"
			}
		}
	}

	enum BackendError: Error, Equatable {
		case notConfigured
		case network
		case rateLimited
		case validation
		case server

		var localizedMessage: String {
			switch self {
			case .notConfigured:
				String(localized: "Messages to the developer are not available in this version.")
			case .network:
				String(localized: "The message could not be sent. Check your internet connection and try again.")
			case .rateLimited:
				String(localized: "Too many messages were sent recently. Try again in an hour.")
			case .validation:
				String(localized: "The message was refused. Check the email address and the message.")
			case .server:
				String(localized: "The server could not take the message. Try again later.")
			}
		}
	}

	/// A report section in the backend's ordered table format (`type: "kv"`).
	struct ReportSection: Encodable {
		struct Row: Encodable {
			let label: String
			let value: String
		}

		let title: String
		let rows: [Row]
		private let type = "kv"

		init(title: String, rows: [Row]) {
			self.title = title
			self.rows = rows
		}

		private enum CodingKeys: String, CodingKey {
			case title, type, rows
		}
	}

	struct Announcement: Decodable, Identifiable {
		let id: String
		let title: String
		let body: String
		let style: String
		let mode: String
		/// Optional second button; the server sends its label already localized.
		let link: Link?

		struct Link: Decodable {
			let label: String
			let url: String
		}
	}

	static let appID = "nvdaremote"

	private static let baseURL = URL(string: "https://mathieumartin.ovh")!

	private static let bundledSecret: String? = {
		guard let url = Bundle.main.url(forResource: "AppBackendSecret", withExtension: "plist"),
			let data = try? Data(contentsOf: url),
			let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			let secret = plist["BearerSecret"] as? String,
			!secret.isEmpty
		else { return nil }
		return secret
	}()

	static var isConfigured: Bool { bundledSecret != nil }

	static var appVersion: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
	}

	private let secret: String?
	private let execute: (URLRequest) async throws -> (Data, URLResponse)

	/// `secret` and `execute` can be injected by tests; by default the client uses the
	/// bundled secret and an ephemeral session (no cache, no cookies).
	init(
		secret: String? = AppBackendClient.bundledSecret,
		execute: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
	) {
		self.secret = secret
		if let execute {
			self.execute = execute
		} else {
			let session = URLSession(configuration: .ephemeral)
			self.execute = { try await session.data(for: $0) }
		}
	}

	// MARK: Contact and report

	func sendContact(email: String, type: ContactType, message: String) async throws {
		struct Body: Encodable {
			let app: String
			let email: String
			let contactType: String
			let message: String
			let appVersion: String

			private enum CodingKeys: String, CodingKey {
				case app, email, message
				case contactType = "contact_type"
				case appVersion = "app_version"
			}
		}
		var request = try makeRequest(path: "/api/feedback/contact")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try encode(Body(
			app: Self.appID,
			email: email,
			contactType: type.rawValue,
			message: message,
			appVersion: Self.appVersion,
		))
		try await perform(request)
	}

	func sendReport(email: String, summary: String, subjectHint: String, sections: [ReportSection]) async throws {
		struct Body: Encodable {
			let app: String
			let email: String
			let summary: String
			let subjectHint: String
			let sections: [ReportSection]

			private enum CodingKeys: String, CodingKey {
				case app, email, summary, sections
				case subjectHint = "subject_hint"
			}
		}
		let json = try encode(Body(
			app: Self.appID,
			email: email,
			summary: summary,
			subjectHint: subjectHint,
			sections: sections,
		))
		let boundary = "nvdaremote-" + UUID().uuidString
		var request = try makeRequest(path: "/api/feedback/report")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.httpBody = multipartBody(boundary: boundary, reportJSON: json)
		try await perform(request)
	}

	// MARK: Announcements

	func checkAnnouncement(installID: String, language: String) async throws -> Announcement? {
		struct Body: Encodable {
			let app: String
			let installID: String
			let lang: String

			private enum CodingKeys: String, CodingKey {
				case app, lang
				case installID = "install_id"
			}
		}
		struct Response: Decodable {
			let ok: Bool
			let announcement: Announcement?
		}
		var request = try makeRequest(path: "/api/announce/check")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try encode(Body(app: Self.appID, installID: installID, lang: language))

		let (data, response): (Data, URLResponse)
		do {
			(data, response) = try await execute(request)
		} catch {
			throw BackendError.network
		}
		guard let http = response as? HTTPURLResponse, http.statusCode == 200,
			let decoded = try? JSONDecoder().decode(Response.self, from: data),
			decoded.ok
		else { throw BackendError.server }
		return decoded.announcement
	}

	/// Tells the backend the announcement was shown. Failures are ignored: at worst
	/// the reach counter is a little low.
	func acknowledgeAnnouncement(installID: String, announcementID: String) async {
		await sendAnnouncementEvent(path: "/api/announce/ack", installID: installID, announcementID: announcementID)
	}

	/// Tells the backend the announcement's link button was used.
	func reportAnnouncementClick(installID: String, announcementID: String) async {
		await sendAnnouncementEvent(path: "/api/announce/click", installID: installID, announcementID: announcementID)
	}

	private func sendAnnouncementEvent(path: String, installID: String, announcementID: String) async {
		struct Body: Encodable {
			let app: String
			let installID: String
			let id: String

			private enum CodingKeys: String, CodingKey {
				case app, id
				case installID = "install_id"
			}
		}
		guard var request = try? makeRequest(path: path),
			let data = try? encode(Body(app: Self.appID, installID: installID, id: announcementID))
		else { return }
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = data
		_ = try? await execute(request)
	}

	// MARK: Plumbing

	private struct APIResponse: Decodable {
		let ok: Bool
		let errorCode: String?

		private enum CodingKeys: String, CodingKey {
			case ok
			case errorCode = "error_code"
		}
	}

	private func makeRequest(path: String) throws -> URLRequest {
		guard let secret else { throw BackendError.notConfigured }
		var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
		request.httpMethod = "POST"
		request.timeoutInterval = 30
		request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
		return request
	}

	private func encode(_ body: some Encodable) throws -> Data {
		do {
			return try JSONEncoder().encode(body)
		} catch {
			throw BackendError.validation
		}
	}

	private func perform(_ request: URLRequest) async throws {
		let (data, response): (Data, URLResponse)
		do {
			(data, response) = try await execute(request)
		} catch {
			throw BackendError.network
		}
		guard let http = response as? HTTPURLResponse else { throw BackendError.network }
		guard http.statusCode != 200 else { return }
		// Errors come as {ok: false, error_code: "..."}; branch on the code, never
		// on the message. An unreadable body counts as a server error.
		switch (try? JSONDecoder().decode(APIResponse.self, from: data))?.errorCode {
		case "rate_limited": throw BackendError.rateLimited
		case "validation_error", "invalid_json": throw BackendError.validation
		default: throw BackendError.server
		}
	}

	private func multipartBody(boundary: String, reportJSON: Data) -> Data {
		var body = Data()
		func append(_ string: String) { body.append(Data(string.utf8)) }
		append("--\(boundary)\r\n")
		append("Content-Disposition: form-data; name=\"report\"\r\n")
		append("Content-Type: application/json\r\n\r\n")
		body.append(reportJSON)
		append("\r\n--\(boundary)--\r\n")
		return body
	}
}
