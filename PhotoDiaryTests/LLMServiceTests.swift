import XCTest
@testable import PhotoDiary

final class LLMServiceTests: XCTestCase {

    private let preset = LLMPreset(
        id: "test",
        name: "测试",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-flash",
        supportsVision: true
    )

    // MARK: - 请求构造

    func testMakeRequestBuildsCorrectURLRequest() throws {
        let imageData = Data([0x01, 0x02, 0x03])
        let request = try LLMService.makeRequest(
            config: preset,
            apiKey: "sk-test-key",
            prompt: "写一段日记",
            imageJPEGData: imageData
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
        XCTAssertEqual(json["stream"] as? Bool, false)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")

        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "写一段日记")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap((content[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertTrue(imageURL.contains(imageData.base64EncodedString()))
    }

    func testMakeRequestWithoutImageOmitsImageBlock() throws {
        let request = try LLMService.makeRequest(config: preset, apiKey: "k", prompt: "你好", imageJPEGData: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
    }

    func testMakeRequestTrimsTrailingSlashInBaseURL() throws {
        let sloppy = LLMPreset(id: "t", name: "t", baseURL: "https://api.deepseek.com/", model: "m", supportsVision: true)
        let request = try LLMService.makeRequest(config: sloppy, apiKey: "k", prompt: "p", imageJPEGData: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
    }

    func testMakeRequestRejectsEmptyBaseURL() {
        let bad = LLMPreset(id: "t", name: "t", baseURL: "  ", model: "m", supportsVision: true)
        XCTAssertThrowsError(try LLMService.makeRequest(config: bad, apiKey: "k", prompt: "p", imageJPEGData: nil)) { error in
            XCTAssertEqual(error as? LLMError, .invalidURL)
        }
    }

    func testMakeBodyMergesExtraBodyWithoutOverriding() throws {
        let body = try LLMService.makeBody(
            model: "deepseek-flash",
            prompt: "p",
            imageJPEGData: nil,
            stream: true,
            extraBodyJSON: #"{"thinking":{"type":"disabled"},"stream":true}"#
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // 厂商参数被合并且不覆盖已有键
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testMakeBodyIgnoresInvalidExtraBody() throws {
        let body = try LLMService.makeBody(model: "m", prompt: "p", imageJPEGData: nil, extraBodyJSON: "not json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "m")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testMakeBodyMultipleImages() throws {
        let body = try LLMService.makeBody(
            model: "m",
            prompt: "p",
            imagesJPEGData: [Data([0x01]), Data([0x02]), Data([0x03])],
            stream: false
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        // 1 个文本块 + 3 个图片块
        XCTAssertEqual(content.count, 4)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertEqual(content[2]["type"] as? String, "image_url")
        XCTAssertEqual(content[3]["type"] as? String, "image_url")
    }

    func testDeepSeekPresetDisablesThinking() {
        let extra = try! XCTUnwrap(LLMPresets.deepSeekFlash.extraBodyJSON)
        XCTAssertTrue(extra.contains("\"disabled\""))
    }

    // MARK: - SSE 解析

    func testParseSSELineDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"今天"}}]}"#
        XCTAssertEqual(LLMService.parseSSELine(line), .delta("今天"))
    }

    func testParseSSELineDone() {
        XCTAssertEqual(LLMService.parseSSELine("data: [DONE]"), .done)
    }

    func testParseSSELineIgnoresNoise() {
        XCTAssertEqual(LLMService.parseSSELine(""), .ignore)
        XCTAssertEqual(LLMService.parseSSELine(": keep-alive"), .ignore)
        XCTAssertEqual(LLMService.parseSSELine("event: message"), .ignore)
        // role-only delta（首包常见）
        XCTAssertEqual(LLMService.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignore)
        // 非法 JSON
        XCTAssertEqual(LLMService.parseSSELine("data: {broken"), .ignore)
    }

    // MARK: - 响应解析

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.deepseek.com/chat/completions")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testParseResponseSuccess() throws {
        let payload: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": "  今天的夕阳真美。  "]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try LLMService.parseResponse(data: data, response: httpResponse(200))
        XCTAssertEqual(text, "今天的夕阳真美。")
    }

    func testParseResponseContentParts() throws {
        let payload: [String: Any] = [
            "choices": [
                ["message": ["content": [["type": "text", "text": "第一段"], ["type": "text", "text": "第二段"]]]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try LLMService.parseResponse(data: data, response: httpResponse(200))
        XCTAssertEqual(text, "第一段第二段")
    }

    func testParseResponseHTTPErrorExtractsServerMessage() throws {
        let payload: [String: Any] = ["error": ["message": "Insufficient Balance", "type": "invalid_request_error"]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try LLMService.parseResponse(data: data, response: httpResponse(402))) { error in
            XCTAssertEqual(error as? LLMError, .httpError(statusCode: 402, message: "Insufficient Balance"))
        }
    }

    func testParseResponseInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try LLMService.parseResponse(data: data, response: httpResponse(200))) { error in
            XCTAssertEqual(error as? LLMError, .invalidResponse)
        }
    }

    // MARK: - PromptBuilder

    func testPromptBuilderReplacesPlaceholders() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = formatter.date(from: "2026-10-07 14:30")!
        let prompt = PromptBuilder.buildPrompt(
            template: "时间{datetime}，日期{date}，时刻{time}，地点{location}",
            date: date,
            locationName: "上海市 · 静安公园"
        )
        XCTAssertTrue(prompt.contains("2026年10月7日 14:30"))
        XCTAssertTrue(prompt.contains("2026年10月7日 星期三"))
        XCTAssertTrue(prompt.contains("14:30"))
        XCTAssertTrue(prompt.contains("上海市 · 静安公园"))
        XCTAssertFalse(prompt.contains("{datetime}"))
        XCTAssertFalse(prompt.contains("{location}"))
    }

    func testPromptBuilderUnknownLocation() {
        let prompt = PromptBuilder.buildPrompt(template: "地点：{location}", date: Date(), locationName: nil)
        XCTAssertEqual(prompt, "地点：未知")
    }

    // MARK: - 预设

    func testDefaultPresetIsDeepSeekFlashWithVision() {
        let preset = LLMPresets.deepSeekFlash
        XCTAssertEqual(preset.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(preset.model, "deepseek-flash")
        XCTAssertTrue(preset.supportsVision)
    }
}
