// MCPClientConfigTests.swift — the `.mcp.json` document model, read, merge, write.
//
// Spec dd8b1a1c-0160-4f82-a0f0-0e238d1e737f, W1 (T-MCPK-01 / T-MCPK-02 / T-MCPK-03).
//
// Why this target exists at all: before it, every fleet consumer that touched
// `.mcp.json` built the document by STRING CONCATENATION — shikki's
// `MCPStackRegistry.generateMCPConfigFromStack(_:)` still does on develop — so
// nothing validated what was written and nothing could read one back. The three
// properties below are exactly the ones a string cannot have.

import Foundation
import SwiftMCPCore
import Testing

@testable import SwiftMCPConfig

// MARK: - Fixtures

/// A temporary directory that is removed when the test leaves scope.
private struct TempDir: ~Copyable {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swiftmcp-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The conventional file name, so a fixture cannot drift from the real one.
    var configURL: URL { url.appendingPathComponent(MCPClientConfig.conventionalFileName) }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func declaredServer(
    command: String = "/usr/local/bin/shikki-mcp",
    args: [String] = ["serve", "--stdio"]
) -> MCPClientConfig.Server {
    MCPClientConfig.Server(command: command, args: args, env: ["SHI_HOME": "/Users/me/.shikki"])
}

// MARK: - T-MCPK-01 — the document has a model

@Suite("MCPClientConfig — the document round-trips")
struct MCPClientConfigRoundTripTests {

    @Test("Every modelled field survives encode → decode")
    func roundTripPreservesEveryField() throws {
        let config = MCPClientConfig(servers: [
            "shikki-db": MCPClientConfig.Server(
                command: "/usr/local/bin/shikki-mcp",
                args: ["serve"],
                env: ["SHI_HOME": "/Users/me/.shikki"],
                transport: .stdio
            ),
            "remote": MCPClientConfig.Server(
                transport: .http,
                url: "https://mcp.example.com/sse"
            ),
        ])

        let data = try MCPClientConfig.encoder.encode(config)
        let decoded = try MCPClientConfig.decoder.decode(MCPClientConfig.self, from: data)

        #expect(decoded == config)
    }

    @Test("The written text carries mcpServers and leaves a path greppable")
    func encodedTextCarriesTheServersKeyAndAnUnescapedSlash() throws {
        let config = MCPClientConfig(servers: ["shikki-db": declaredServer()])

        let text = try #require(String(data: try MCPClientConfig.encoder.encode(config), encoding: .utf8))

        #expect(text.contains("\"\(MCPClientConfig.serversKey)\""))
        #expect(text.contains("/usr/local/bin/shikki-mcp"))
        // Foundation escapes `/` as `\/` unless the encoder says otherwise, and a
        // path written that way is valid JSON that no longer greps as a path.
        #expect(!text.contains("\\/"))
    }

    @Test("An entry carries no redundant name key — the name is the dictionary key")
    func anEntryCarriesNoNameKey() throws {
        let config = MCPClientConfig(servers: ["shikki-db": declaredServer()])

        let text = try #require(String(data: try MCPClientConfig.encoder.encode(config), encoding: .utf8))

        #expect(!text.contains("\"name\""))
        #expect(text.contains("\"shikki-db\""))
    }

    @Test("A transport spelling this package does not model still round-trips")
    func anUnknownTransportSpellingRoundTrips() throws {
        let text = """
        { "\(MCPClientConfig.serversKey)": { "odd": { "type": "websocket" } } }
        """

        let decoded = try MCPClientConfig.decoder.decode(MCPClientConfig.self, from: Data(text.utf8))
        let again = try MCPClientConfig.decoder.decode(
            MCPClientConfig.self,
            from: try MCPClientConfig.encoder.encode(decoded)
        )

        #expect(decoded.servers["odd"]?.transport == .other("websocket"))
        #expect(again == decoded)
    }
}

// MARK: - T-MCPK-02 — every read outcome is named

@Suite("MCPClientConfigFile — every read outcome is named")
struct MCPClientConfigReadOutcomeTests {

    private let file = MCPClientConfigFile()

    @Test("A file that is not there is absent, not empty")
    func anAbsentFileIsAbsent() throws {
        let dir = try TempDir()

        #expect(file.read(at: dir.configURL) == .absent)
    }

