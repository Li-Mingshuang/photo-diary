import SwiftUI

/// 设置：LLM 预设 / API Key / Prompt 模板 / 用户画像 / 连接测试
struct SettingsView: View {
    @ObservedObject var config: LLMConfigStore
    @ObservedObject var profileStore: UserProfileStore
    @ObservedObject var diaryStore: DiaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var bioName = ""
    @State private var bioAbout = ""
    @State private var isDistilling = false
    @State private var distillMessage: String?
    @State private var editingPersona = false

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
                    TextField("称呼（如：阿明）", text: $bioName)
                        .onSubmit { profileStore.updateBio(name: bioName, about: bioAbout) }
                    TextField("一句话简介（城市/职业/兴趣，可选）", text: $bioAbout)
                        .onSubmit { profileStore.updateBio(name: bioName, about: bioAbout) }

                    if profileStore.profile.personaText.isEmpty {
                        Text("还没有画像。写几天日记、改几篇 AI 生成内容后，点下方按钮提炼。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(profileStore.profile.personaText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                        Button("编辑画像") { editingPersona = true }
                            .font(.footnote)
                    }

                    Button {
                        Task { await distillNow() }
                    } label: {
                        HStack {
                            Text(profileStore.profile.personaText.isEmpty ? "提炼画像" : "重新提炼画像")
                            if isDistilling {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isDistilling || !config.hasAPIKey)

                    if let distillMessage {
                        Text(distillMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("用户画像")
                } footer: {
                    if let updatedAt = profileStore.profile.updatedAt {
                        Text("基于 \(profileStore.profile.signalCount) 条信号 · 更新于 \(updatedAt.formatted(date: .numeric, time: .shortened)) · 待提炼信号 \(profileStore.pendingSignals) 条（满 \(UserProfileStore.autoDistillThreshold) 条自动提炼）。画像只存在本机 diaries/profile.md，可手改。")
                    } else {
                        Text("画像从你的日记修改记录、标签与基本信息中沉淀，只存在本机 diaries/profile.md，可手改；满 \(UserProfileStore.autoDistillThreshold) 条信号自动提炼。")
                    }
                }
                .onChange(of: bioName) { _, _ in profileStore.updateBio(name: bioName, about: bioAbout) }
                .onChange(of: bioAbout) { _, _ in profileStore.updateBio(name: bioName, about: bioAbout) }
                .sheet(isPresented: $editingPersona) {
                    PersonaEditorView(profileStore: profileStore)
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
                bioName = profileStore.profile.bioName
                bioAbout = profileStore.profile.bioAbout
            }
        }
    }

    private func distillNow() async {
        isDistilling = true
        distillMessage = nil
        defer { isDistilling = false }
        do {
            try await UserProfileStore.distill(profileStore: profileStore, config: config, days: diaryStore.days)
            distillMessage = "提炼完成，已更新画像。"
        } catch {
            distillMessage = "提炼失败：\(error.localizedDescription)"
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

/// 画像全文编辑（与 diaries/profile.md 双向同步）
private struct PersonaEditorView: View {
    @ObservedObject var profileStore: UserProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(8)
                .navigationTitle("编辑画像")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            profileStore.updatePersona(text)
                            dismiss()
                        }
                    }
                }
                .onAppear { text = profileStore.profile.personaText }
        }
    }
}
