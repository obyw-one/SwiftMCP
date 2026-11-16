// MCPClientConfig.swift — `.mcp.json`, the MCP CLIENT configuration document,
// as a typed model with a merging writer.
//
// Spec dd8b1a1c-0160-4f82-a0f0-0e238d1e737f, W1 (BR-MCPK-01..04).
//
// WHY THIS LIVES IN THE KIT. The operator, reviewing shikki#1909: *"why do we
// have all the MCP setup inside #1909 and not in the ShikkiMCP SPM or even
// SwiftMCP, with a thin usage of it in shikki?"* Every fleet consumer that
// touched `.mcp.json` carried its own idea of the document — shikki builds it
// by STRING CONCATENATION to this day (`MCPStackRegistry.generateMCPConfigFromStack`),
// so nothing validates what is written and nothing can read one back. The
// document belongs to the MCP layer, so its model belongs here.
//
// THREE PROPERTIES A STRING CANNOT HAVE, and each is pinned by a test:
//   1. ROUND-TRIP — what we write, we can read, and it is equal.
//   2. EVERY OUTCOME NAMED — absent, unreadable, non-object root and `{}` are
//      four different answers. A reader that collapses them into "no servers"
//      silently proposes to overwrite a file it failed to understand.
//   3. MERGE, NOT OVERWRITE — the file is shared with the operator's own
//      editor and with other tools. Entries and fields this package does not
//      model survive a write, and a document that could not be read is refused
//      rather than clobbered.
//
// NAMES ARE KEYS, NOT FIELDS. In `.mcp.json` a server's name is the dictionary
// KEY. A model that also carried `name` as a property would emit it inside
// every entry and change the file's shape, so ``Server`` is the WIRE model and
// a consumer's own registry type converts into it.

import Foundation
import SwiftMCPCore

// MARK: - MCPClientConfigError

/// The one way a config operation fails: the document on disk is not one.
public enum MCPClientConfigError: Error, Equatable, Sendable {
    /// The file exists but could not be read as a configuration document.
    case unreadable(detail: String)
}

// MARK: - MCPServerTransport

/// The `type` field: how a client reaches the server.
///
/// `other` exists because a hand-edited file may name a transport this package
/// does not model, and refusing to read such a file would be worse than
/// carrying the spelling through unchanged.
public enum MCPServerTransport: RawRepresentable, Equatable, Sendable {
    case stdio
    case http
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case Self.stdio.rawValue: self = .stdio
        case Self.http.rawValue: self = .http
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stdio: "stdio"
        case .http: "http"
        case .other(let spelling): spelling
        }
    }
}

extension MCPServerTransport: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - DocumentKey

/// A coding key for a document whose keys are data, not a fixed set.
private struct DocumentKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

// MARK: - MCPClientConfig

/// The `.mcp.json` document: `{ "mcpServers": { "<name>": { … } } }`.
public struct MCPClientConfig: Equatable, Sendable {

    // MARK: - Server

    /// One server entry, in the shape the file uses.
    ///
    /// Every modelled field is optional because a hand-edited document may
    /// carry any subset, and this model must not refuse to read one.
    public struct Server: Equatable, Sendable {

        /// The field names this type models — declared once, so the decoder and
        /// the encoder cannot disagree about which keys are "the rest".
        enum Field: String, CaseIterable {
            case command
            case args
            case env
            case type
            case url
        }

        public var command: String?
        public var args: [String]?
        public var env: [String: String]?
        /// The `type` field on the wire.
        public var transport: MCPServerTransport?
        /// Only meaningful for an `http`-transport server.
        public var url: String?
        /// Fields this package does not model, carried through unchanged.
        public var unmodelled: [String: JSONValue]

        public init(
            command: String? = nil,
            args: [String]? = nil,
            env: [String: String]? = nil,
            transport: MCPServerTransport? = nil,
            url: String? = nil,
            unmodelled: [String: JSONValue] = [:]
        ) {
            self.command = command
            self.args = args
            self.env = env
            self.transport = transport
            self.url = url
            self.unmodelled = unmodelled
        }
    }

    // MARK: - Declared names

    /// The key the document wraps its servers in.
    public static let serversKey = "mcpServers"

    /// The file name clients look for, so a consumer need not spell it.
    public static let conventionalFileName = ".mcp.json"

    // MARK: - Codecs (BR-MCPK-03)

    /// The writer. `withoutEscapingSlashes` is the one that matters: Foundation
    /// escapes `/` as `\/` by default, so a command path written through a
    /// plain encoder lands in the file as `\/usr\/local\/bin\/…` — valid JSON
    /// that no longer greps as a path. `sortedKeys` is what makes a write
    /// byte-idempotent.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The reader.
    public static var decoder: JSONDecoder { JSONDecoder() }

    // MARK: - Stored

    public var servers: [String: Server]
    /// Top-level keys this package does not model, carried through unchanged.
    public var unmodelled: [String: JSONValue]

    public init(servers: [String: Server] = [:], unmodelled: [String: JSONValue] = [:]) {
        self.servers = servers
        self.unmodelled = unmodelled
    }

    // MARK: - Merge

