import Foundation

enum LLMError: LocalizedError, Equatable {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址无效，请检查设置中的 Base URL"
        case .httpError(let code, let message):
            return "请求失败（HTTP \(code)）：\(message)"
        case .invalidResponse:
            return "返回数据格式无法解析"
        }
    }
}

/// OpenAI 兼容 Chat Completions 客户端，支持多模态（base64 图片）
struct LLMService {
    var session: URLSession = .shared

    func chat(prompt: String, imageJPEGData: Data?, config: LLMPreset, apiKey: String) async throws -> String {
        let request = try Self.makeRequest(
            config: config,
            apiKey: apiKey,
            prompt: prompt,
            imageJPEGData: config.supportsVision ? imageJPEGData : nil
        )
        let (data, response) = try await session.data(for: request)
        return try Self.parseResponse(data: data, response: response)
    }

    /// 流式生成（SSE，单图便捷版）
    func chatStream(prompt: String, imageJPEGData: Data?, config: LLMPreset, apiKey: String) -> AsyncThrowingStream<String, Error> {
        chatStreamMulti(prompt: prompt, imagesJPEGData: imageJPEGData.map { [$0] } ?? [], config: config, apiKey: apiKey)
    }

    /// 流式生成（SSE，多图版），逐段产出文本增量。
    /// 调用方取消消费（Task.cancel / 视图消失）时，底层网络任务会被一并取消。
    func chatStreamMulti(prompt: String, imagesJPEGData: [Data], config: LLMPreset, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(
                        config: config,
                        apiKey: apiKey,
                        prompt: prompt,
                        imagesJPEGData: config.supportsVision ? imagesJPEGData : [],
                        stream: true
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 8192 { break }
                        }
                        throw LLMError.httpError(
                            statusCode: http.statusCode,
                            message: Self.extractErrorMessage(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                        )
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch Self.parseSSELine(line) {
                        case .delta(let text):
                            continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 用于设置页的「测试连接」
    func testConnection(config: LLMPreset, apiKey: String) async throws -> String {
        try await chat(prompt: "请用一句中文回答：连接正常。", imageJPEGData: nil, config: config, apiKey: apiKey)
    }

    // MARK: - 纯函数，便于单元测试

    static func makeRequest(config: LLMPreset, apiKey: String, prompt: String, imageJPEGData: Data?, stream: Bool = false) throws -> URLRequest {
        try makeRequest(config: config, apiKey: apiKey, prompt: prompt, imagesJPEGData: imageJPEGData.map { [$0] } ?? [], stream: stream)
    }

    static func makeRequest(config: LLMPreset, apiKey: String, prompt: String, imagesJPEGData: [Data], stream: Bool) throws -> URLRequest {
        let base = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
            throw LLMError.invalidURL
        }
        // 60s 无数据即超时；流式场景下每收到一块数据会重置计时
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try makeBody(
            model: config.model,
            prompt: prompt,
            imagesJPEGData: imagesJPEGData,
            stream: stream,
            extraBodyJSON: config.extraBodyJSON
        )
        return request
    }

    static func makeBody(model: String, prompt: String, imageJPEGData: Data?, stream: Bool = false, extraBodyJSON: String? = nil) throws -> Data {
        try makeBody(model: model, prompt: prompt, imagesJPEGData: imageJPEGData.map { [$0] } ?? [], stream: stream, extraBodyJSON: extraBodyJSON)
    }

    static func makeBody(model: String, prompt: String, imagesJPEGData: [Data], stream: Bool = false, extraBodyJSON: String? = nil) throws -> Data {
        var content: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        for imageData in imagesJPEGData {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"],
            ])
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": content]
            ],
            "stream": stream,
        ]
        // 合并厂商特有参数（如 DeepSeek 的 thinking），不覆盖已有键
        if let extraBodyJSON,
           let extraData = extraBodyJSON.data(using: .utf8),
           let extra = try? JSONSerialization.jsonObject(with: extraData) as? [String: Any] {
            for (key, value) in extra where payload[key] == nil {
                payload[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - SSE 解析

    enum SSEEvent: Equatable {
        case delta(String)
        case done
        case ignore
    }

    /// 解析单行 SSE：只关心 `data:` 行中的 choices[0].delta.content
    static func parseSSELine(_ line: String) -> SSEEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return .ignore
        }
        return .delta(content)
    }

    static func parseResponse(data: Data, response: URLResponse) throws -> String {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let message = extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw LLMError.httpError(statusCode: statusCode, message: message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }
        // 常见形态：content 为字符串
        if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw LLMError.invalidResponse }
            return trimmed
        }
        // 兼容形态：content 为分块数组
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw LLMError.invalidResponse }
            return trimmed
        }
        throw LLMError.invalidResponse
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String
    }
}
