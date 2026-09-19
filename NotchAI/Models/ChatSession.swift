import Foundation
import Observation

/// A short conversation with one provider from the notch. The CLI keeps the real context
/// (the conversation is resumed by id); this only holds what is shown.
@MainActor
@Observable
final class ChatSession {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, step, error }
        let id = UUID()
        var role: Role
        var text: String
    }

    static let limit = 60

    private(set) var messages: [Message] = []
    /// Claude session id / Codex thread id, used to continue the same conversation.
    var conversationID: String?

    func add(_ role: Message.Role, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Consecutive progress steps replace each other so the chat does not fill with them.
        if role == .step, messages.last?.role == .step {
            messages[messages.count - 1].text = trimmed
        } else {
            messages.append(Message(role: role, text: trimmed))
        }
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
    }

    /// The reply is in; progress steps are no longer interesting.
    func dropSteps() {
        messages.removeAll { $0.role == .step }
    }

    func reset() {
        messages.removeAll()
        conversationID = nil
    }
}

/// What a line of CLI output means for the chat.
enum ChatUpdate: Equatable {
    case conversation(String)
    case message(ChatSession.Message.Role, String)
    case finished
    case failed(String)
}

extension ChatSession {
    func apply(_ update: ChatUpdate) {
        switch update {
        case .conversation(let id): conversationID = id
        case .message(let role, let text): add(role, text)
        case .finished: dropSteps()
        case .failed(let message):
            dropSteps()
            add(.error, message)
        }
    }
}

enum ChatStreamParser {
    /// `claude -p --output-format stream-json --verbose` lines.
    static func claude(_ line: String) -> [ChatUpdate] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return [] }
        switch object["type"] as? String {
        case "system":
            return (object["session_id"] as? String).map { [.conversation($0)] } ?? []
        case "assistant":
            if object["parent_tool_use_id"] as? String != nil { return [] }   // subagent chatter
            let items = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return items.compactMap { item in
                switch item["type"] as? String {
                case "text":
                    return (item["text"] as? String).map { .message(.assistant, $0) }
                case "tool_use":
                    return .message(.step, ClaudeTranscriptParser.describeTool(
                        name: item["name"] as? String ?? "Tool", input: item["input"] as? [String: Any] ?? [:]))
                default:
                    return nil
                }
            }
        case "result":
            var updates: [ChatUpdate] = []
            if let id = object["session_id"] as? String { updates.append(.conversation(id)) }
            if object["is_error"] as? Bool == true {
                updates.append(.failed(ClaudeTranscriptParser.summary(object["result"] as? String ?? "Claude Code failed", limit: 200)))
            } else {
                updates.append(.finished)
            }
            return updates
        default:
            return []
        }
    }

    /// `codex exec --json` lines.
    static func codex(_ line: String) -> [ChatUpdate] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return [] }
        let item = object["item"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "thread.started":
            return (object["thread_id"] as? String).map { [.conversation($0)] } ?? []
        case "item.started" where item["type"] as? String == "command_execution":
            return [.message(.step, "Running " + ClaudeTranscriptParser.summary(item["command"] as? String ?? "command", limit: 40))]
        case "item.started" where item["type"] as? String == "file_change":
            return [.message(.step, "Editing files")]
        case "item.completed" where item["type"] as? String == "agent_message":
            return (item["text"] as? String).map { [.message(.assistant, $0)] } ?? []
        case "turn.completed":
            return [.finished]
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.failed(message ?? "Codex failed")]
        case "error":
            return [.failed(object["message"] as? String ?? "Codex error")]
        default:
            return []
        }
    }
}
