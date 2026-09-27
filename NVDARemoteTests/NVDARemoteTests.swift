//
//  NVDARemoteTests.swift
//  NVDARemoteTests
//
//  Created by Mathieu Martin on 28/09/2026.
//

import Testing
@testable import NVDARemote

@MainActor
struct NVDARemoteTests {

	/// Certificate fingerprints are shown in groups of four, easier to compare by ear or in braille.
	@Test func fingerprintIsGroupedByFour() {
		#expect(AppModel.grouped("54fd178e0e266ab0") == "54fd 178e 0e26 6ab0")
		#expect(AppModel.grouped("abcdef") == "abcd ef")
		#expect(AppModel.grouped("") == "")
	}
}
