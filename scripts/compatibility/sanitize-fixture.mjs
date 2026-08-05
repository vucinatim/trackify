const enumKeys = new Set([
  "direction",
  "effort",
  "entrypoint",
  "historyMode",
  "itemsView",
  "operation",
  "permissionMode",
  "phase",
  "role",
  "source",
  "status",
  "stop_reason",
  "subtype",
  "threadSource",
  "type",
  "userType",
]);

const versionKeys = new Set(["cliVersion", "model", "modelProvider", "version"]);

const safeEnum = (value) =>
  /^[A-Za-z][A-Za-z0-9_.:@/-]{0,95}$/.test(value) ? value : "unknown";

export const createFixtureSanitizer = () => {
  const identifiers = new Map();
  const dynamicKeys = new Map();
  let identifierCounter = 1;
  let dynamicKeyCounter = 1;
  let timestampCounter = 0;

  const identifier = (value) => {
    if (!identifiers.has(value)) {
      identifiers.set(
        value,
        `01900000-0000-7000-8000-${String(identifierCounter).padStart(12, "0")}`,
      );
      identifierCounter += 1;
    }
    return identifiers.get(value);
  };

  const timestamp = (numeric) => {
    const date = new Date(Date.UTC(2026, 7, 4, 9, 0, timestampCounter));
    timestampCounter += 1;
    return numeric ? Math.floor(date.getTime() / 1_000) : date.toISOString();
  };

  const sanitizeObjectKey = (key) => {
    if (!key.startsWith("/") && !key.includes("/Users/")) return key;
    if (!dynamicKeys.has(key)) {
      dynamicKeys.set(
        key,
        `/Users/example/Developer/Work/sample-repo/Sources/Fixture${dynamicKeyCounter}.swift`,
      );
      dynamicKeyCounter += 1;
    }
    return dynamicKeys.get(key);
  };

  const sanitizeString = (key, value) => {
    if (enumKeys.has(key)) return safeEnum(value);
    if (versionKeys.has(key)) return safeEnum(value);
    if (/^(id|.*Id|.*ID|.*Uuid|.*UUID|uuid|session_id|turn_id|call_id)$/.test(key)) {
      return identifier(value);
    }
    if (/timestamp|createdAt|updatedAt|startedAt|completedAt|recencyAt/i.test(key)) {
      return timestamp(false);
    }
    if (/cwd|path|file|directory/i.test(key)) {
      return "/Users/example/Developer/Work/sample-repo/Sources/Example.swift";
    }
    if (/branch/i.test(key)) return "main";
    if (/sha|hash|commit/i.test(key)) return "0123456789abcdef0123456789abcdef01234567";
    if (/url|uri/i.test(key)) return "https://example.invalid/resource";
    if (/command/i.test(key)) return "git status --short";
    if (/text|content|message|summary|preview|thinking|result|output|query|prompt/i.test(key)) {
      return "Synthetic fixture content.";
    }
    return `<fixture:${key || "value"}>`;
  };

  const sanitize = (value, key = "") => {
    if (value === null || typeof value === "boolean") return value;
    if (typeof value === "number") {
      return /timestamp|createdAt|updatedAt|startedAt|completedAt|recencyAt/i.test(key)
        ? timestamp(true)
        : value;
    }
    if (typeof value === "string") return sanitizeString(key, value);
    if (Array.isArray(value)) return value.map((item) => sanitize(item, key));
    if (typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([childKey, child]) => [
          sanitizeObjectKey(childKey),
          sanitize(child, childKey),
        ]),
      );
    }
    return null;
  };

  return sanitize;
};
