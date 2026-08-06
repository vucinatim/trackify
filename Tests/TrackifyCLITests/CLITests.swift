import Foundation
import Testing
import TrackifyDomain

@testable import TrackifyCLI

@Suite("CLI surface")
struct CLITests {
    @Test("Root command has a stable name")
    func commandName() {
        #expect(TrackifyCommand.configuration.commandName == "trackify")
        let commands = Set(
            TrackifyCommand.configuration.subcommands.compactMap { $0.configuration.commandName })
        #expect(commands.isSuperset(of: ["sources", "usage", "recipes", "artifacts"]))
        #expect(Providers.configuration.subcommands.count == 4)
    }

    @Test("Context JSON stays inside its total byte budget")
    func boundedContextJSON() throws {
        let data = try JSONOutput.contextData(
            rendered: String(repeating: "message with a newline\n", count: 1_000),
            mode: "today-all",
            maximumBytes: 2_000
        )
        let payload = try JSONDecoder().decode(ContextPayload.self, from: data)

        #expect(data.count + 1 <= 2_000)
        #expect(payload.truncated)
        #expect(payload.mode == "today-all")
    }

    @Test("Report JSON omits evidence identifiers by default")
    func compactReportJSON() throws {
        let report = WorkReport(
            id: ReportID("report"),
            periodStart: Date(timeIntervalSince1970: 1_754_294_400),
            periodEnd: Date(timeIntervalSince1970: 1_754_298_000),
            state: .completed,
            summary: "Completed the work.",
            evidenceIDs: [EvidenceID("one"), EvidenceID("two")],
            provider: nil,
            model: nil,
            generatorVersion: "test",
            revision: 1
        )
        let payload = ReportPayload(report: report, evidenceLimit: 0)
        let data = try JSONOutput.encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try #require(object["report"] as? [String: Any])

        #expect(record["evidenceCount"] as? Int == 2)
        #expect((record["evidenceIDs"] as? [String])?.isEmpty == true)
        #expect(record["omittedEvidenceCount"] as? Int == 2)
    }
}
