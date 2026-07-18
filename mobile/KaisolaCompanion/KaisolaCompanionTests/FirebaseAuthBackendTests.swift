import Foundation
import XCTest
@testable import KaisolaCompanion

final class FirebaseAuthBackendTests: XCTestCase {
    func testConfigurationParsesBundledShape() throws {
        let data = Data(#"""
        {
          "projectId": "kaisola-a9ab7",
          "apiKey": "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
          "serverUrl": "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session"
        }
        """#.utf8)

        let configuration = try FirebaseAuthConfiguration.parse(data)

        XCTAssertEqual(configuration.projectId, "kaisola-a9ab7")
        XCTAssertEqual(configuration.apiKey, "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY")
        XCTAssertEqual(
            configuration.serverURL,
            URL(string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session")
        )
    }

    func testConfigurationRejectsNonHTTPSVerificationServer() {
        let data = Data(#"""
        {
          "projectId": "kaisola-a9ab7",
          "apiKey": "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
          "serverUrl": "http://localhost/session"
        }
        """#.utf8)

        XCTAssertThrowsError(try FirebaseAuthConfiguration.parse(data))
    }

    func testCallbackParsesRawPostBodyForIdentityToolkit() throws {
        let continueURI = try XCTUnwrap(URL(string: "kaisola://auth"))
        let callback = try FirebaseAuthCallback.parse(
            try XCTUnwrap(URL(string: "kaisola://auth?code=a%2Bb%3D&state=state-123")),
            expectedContinueURI: continueURI
        )

        XCTAssertEqual(callback.requestURI, "kaisola://auth")
        XCTAssertEqual(callback.postBody, "code=a%2Bb%3D&state=state-123")
    }

    func testCallbackRejectsAURLOutsideTheRegisteredScheme() throws {
        let continueURI = try XCTUnwrap(URL(string: "kaisola://auth"))

        XCTAssertThrowsError(
            try FirebaseAuthCallback.parse(
                try XCTUnwrap(URL(string: "attacker://auth?code=stolen")),
                expectedContinueURI: continueURI
            )
        )
    }

    func testCallbackMapsGoogleAccessDeniedToCancellation() throws {
        let continueURI = try XCTUnwrap(URL(string: "kaisola://auth"))

        XCTAssertThrowsError(
            try FirebaseAuthCallback.parse(
                try XCTUnwrap(URL(string: "kaisola://auth?error=access_denied")),
                expectedContinueURI: continueURI
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSessionVaultRoundTripsAndClearsThroughMockSecureStore() throws {
        let store = InMemoryAuthSecureStore()
        let vault = AuthSessionVault(store: store)
        let account = AuthAccount(
            uid: "firebase-uid",
            email: "person@example.com",
            displayName: "Kaisola Person",
            avatarURL: URL(string: "https://example.com/avatar.png")
        )

        try vault.save(refreshToken: "refresh-token-only", account: account)

        XCTAssertEqual(try vault.refreshToken(), "refresh-token-only")
        XCTAssertEqual(try vault.account(), account)
        XCTAssertEqual(store.values.count, 2)

        try vault.clear()

        XCTAssertNil(try vault.refreshToken())
        XCTAssertNil(try vault.account())
        XCTAssertTrue(store.values.isEmpty)
    }
}

private final class InMemoryAuthSecureStore: AuthSecureStoring {
    var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        values[key]
    }

    func set(_ data: Data, for key: String) throws {
        values[key] = data
    }

    func removeData(for key: String) throws {
        values.removeValue(forKey: key)
    }
}
