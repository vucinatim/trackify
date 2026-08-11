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
        let value = """
            token: example-secret-value-123
            SERVICE_API_KEY=another-secret-value-456
            /var/folders/aa/private/Screenshot.png
            /tmp/trackify-secret.json
            """
        let redacted = SensitiveText.redact(value)

        #expect(!redacted.contains("example-secret-value-123"))
        #expect(!redacted.contains("another-secret-value-456"))
        #expect(redacted.contains("token: [REDACTED_SECRET]"))
        #expect(redacted.contains("SERVICE_API_KEY=[REDACTED_SECRET]"))
        #expect(!redacted.contains("Screenshot.png"))
        #expect(!redacted.contains("trackify-secret.json"))
        #expect(redacted.contains("[TEMP_PATH]"))
    }

    @Test("Message sanitization removes transport-only image markup")
    func attachmentSanitization() {
        let plain = "Please fix the calendar layout."
        let attached = plain + "\n\n<image name=[Image #1] path=\"/tmp/calendar.png\">\n</image>"

        #expect(MessageTextSanitizer.sanitize(attached) == plain)
        #expect(MessageTextSanitizer.canonicalKey(attached) == MessageTextSanitizer.canonicalKey(plain))
    }

    @Test("Internal transport envelopes are not work evidence")
    func internalMessageVisibility() {
        func message(_ text: String) -> ConversationMessage {
            ConversationMessage(
                id: MessageID(text), sessionID: SessionID("session"), role: .user,
                occurredAt: Date(), normalizedText: text, fingerprint: text)
        }
        #expect(ConversationMessageVisibility.isWorkEvidence(message("Please finish the reports UI.")))
        #expect(
            !ConversationMessageVisibility.isWorkEvidence(
                message("<codex_internal_context source=\"goal\">Continue working</codex_internal_context>")))
        #expect(
            !ConversationMessageVisibility.isWorkEvidence(
                message("<app-context>private transport metadata</app-context>")))
        #expect(
            !ConversationMessageVisibility.isWorkEvidence(
                message("<local-command-caveat>Do not treat this as intent.</local-command-caveat>")))
        #expect(
            !ConversationMessageVisibility.isWorkEvidence(
                message("# AGENTS.md instructions for /Users/person/project")))
        let attachment = message(
            """
            # Files mentioned by the user:

            ## Screenshot.png: /var/folders/private/Screenshot.png

            ## My request for Codex:
            Please fix the summary grouping.
            """)
        #expect(
            ConversationMessageVisibility.workText(attachment)
                == "Please fix the summary grouping.")
    }

    @Test("Codex credit estimation follows published model rates without double-counting reasoning")
    func codexCreditEstimate() throws {
        let record = GenerationUsageRecord(
            provider: .codex, model: "gpt-5.6-sol",
            estimatedInputTokens: nil,
            usage: ProviderUsage(
                inputTokens: 44_313, cachedInputTokens: 0,
                outputTokens: 2_265, reasoningTokens: 1_000))
        let credits = try #require(GenerationCreditEstimator.credits(for: record))
        #expect(credits == Decimal(string: "7.237875"))
        #expect(
            GenerationCreditEstimator.credits(
                provider: .claude, model: "opus", inputTokens: 10_000,
                outputTokens: 1_000) == nil)
    }
}
