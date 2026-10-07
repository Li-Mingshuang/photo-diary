import Foundation
import Combine

/// 一个 OpenAI 兼容的 LLM 接入配置
struct LLMPreset: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var supportsVision: Bool
    /// 额外请求参数（JSON 字符串），会合并进请求体顶层，用于厂商特有参数
    var extraBodyJSON: String? = nil
}

enum LLMPresets {
    /// DeepSeek V4.1 Flash，官方确认支持视觉输入（OpenAI 兼容格式）。
    /// 官方默认开启 thinking 模式，写日记这种短文本场景关闭后生成更快。
    static let deepSeekFlash = LLMPreset(
        id: "deepseek-flash",
        name: "DeepSeek V4.1 Flash",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-flash",
        supportsVision: true,
        extraBodyJSON: #"{"thinking":{"type":"disabled"}}"#
    )
    static let qwenVL = LLMPreset(
        id: "qwen-vl-max",
        name: "通义千问 Qwen-VL Max",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        model: "qwen-vl-max",
        supportsVision: true
    )
    static let gpt4o = LLMPreset(
        id: "gpt-4o",
        name: "OpenAI GPT-4o",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o",
        supportsVision: true
    )
    static let custom = LLMPreset(
        id: "custom",
        name: "自定义（OpenAI 兼容）",
        baseURL: "",
        model: "",
        supportsVision: true
    )

    static let all: [LLMPreset] = [deepSeekFlash, qwenVL, gpt4o, custom]

    static func preset(for id: String) -> LLMPreset? {
        all.first { $0.id == id }
    }
}

enum DefaultPrompt {
    static let template = """
    你是一位细腻的中文日记作者。请根据这张照片和拍摄信息，以第一人称写一段简短的日记（80~150字）。
    要求：
    - 语气自然真诚，像写给自己的记录，可以带一点感受和小细节；
    - 不要标题、不要列表、不要解释，直接输出日记正文；
    - 结合时间与地点信息，让文字贴合当时的情景。

    拍摄信息：
    - 时间：{datetime}
    - 地点：{location}
    """
}

/// LLM 配置的持久化存储：普通配置走 UserDefaults，API Key 走 Keychain
@MainActor
final class LLMConfigStore: ObservableObject {
    private let defaults: UserDefaults
    private let keychainService = "com.photodiary.app"
    private let keychainAccount = "llm-api-keys"

    @Published var selectedPresetID: String {
        didSet { defaults.set(selectedPresetID, forKey: "llm.selectedPresetID") }
    }
    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: "llm.customBaseURL") }
    }
    @Published var customModel: String {
        didSet { defaults.set(customModel, forKey: "llm.customModel") }
    }
    @Published var customSupportsVision: Bool {
        didSet { defaults.set(customSupportsVision, forKey: "llm.customSupportsVision") }
    }
    @Published var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: "llm.promptTemplate") }
    }
    @Published var customExtraBody: String {
        didSet { defaults.set(customExtraBody, forKey: "llm.customExtraBody") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedPresetID = defaults.string(forKey: "llm.selectedPresetID") ?? LLMPresets.deepSeekFlash.id
        customBaseURL = defaults.string(forKey: "llm.customBaseURL") ?? ""
        customModel = defaults.string(forKey: "llm.customModel") ?? ""
        customSupportsVision = defaults.object(forKey: "llm.customSupportsVision") as? Bool ?? true
        promptTemplate = defaults.string(forKey: "llm.promptTemplate") ?? DefaultPrompt.template
        customExtraBody = defaults.string(forKey: "llm.customExtraBody") ?? ""
    }

    /// 当前生效的配置
    var preset: LLMPreset {
        if selectedPresetID == LLMPresets.custom.id {
            return LLMPreset(
                id: LLMPresets.custom.id,
                name: LLMPresets.custom.name,
                baseURL: customBaseURL,
                model: customModel,
                supportsVision: customSupportsVision,
                extraBodyJSON: customExtraBody.isEmpty ? nil : customExtraBody
            )
        }
        return LLMPresets.preset(for: selectedPresetID) ?? LLMPresets.deepSeekFlash
    }

    // MARK: - API Key（按预设分别存储在 Keychain）

    func apiKey() -> String {
        apiKeys()[preset.id] ?? ""
    }

    func setAPIKey(_ key: String) {
        var keys = apiKeys()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keys.removeValue(forKey: preset.id)
        } else {
            keys[preset.id] = trimmed
        }
        if let data = try? JSONEncoder().encode(keys) {
            KeychainHelper.save(data, service: keychainService, account: keychainAccount)
        }
    }

    var hasAPIKey: Bool {
        !apiKey().isEmpty
    }

    private func apiKeys() -> [String: String] {
        guard let data = KeychainHelper.load(service: keychainService, account: keychainAccount),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return keys
    }

    func resetPromptTemplate() {
        promptTemplate = DefaultPrompt.template
    }
}
