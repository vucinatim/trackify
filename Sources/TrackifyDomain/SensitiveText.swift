import Foundation

public enum SensitiveText {
    private static let replacements: [(pattern: String, replacement: String)] = [
        (#"/Users/[^/\s]+"#, "/Users/[REDACTED_USER]"),
        (#"/home/[^/\s]+"#, "/home/[REDACTED_USER]"),
        (#"(?:/private)?/var/folders/[^\s\"']+"#, "[TEMP_PATH]"),
        (#"/tmp/[^\s\"']+"#, "[TEMP_PATH]"),
        (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "[REDACTED_OPENAI_KEY]"),
        (#"\bgh[pousr]_[A-Za-z0-9]{12,}\b"#, "[REDACTED_GITHUB_TOKEN]"),
        (#"\bAKIA[A-Z0-9]{16}\b"#, "[REDACTED_AWS_KEY]"),
        (#"\bxox[a-z]-[A-Za-z0-9-]{12,}\b"#, "[REDACTED_SLACK_TOKEN]"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "[REDACTED_JWT]"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{8,}=*"#, "Bearer [REDACTED_TOKEN]"),
        (
            #"(?i)\b(token|api[_ -]?key|secret|password|authorization)\b(\s*[:=]\s*)[\"']?[A-Za-z0-9._~+/$\-=]{8,}[\"']?"#,
            "$1$2[REDACTED_SECRET]"
        ),
        (
            #"(?i)(\b[A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD)\b)(\s*=\s*)[\"']?[A-Za-z0-9._~+/$\-=]{8,}[\"']?"#,
            "$1$2[REDACTED_SECRET]"
        ),
        (#"(?i)(https?://[^\s:/@]+:)[^\s/@]+@"#, "$1[REDACTED_PASSWORD]@"),
        (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
    ]

    public static func redact(_ value: String, privatePaths: [String] = []) -> String {
        let pathRedacted =
            privatePaths
            .filter { !$0.isEmpty && $0 != "/" }
            .sorted { $0.count > $1.count }
            .reduce(value) { result, path in
                result.replacingOccurrences(of: path, with: "[REPOSITORY_PATH]")
            }
        return replacements.reduce(pathRedacted) { result, replacement in
            result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.replacement,
                options: .regularExpression
            )
        }
    }
}

public enum MessageTextSanitizer {
    private static let attachmentPatterns = [
        #"(?s)<image\b[^>]*>.*?</image>"#,
        #"(?s)<image\b[^>]*/>"#,
    ]

    public static func sanitize(_ value: String) -> String {
        let redacted = SensitiveText.redact(value)
        let withoutAttachments = removingAttachments(redacted)
        let sanitized = withoutAttachments.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "[Attachment]"
            : sanitized
    }

    public static func removingAttachments(_ value: String) -> String {
        attachmentPatterns.reduce(value) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    public static func canonicalKey(_ value: String) -> String {
        sanitize(value)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
