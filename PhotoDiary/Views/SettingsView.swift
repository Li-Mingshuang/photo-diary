import SwiftUI

/// 设置：LLM 预设 / API Key / Prompt 模板 / 连接测试
struct SettingsView: View {
    @ObservedObject var config: LLMConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var isTesting = false
    @State private var testResult: String?

    private var isCustom: Bool {
        config.selectedPresetID == LLMPresets.custom.id
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("大模型服务") {
                    Picker("服务", selection: $config.selectedPresetID) {
                        ForEach(LLMPresets.all) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .onChange(of: config.selectedPresetID) { _, _ in
                        apiKeyInput = config.apiKey()
                        testResult = nil
                    }

                    if isCustom {
                        TextField("Base URL，如 https://api.example.com/v1", text: $config.customBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("模型名，如 some-vision-model", text: $config.customModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("该模型支持图片输入", isOn: $config.customSupportsVision)
                        TextField(#"额外请求参数 JSON（可选），如 {"thinking":{"type":"disabled"}}"#, text: $config.customExtraBody, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote)
                    } else {
                        LabeledContent("Base URL", value: config.preset.baseURL)
                            .font(.footnote)
                        LabeledContent("模型", value: config.preset.model)
                            .font(.footnote)
                    }
                }

                Section {
                    SecureField("API Key", text: $apiKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: apiKeyInput) { _, newValue in
                            config.setAPIKey(newValue)
                            testResult = nil
                        }
                    if !isCustom, config.selectedPresetID == LLMPresets.deepSeekFlash.id {
                        Link("去 DeepSeek 开放平台申请 Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                            .font(.footnote)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Key 仅保存在本机 Keychain 中。")
                }

                Section {
                    TextEditor(text: $config.promptTemplate)
                        .frame(minHeight: 180)
                    Button("恢复默认模板", role: .none) {
                        config.resetPromptTemplate()
                    }
                    .font(.footnote)
                } header: {
                    Text("Prompt 模板")
                } footer: {
                    Text("可用占位符：{datetime}、{date}、{time}、{location}。")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting || apiKeyInput.isEmpty || config.preset.baseURL.isEmpty || config.preset.model.isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("成功") ? .green : .red)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                apiKeyInput = config.apiKey()
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            let reply = try await LLMService().testConnection(config: config.preset, apiKey: apiKeyInput)
            testResult = "成功：\(reply)"
        } catch {
            testResult = "失败：\(error.localizedDescription)"
        }
    }
}