    /// The document with `servers` added or replaced, entry by entry.
    ///
    /// Entries this document already carries under other names are untouched —
    /// that is the whole point: the file is shared with the operator's editor
    /// and with other tools.
    public func merging(_ servers: [String: Server]) -> Self {
        var merged = self
        for (name, server) in servers {
            merged.servers[name] = server
        }
        return merged
    }
}

// MARK: - MCPClientConfig + Codable

extension MCPClientConfig: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DocumentKey.self)
        let serversKey = DocumentKey(Self.serversKey)

        servers = try container.decodeIfPresent([String: Server].self, forKey: serversKey) ?? [:]

        var rest: [String: JSONValue] = [:]
        for key in container.allKeys where key.stringValue != Self.serversKey {
            rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unmodelled = rest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DocumentKey.self)

        for (key, value) in unmodelled where key != Self.serversKey {
            try container.encode(value, forKey: DocumentKey(key))
        }
        try container.encode(servers, forKey: DocumentKey(Self.serversKey))
    }
}

// MARK: - MCPClientConfig.Server + Codable

extension MCPClientConfig.Server: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DocumentKey.self)

        command = try container.decodeIfPresent(String.self, forKey: DocumentKey(Field.command.rawValue))
        args = try container.decodeIfPresent([String].self, forKey: DocumentKey(Field.args.rawValue))
        env = try container.decodeIfPresent([String: String].self, forKey: DocumentKey(Field.env.rawValue))
        transport = try container.decodeIfPresent(
            MCPServerTransport.self,
            forKey: DocumentKey(Field.type.rawValue)
        )
        url = try container.decodeIfPresent(String.self, forKey: DocumentKey(Field.url.rawValue))

        let modelled = Set(Field.allCases.map(\.rawValue))
        var rest: [String: JSONValue] = [:]
        for key in container.allKeys where !modelled.contains(key.stringValue) {
            rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unmodelled = rest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DocumentKey.self)
        let modelled = Set(Field.allCases.map(\.rawValue))

        // The unmodelled remainder goes first, so a modelled field always wins
        // over a stale spelling of the same key.
        for (key, value) in unmodelled where !modelled.contains(key) {
            try container.encode(value, forKey: DocumentKey(key))
        }

        try container.encodeIfPresent(command, forKey: DocumentKey(Field.command.rawValue))
        try container.encodeIfPresent(args, forKey: DocumentKey(Field.args.rawValue))
        try container.encodeIfPresent(env, forKey: DocumentKey(Field.env.rawValue))
        try container.encodeIfPresent(transport, forKey: DocumentKey(Field.type.rawValue))
        try container.encodeIfPresent(url, forKey: DocumentKey(Field.url.rawValue))
    }
}

// MARK: - MCPClientConfigReadOutcome

/// What reading a `.mcp.json` found. Four answers, never one silent default.
public enum MCPClientConfigReadOutcome: Equatable, Sendable {
    /// No file at that path. A consumer may create one.
    case absent
    /// A file is there and it is not a configuration document. A consumer must
    /// surface this and must not overwrite it.
    case unreadable(detail: String)
    /// A document, including the empty one (`{}`), which is not the same as absent.
    case parsed(MCPClientConfig)
}

// MARK: - MCPClientConfigFile

/// Reads, merges and writes a `.mcp.json` at a URL.
///
/// Stateless on purpose. An injected `FileManager` would make the type
/// non-`Sendable` (`FileManager` is not), and the seam would have no user: the
/// tests drive real files in a temporary directory, which is what a config
/// writer has to get right anyway. `FileManager.default`'s own documentation
/// states its methods are safe to call from multiple threads, and this type
/// holds no instance to make unsafe.
public struct MCPClientConfigFile: Sendable {

    private var fileManager: FileManager { .default }

    public init() {}

    /// Read the document at `url`, naming every outcome (BR-MCPK-02).
    public func read(at url: URL) -> MCPClientConfigReadOutcome {
        guard let data = fileManager.contents(atPath: url.path) else {
            return fileManager.fileExists(atPath: url.path)
                ? .unreadable(detail: "the file exists but its bytes could not be read")
                : .absent
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .unreadable(detail: String(describing: error))
        }
        guard root is [String: Any] else {
            return .unreadable(detail: "the document's root is not a JSON object")
        }

        do {
            return .parsed(try MCPClientConfig.decoder.decode(MCPClientConfig.self, from: data))
        } catch {
            return .unreadable(detail: String(describing: error))
        }
    }

    /// Write `config` to `url`, atomically and deterministically.
    public func write(_ config: MCPClientConfig, to url: URL) throws {
        try MCPClientConfig.encoder.encode(config).write(to: url, options: .atomic)
    }

    /// Add or replace `servers` in the document at `url` and write it back.
    ///
    /// Creates the file when there is none. THROWS, and writes nothing, when a
    /// file is there and could not be read — the alternative is deleting
    /// somebody's hand-edited configuration because we failed to parse it.
    @discardableResult
    public func merge(
        _ servers: [String: MCPClientConfig.Server],
        into url: URL
    ) throws -> MCPClientConfig {
        let existing: MCPClientConfig
        switch read(at: url) {
        case .absent:
            existing = MCPClientConfig()
        case .unreadable(let detail):
            throw MCPClientConfigError.unreadable(detail: detail)
        case .parsed(let parsed):
            existing = parsed
        }

        let merged = existing.merging(servers)
        try write(merged, to: url)
        return merged
    }
}