    @Test("Bytes that are not JSON are unreadable, with a detail")
    func unreadableBytesAreUnreadable() throws {
        let dir = try TempDir()
        try dir.write("{ not json at all")

        guard case .unreadable(let detail) = file.read(at: dir.configURL) else {
            Issue.record("garbage bytes must not parse")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test("A root that is not an object is unreadable, never an empty document")
    func aNonObjectRootIsUnreadable() throws {
        let dir = try TempDir()
        try dir.write("[1, 2, 3]")

        guard case .unreadable(let detail) = file.read(at: dir.configURL) else {
            Issue.record("a JSON array root is not a config document")
            return
        }
        #expect(detail.contains("object"))
    }

    @Test("A wrapped document parses its servers")
    func aWrappedDocumentParses() throws {
        let dir = try TempDir()
        try dir.write("""
        {
          "\(MCPClientConfig.serversKey)": {
            "shikki-db": { "command": "shikki-mcp", "args": ["serve"] }
          }
        }
        """)

        guard case .parsed(let config) = file.read(at: dir.configURL) else {
            Issue.record("a well-formed document must parse")
            return
        }
        #expect(config.servers.keys.sorted() == ["shikki-db"])
        #expect(config.servers["shikki-db"]?.command == "shikki-mcp")
        #expect(config.servers["shikki-db"]?.args == ["serve"])
    }

    @Test("An empty object is a parsed document with no servers — not absent")
    func anEmptyObjectIsParsedWithNoServers() throws {
        let dir = try TempDir()
        try dir.write("{}")

        guard case .parsed(let config) = file.read(at: dir.configURL) else {
            Issue.record("`{}` is a readable document")
            return
        }
        #expect(config.servers.isEmpty)
    }

    @Test("A top-level key this package does not model survives the decode")
    func anUnmodelledTopLevelKeySurvives() throws {
        let dir = try TempDir()
        try dir.write("""
        { "\(MCPClientConfig.serversKey)": {}, "inputs": [{ "id": "token" }] }
        """)

        guard case .parsed(let config) = file.read(at: dir.configURL) else {
            Issue.record("a well-formed document must parse")
            return
        }
        #expect(config.unmodelled["inputs"] != nil)

        let text = try #require(String(data: try MCPClientConfig.encoder.encode(config), encoding: .utf8))
        #expect(text.contains("\"inputs\""))
    }

    @Test("A server field this package does not model survives the decode")
    func anUnmodelledServerFieldSurvives() throws {
        let dir = try TempDir()
        try dir.write("""
        {
          "\(MCPClientConfig.serversKey)": {
            "shikki-db": { "command": "shikki-mcp", "disabled": true }
          }
        }
        """)

        guard case .parsed(let config) = file.read(at: dir.configURL) else {
            Issue.record("a well-formed document must parse")
            return
        }
        #expect(config.servers["shikki-db"]?.unmodelled["disabled"] == .bool(true))

        let text = try #require(String(data: try MCPClientConfig.encoder.encode(config), encoding: .utf8))
        #expect(text.contains("\"disabled\""))
    }
}

// MARK: - T-MCPK-03 — merge, never overwrite

@Suite("MCPClientConfigFile — merge preserves what the fleet does not own")
struct MCPClientConfigMergeTests {

    private let file = MCPClientConfigFile()

    @Test("An entry the fleet does not own is preserved")
    func mergePreservesAForeignEntry() throws {
        let dir = try TempDir()
        try dir.write("""
        {
          "\(MCPClientConfig.serversKey)": {
            "someone-elses": { "command": "their-binary", "args": ["--weird"] }
          }
        }
        """)

        let merged = try file.merge(["shikki-db": declaredServer()], into: dir.configURL)

        #expect(merged.servers.keys.sorted() == ["shikki-db", "someone-elses"])
        #expect(merged.servers["someone-elses"]?.command == "their-binary")
        #expect(merged.servers["someone-elses"]?.args == ["--weird"])
    }

    @Test("Only the named entry is replaced")
    func mergeReplacesOnlyTheNamedEntry() throws {
        let dir = try TempDir()
        try dir.write("""
        {
          "\(MCPClientConfig.serversKey)": {
            "shikki-db": { "command": "stale-binary" },
            "keep-me": { "command": "untouched" }
          }
        }
        """)

        let merged = try file.merge(["shikki-db": declaredServer(command: "fresh-binary")], into: dir.configURL)

        #expect(merged.servers["shikki-db"]?.command == "fresh-binary")
        #expect(merged.servers["keep-me"]?.command == "untouched")
    }

    @Test("Merging into a file that is not there creates it")
    func mergeCreatesTheFileWhenAbsent() throws {
        let dir = try TempDir()

        let merged = try file.merge(["shikki-db": declaredServer()], into: dir.configURL)

        #expect(merged.servers.keys.sorted() == ["shikki-db"])
        guard case .parsed(let reread) = file.read(at: dir.configURL) else {
            Issue.record("the merge must have written a readable document")
            return
        }
        #expect(reread == merged)
    }

    @Test("Writing an unchanged document twice produces identical bytes")
    func writeIsIdempotent() throws {
        let dir = try TempDir()
        try file.write(MCPClientConfig(servers: ["shikki-db": declaredServer()]), to: dir.configURL)
        let first = try Data(contentsOf: dir.configURL)

        guard case .parsed(let reread) = file.read(at: dir.configURL) else {
            Issue.record("what we just wrote must read back")
            return
        }
        try file.write(reread, to: dir.configURL)

        #expect(try Data(contentsOf: dir.configURL) == first)
    }

    @Test("Merging the same entry twice is a no-op on the bytes")
    func mergeIsIdempotent() throws {
        let dir = try TempDir()
        _ = try file.merge(["shikki-db": declaredServer()], into: dir.configURL)
        let first = try Data(contentsOf: dir.configURL)

        _ = try file.merge(["shikki-db": declaredServer()], into: dir.configURL)

        #expect(try Data(contentsOf: dir.configURL) == first)
    }

    @Test("A merge refuses rather than clobber a document it could not read")
    func mergeRefusesAnUnreadableDocument() throws {
        let dir = try TempDir()
        try dir.write("{ not json at all")
        let before = try Data(contentsOf: dir.configURL)

        #expect(throws: MCPClientConfigError.self) {
            _ = try file.merge(["shikki-db": declaredServer()], into: dir.configURL)
        }
        #expect(try Data(contentsOf: dir.configURL) == before)
    }
}
