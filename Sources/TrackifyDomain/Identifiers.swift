import Foundation

public struct Identifier<Tag>: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func random() -> Self {
        Self(UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

public enum DiscoveryRootTag: Sendable {}
public enum RepositoryTag: Sendable {}
public enum WorkingCopyTag: Sendable {}
public enum SessionTag: Sendable {}
public enum MessageTag: Sendable {}
public enum RunTag: Sendable {}
public enum EventTag: Sendable {}
public enum EvidenceTag: Sendable {}
public enum ReportTag: Sendable {}
public enum WorkIntervalTag: Sendable {}
public enum RecipeTag: Sendable {}
public enum RecipeVersionTag: Sendable {}
public enum ReportRunTag: Sendable {}
public enum ArtifactTag: Sendable {}
public enum DestinationTag: Sendable {}
public enum DeliveryAttemptTag: Sendable {}
public enum ReportScheduleTag: Sendable {}
public enum SummaryTag: Sendable {}
public enum SummaryRunTag: Sendable {}
public enum ConversationRecordTag: Sendable {}
public enum LogicalTurnTag: Sendable {}
public enum LogicalMessageTag: Sendable {}
public enum EvidenceQualityIssueTag: Sendable {}

public typealias DiscoveryRootID = Identifier<DiscoveryRootTag>
public typealias RepositoryID = Identifier<RepositoryTag>
public typealias WorkingCopyID = Identifier<WorkingCopyTag>
public typealias SessionID = Identifier<SessionTag>
public typealias MessageID = Identifier<MessageTag>
public typealias RunID = Identifier<RunTag>
public typealias EventID = Identifier<EventTag>
public typealias EvidenceID = Identifier<EvidenceTag>
public typealias ReportID = Identifier<ReportTag>
public typealias WorkIntervalID = Identifier<WorkIntervalTag>
public typealias RecipeID = Identifier<RecipeTag>
public typealias RecipeVersionID = Identifier<RecipeVersionTag>
public typealias ReportRunID = Identifier<ReportRunTag>
public typealias ArtifactID = Identifier<ArtifactTag>
public typealias DestinationID = Identifier<DestinationTag>
public typealias DeliveryAttemptID = Identifier<DeliveryAttemptTag>
public typealias ReportScheduleID = Identifier<ReportScheduleTag>
public typealias SummaryID = Identifier<SummaryTag>
public typealias SummaryRunID = Identifier<SummaryRunTag>
public typealias ConversationRecordID = Identifier<ConversationRecordTag>
public typealias LogicalTurnID = Identifier<LogicalTurnTag>
public typealias LogicalMessageID = Identifier<LogicalMessageTag>
public typealias EvidenceQualityIssueID = Identifier<EvidenceQualityIssueTag>
