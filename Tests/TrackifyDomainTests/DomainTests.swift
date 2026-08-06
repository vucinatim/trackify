import Foundation
import Testing

@testable import TrackifyDomain

@Suite("Domain primitives")
struct DomainTests {
    @Test("Typed identifiers round-trip through Codable")
    func identifierRoundTrip() throws {
        let original = RepositoryID("repo-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepositoryID.self, from: data)
        #expect(decoded == original)
        #expect(decoded.description == "repo-1")
    }

    @Test("Fixed clock never consults system time")
    func fixedClock() {
        let instant = Date(timeIntervalSince1970: 1_754_294_400)
        #expect(FixedWallClock(instant).now() == instant)
    }

    @Test("Sensitive text redacts contextual credentials")
    func contextualSecretRedaction() {
        let value = "token: example-secret-value-123\nSERVICE_API_KEY=another-secret-value-456"
        let redacted = SensitiveText.redact(value)

        #expect(!redacted.contains("example-secret-value-123"))
        #expect(!redacted.contains("another-secret-value-456"))
        #expect(redacted.contains("token: [REDACTED_SECRET]"))
        #expect(redacted.contains("SERVICE_API_KEY=[REDACTED_SECRET]"))
    }

    @Test("Message sanitization removes transport-only image markup")
    func attachmentSanitization() {
        let plain = "Please fix the calendar layout."
        let attached = plain + "\n\n<image name=[Image #1] path=\"/tmp/calendar.png\">\n</image>"

        #expect(MessageTextSanitizer.sanitize(attached) == plain)
        #expect(MessageTextSanitizer.canonicalKey(attached) == MessageTextSanitizer.canonicalKey(plain))
    }
}
