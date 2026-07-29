import Foundation

public enum PiAgentRPCParsedEvent: Equatable, Sendable {
    case promptAccepted
    case textDelta(String)
    case thinkingDelta(String)
    case toolExecutionStarted(name: String)
    case toolExecutionEnded(name: String, isError: Bool)
    case compactionStarted(reason: String)
    case compactionEnded(reason: String, tokensBefore: Int?, estimatedTokensAfter: Int?)
    case extensionUIRequest(id: String, title: String)
    case sessionStats(PiAgentSessionStats)
    case agentEnd(finalText: String?)
}

public struct PiAgentRPCEventParser: Sendable {
    private static let maximumLineBytes = 8 * 1_024 * 1_024
    private var buffer = Data()

    public init() {}

    public mutating func append<S: DataProtocol>(_ data: S) throws -> [PiAgentRPCParsedEvent] {
        buffer.append(contentsOf: data)
        if buffer.count > Self.maximumLineBytes, !buffer.contains(0x0A) {
            throw PiAgentRPCClientError.invalidRPC("RPC JSONL 单行超过 8 MiB")
        }

        var events: [PiAgentRPCParsedEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumLineBytes else {
                throw PiAgentRPCClientError.invalidRPC("RPC JSONL 单行超过 8 MiB")
            }
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            events.append(contentsOf: try Self.parseLine(line))
        }
        return events
    }

    public func finish() throws {
        guard buffer.isEmpty else {
            throw PiAgentRPCClientError.invalidRPC("RPC JSONL 缺少结尾 LF")
        }
    }

    private static func parseLine(_ data: Data) throws -> [PiAgentRPCParsedEvent] {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PiAgentRPCClientError.invalidRPC("RPC 消息不是 JSON 对象")
            }
            object = decoded
        } catch let error as PiAgentRPCClientError {
            throw error
        } catch {
            throw PiAgentRPCClientError.invalidRPC("RPC JSON 格式无效")
        }

        guard let type = object["type"] as? String else {
            throw PiAgentRPCClientError.invalidRPC("RPC 消息缺少 type")
        }
        switch type {
        case "response":
            guard let command = object["command"] as? String else { return [] }
            if command == "get_session_stats", object["success"] as? Bool == true {
                return [.sessionStats(try parseSessionStats(object["data"]))]
            }
            guard command == "prompt" else { return [] }
            if object["success"] as? Bool == true { return [.promptAccepted] }
            let message = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PiAgentRPCClientError.rpcRejected(message.flatMap { $0.isEmpty ? nil : $0 } ?? "Pi 拒绝了 prompt")
        case "message_update":
            guard let assistantEvent = object["assistantMessageEvent"] as? [String: Any],
                  let eventType = assistantEvent["type"] as? String else {
                return []
            }
            switch eventType {
            case "text_delta":
                guard let delta = assistantEvent["delta"] as? String else {
                    throw PiAgentRPCClientError.invalidRPC("text_delta 缺少 delta")
                }
                return [.textDelta(delta)]
            case "thinking_delta":
                guard let delta = assistantEvent["delta"] as? String else {
                    throw PiAgentRPCClientError.invalidRPC("thinking_delta 缺少 delta")
                }
                return [.thinkingDelta(delta)]
            case "error":
                let error = assistantEvent["error"] as? [String: Any]
                let message = nonemptyString(error?["errorMessage"])
                    ?? nonemptyString(assistantEvent["reason"])
                    ?? "模型生成失败"
                throw PiAgentRPCClientError.rpcRejected(message)
            default:
                return []
            }
        case "message_end":
            guard let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let stopReason = message["stopReason"] as? String,
                  stopReason == "error" || stopReason == "aborted" else {
                return []
            }
            throw PiAgentRPCClientError.rpcRejected(
                nonemptyString(message["errorMessage"]) ?? "模型生成\(stopReason == "aborted" ? "已中止" : "失败")"
            )
        case "tool_execution_start":
            guard let name = nonemptyString(object["toolName"]) else {
                throw PiAgentRPCClientError.invalidRPC("tool_execution_start 缺少 toolName")
            }
            return [.toolExecutionStarted(name: name)]
        case "tool_execution_end":
            guard let name = nonemptyString(object["toolName"]),
                  let isError = object["isError"] as? Bool else {
                throw PiAgentRPCClientError.invalidRPC("tool_execution_end 缺少 toolName 或 isError")
            }
            return [.toolExecutionEnded(name: name, isError: isError)]
        case "compaction_start":
            return [.compactionStarted(reason: nonemptyString(object["reason"]) ?? "unknown")]
        case "compaction_end":
            let result = object["result"] as? [String: Any]
            return [.compactionEnded(
                reason: nonemptyString(object["reason"]) ?? "unknown",
                tokensBefore: integer(result?["tokensBefore"]),
                estimatedTokensAfter: integer(result?["estimatedTokensAfter"])
            )]
        case "extension_ui_request":
            guard let id = nonemptyString(object["id"]),
                  let method = nonemptyString(object["method"]),
                  ["select", "confirm", "input", "editor"].contains(method) else {
                return []
            }
            return [.extensionUIRequest(
                id: id,
                title: nonemptyString(object["title"]) ?? "插件需要交互输入"
            )]
        case "agent_end":
            return [.agentEnd(finalText: finalAssistantText(from: object["messages"]))]
        default:
            return []
        }
    }

    private static func parseSessionStats(_ value: Any?) throws -> PiAgentSessionStats {
        guard let data = value as? [String: Any],
              let tokens = data["tokens"] as? [String: Any] else {
            throw PiAgentRPCClientError.invalidRPC("get_session_stats 缺少 data 或 tokens")
        }
        let context = data["contextUsage"] as? [String: Any]
        return PiAgentSessionStats(
            inputTokens: integer(tokens["input"]) ?? 0,
            outputTokens: integer(tokens["output"]) ?? 0,
            cacheReadTokens: integer(tokens["cacheRead"]) ?? 0,
            cacheWriteTokens: integer(tokens["cacheWrite"]) ?? 0,
            totalTokens: integer(tokens["total"]) ?? 0,
            contextTokens: integer(context?["tokens"]),
            contextWindow: integer(context?["contextWindow"]),
            contextPercent: double(context?["percent"]),
            userMessages: integer(data["userMessages"]) ?? 0,
            assistantMessages: integer(data["assistantMessages"]) ?? 0,
            toolCalls: integer(data["toolCalls"]) ?? 0
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func finalAssistantText(from value: Any?) -> String? {
        guard let messages = value as? [[String: Any]] else { return nil }
        for message in messages.reversed() where message["role"] as? String == "assistant" {
            if let content = message["content"] as? String, !content.isEmpty { return content }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            let text = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }
}
