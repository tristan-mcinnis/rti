import Foundation

/// `rti-mcp` — standalone command-line MCP server. Reads JSON-RPC 2.0
/// messages from stdin (one per line), dispatches to the four tools in
/// `MCPTools`, writes JSON-RPC responses to stdout.
///
/// Run by external agents (Claude Desktop, Codex, Gemini CLI, OpenCode).
/// Each agent invocation spawns a fresh process — the binary is small and
/// startup is microseconds, so there's no need for a long-lived server.
@main
enum RTIMCPMain {
    static func main() {
        let args = parseArgs()
        let tools = MCPTools(
            corpusDirectory: args.corpusDirectory,
            liveDirectory: args.liveDirectory,
            dbPath: args.dbPath
        )
        runLoop(tools: tools)
    }

    // MARK: - args

    struct Args {
        var corpusDirectory: URL
        var liveDirectory: URL
        var dbPath: URL
    }

    static func parseArgs() -> Args {
        let argv = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        var corpusDir = home.appendingPathComponent("meetings", isDirectory: true)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let rtiSupport = appSupport.appendingPathComponent("RTI", isDirectory: true)
        var liveDir = rtiSupport.appendingPathComponent("live", isDirectory: true)
        var dbPath = rtiSupport.appendingPathComponent("rti.db")

        var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--corpus":
                if i + 1 < argv.count {
                    corpusDir = URL(fileURLWithPath: (argv[i + 1] as NSString).expandingTildeInPath)
                    i += 2
                } else { i += 1 }
            case "--live":
                if i + 1 < argv.count {
                    liveDir = URL(fileURLWithPath: (argv[i + 1] as NSString).expandingTildeInPath)
                    i += 2
                } else { i += 1 }
            case "--db":
                if i + 1 < argv.count {
                    dbPath = URL(fileURLWithPath: (argv[i + 1] as NSString).expandingTildeInPath)
                    i += 2
                } else { i += 1 }
            default:
                i += 1
            }
        }
        return Args(corpusDirectory: corpusDir, liveDirectory: liveDir, dbPath: dbPath)
    }

    // MARK: - runloop

    static func runLoop(tools: MCPTools) {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                // EOF — agent disconnected.
                return
            }
            buffer.append(chunk)
            // Process every complete line (terminated by \n) and leave any
            // trailing partial line in the buffer.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard !lineData.isEmpty else { continue }
                if let response = handleLine(lineData, tools: tools) {
                    stdout.write(response)
                    stdout.write(Data([0x0A]))
                }
            }
        }
    }

    static func handleLine(_ data: Data, tools: MCPTools) -> Data? {
        let decoder = JSONDecoder()
        // Notifications have no `id` and need no response. Try to decode
        // as a request first; fall back to notification on failure.
        if let req = try? decoder.decode(JSONRPCRequest.self, from: data),
           let id = req.id {
            let response = dispatch(method: req.method, params: req.params, tools: tools)
            switch response {
            case .success(let result):
                return try? JSONEncoder().encode(JSONRPCResponse(id: id, result: result))
            case .failure(let error):
                return try? JSONEncoder().encode(JSONRPCResponse(id: id, error: error))
            }
        }
        // Decode as notification — no reply.
        _ = try? decoder.decode(JSONRPCNotification.self, from: data)
        return nil
    }

    enum Outcome {
        case success(AnyCodable)
        case failure(JSONRPCError)
    }

    static func dispatch(method: String, params: AnyCodable?, tools: MCPTools) -> Outcome {
        switch method {
        case "initialize":
            let result = InitializeResult(
                protocolVersion: MCPProtocolVersion.supported,
                serverInfo: .init(name: "rti-mcp", version: "0.1.0"),
                capabilities: .init(tools: .init())
            )
            return .success(encodeAsAny(result))
        case "tools/list":
            return .success(encodeAsAny(ToolListing(tools: MCPTools.descriptors)))
        case "tools/call":
            return handleToolCall(params: params, tools: tools)
        default:
            return .failure(.methodNotFound)
        }
    }

    static func handleToolCall(params: AnyCodable?, tools: MCPTools) -> Outcome {
        guard let dict = params?.value as? [String: Any],
              let name = dict["name"] as? String else {
            return .failure(.invalidParams)
        }
        let arguments = (dict["arguments"] as? [String: Any]) ?? [:]
        let result: ToolCallResult
        switch name {
        case "search_corpus": result = tools.searchCorpus(arguments: arguments)
        case "read_meeting": result = tools.readMeeting(arguments: arguments)
        case "list_meetings": result = tools.listMeetings(arguments: arguments)
        case "read_live_transcript": result = tools.readLiveTranscript(arguments: arguments)
        case "list_projects": result = tools.listProjects(arguments: arguments)
        case "read_project": result = tools.readProject(arguments: arguments)
        case "search_project": result = tools.searchProject(arguments: arguments)
        case "append_to_session": result = tools.appendToSession(arguments: arguments)
        default:
            return .failure(.init(code: -32601, message: "Unknown tool: \(name)"))
        }
        return .success(encodeAsAny(result))
    }

    static func encodeAsAny<T: Encodable>(_ value: T) -> AnyCodable {
        // Round-trip through JSONSerialization so AnyCodable's untyped
        // inner storage matches what the encoder expects on output.
        guard let data = try? JSONEncoder().encode(value),
              let raw = try? JSONSerialization.jsonObject(with: data) else {
            return AnyCodable(nil)
        }
        return AnyCodable(raw)
    }
}
