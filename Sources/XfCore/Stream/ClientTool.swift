import Foundation

/// 客户端工具：让大模型调用设备本地能力（调音量、拍照、打电话……）。
///
/// 放进 `StreamConfig.tools` 后，SDK 会在会话就绪时上报 tools_list；模型发起调用时
/// 自动执行 handler 并把结果以 tool_event 回给服务端，接入方不用碰协议。
///
/// 注意：
/// - 一个会话最多 8 个工具，超出的服务端会截掉
/// - 收到调用后必须在超时内回复（默认 2 秒，`StreamConfig.toolTimeoutMs` 可调），否则服务端断开连接
/// - parameters 里 required 的设置直接决定模型会不会追问用户，写法见 docs/client_tool_definition_guide.md
public struct ClientTool {
    public let name: String
    public let description: String
    /// JSON Schema，如 ["type": "object", "properties": ["delta": ["type": "integer"]], "required": ["delta"]]
    public let parameters: [String: Any]
    public let handler: (ToolCall) async -> ToolResult

    public init(name: String, description: String,
                parameters: [String: Any] = ["type": "object", "properties": [String: Any]()],
                handler: @escaping (ToolCall) async -> ToolResult) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }

    var definition: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

public enum ToolResult {
    /// content 会进对话历史给模型看；建议带上 success 和必要数据
    case success(Any?)
    /// error 说清楚哪里不对、期望什么，模型能据此自己纠正
    case failure(error: String, content: Any? = nil)
}

public struct ToolCall {
    public let toolCallId: String
    public let functionName: String
    /// 模型给的参数（JSON 字符串原文）
    public let argumentsJSON: String

    /// 解析后的参数，解析失败返回空字典
    public var arguments: [String: Any] {
        let text = argumentsJSON.isEmpty ? "{}" : argumentsJSON
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func parseAll(_ json: [String: Any]) -> [ToolCall] {
        json.objects("toolCalls").map { call in
            // 兼容扁平和 OpenAI 嵌套两种形态
            let function = call["function"] as? [String: Any]
            return ToolCall(
                toolCallId: call.str("toolCallId") ?? call.str("id") ?? "",
                functionName: call.str("functionName") ?? function?.str("name") ?? "",
                argumentsJSON: call.str("arguments") ?? function?.str("arguments") ?? "{}"
            )
        }
    }
}
