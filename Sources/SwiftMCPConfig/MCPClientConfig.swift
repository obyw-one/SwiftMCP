// MCPClientConfig.swift — RED STUB. The public surface only; every behaviour
// throws `.notImplemented` so the suite can be proven red before W1's
// implementation exists (spec dd8b1a1c, W1).

import Foundation
import SwiftMCPCore

public enum MCPClientConfigError: Error, Equatable, Sendable {
    case notImplemented
    case unreadable(detail: String)
}

public enum MCPServerTransport: Equatable, Sendable {
    case stdio
    case http
    case other(String)
}

public struct MCPClientConfig: Equatable, Sendable {

    public struct Server: Equatable, Sendable {
        public var command: String?
        public var args: [String]?
        public var env: [String: String]?
        public var transport: MCPServerTransport?
        public var url: String?
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

    public static let serversKey = "mcpServers"
    public static let conventionalFileName = ".mcp.json"

    public static var encoder: JSONEncoder { JSONEncoder() }
    public static var decoder: JSONDecoder { JSONDecoder() }

    public var servers: [String: Server]
    public var unmodelled: [String: JSONValue]

    public init(servers: [String: Server] = [:], unmodelled: [String: JSONValue] = [:]) {
        self.servers = servers
        self.unmodelled = unmodelled
    }
}

extension MCPClientConfig: Codable {
    public init(from decoder: Decoder) throws { throw MCPClientConfigError.notImplemented }
    public func encode(to encoder: Encoder) throws { throw MCPClientConfigError.notImplemented }
}

public enum MCPClientConfigReadOutcome: Equatable, Sendable {
    case absent
    case unreadable(detail: String)
    case parsed(MCPClientConfig)
}

public struct MCPClientConfigFile: Sendable {
    public init() {}

    public func read(at url: URL) -> MCPClientConfigReadOutcome {
        .unreadable(detail: "not implemented")
    }

    public func write(_ config: MCPClientConfig, to url: URL) throws {
        throw MCPClientConfigError.notImplemented
    }

    public func merge(_ servers: [String: MCPClientConfig.Server], into url: URL) throws -> MCPClientConfig {
        throw MCPClientConfigError.notImplemented
    }
}
