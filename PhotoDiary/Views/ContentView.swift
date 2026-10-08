import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @StateObject private var store = DiaryStore()
    @StateObject private var llmConfig = LLMConfigStore()
    @StateObject private var locationService = LocationService()
    @StateObject private var profileStore = UserProfileStore()

    @State private var showingSettings = false
    @State private var showingCamera = false
    @State private var showingPhotosPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var draft: EntryDraft?
    @State private var importError: String?
    @State private var locationPrefetch: Task<CLLocation?, Never>?
    @State private var searchText = ""

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("光影日记")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityIdentifier("settingsButton")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if cameraAvailable {
                                Button {
                                    // 打开相机的同时就开始定位，拍完整刻的位置更准、等待更短
                                    locationPrefetch = Task { await locationService.requestCurrentLocation() }
                                    showingCamera = true
                                } label: {
                                    Label("拍照", systemImage: "camera")
                                }
                            }
                            // 注意：PhotosPicker 直接放在 Menu 里无法弹出（SwiftUI 已知问题），
                            // 改为 Button 触发，用 .photosPicker(isPresented:) 呈现
                            Button {
                                showingPhotosPicker = true
                            } label: {
                                Label("从相册导入", systemImage: "photo.on.rectangle")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .accessibilityIdentifier("addEntryMenu")
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(config: llmConfig, profileStore: profileStore, diaryStore: store)
                }
                .photosPicker(isPresented: $showingPhotosPicker, selection: $photosPickerItem, matching: .images)
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraPicker { image in
                        handleCapture(image)
                    }
                    .ignoresSafeArea()
                }
                .sheet(item: $draft) { draft in
                    AddEntryView(draft: draft, store: store, config: llmConfig, profileStore: profileStore)
                }
                .onChange(of: photosPickerItem) { _, item in
                    Task { await importPhoto(item) }
                }
                .alert("导入失败", isPresented: .constant(importError != nil)) {
                    Button("好的") { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
        }
    }

    /// 搜索过滤后的日记列表
    private var displayedDays: [DiaryDay] {
        DiarySearch.filter(store.days, query: searchText)
    }

    @ViewBuilder
    private var content: some View {
        // Group 承载 searchable：搜索无结果切到空态视图时搜索框不消失
        Group {
            if store.days.isEmpty {
            ContentUnavailableView {
                Label("还没有日记", systemImage: "camera.on.rectangle")
            } description: {
                Text("点右上角 + 拍照或导入照片，\nAI 会自动帮你写好今天的日记。")
                    .multilineTextAlignment(.center)
            } actions: {
                // 首次使用引导：先填 Key
                if !llmConfig.hasAPIKey {
                    Button("先设置 API Key") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if displayedDays.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                // 未配置 Key 时的常驻引导横幅
                if !llmConfig.hasAPIKey {
                    Section {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("还没有设置 API Key，点这里配置后 AI 才能写日记", systemImage: "key.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(displayedDays) { day in
                    NavigationLink {
                        DayDetailView(dayKey: day.key, store: store, config: llmConfig, profileStore: profileStore)
                    } label: {
                        DayRowView(day: day, store: store)
                    }
                }
            }
            .listStyle(.plain)
            }
        }
        // 挂在整个内容区而非 List 上：搜索无结果切到空态视图时搜索框不消失
        .searchable(text: $searchText, prompt: "搜索正文、地点、日期")
    }

    // MARK: - 拍照 / 导入

    private func handleCapture(_ image: UIImage) {
        Task {
            // 等相机界面完全关闭后再弹编辑页
            try? await Task.sleep(nanoseconds: 400_000_000)
            // 优先用打开相机时预取的定位
            let location: CLLocation?
            if let prefetch = locationPrefetch {
                location = await prefetch.value
            } else {
                location = await locationService.requestCurrentLocation()
            }
            locationPrefetch = nil
            let locationName = await geocode(location)
            draft = EntryDraft(image: image, takenAt: Date(), location: location, locationName: locationName)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            let imported = try await PhotoImporter.load(from: item)
            let locationName = await geocode(imported.location)
            draft = EntryDraft(
                image: imported.image,
                takenAt: imported.takenAt ?? Date(),
                location: imported.location,
                locationName: locationName
            )
        } catch {
            importError = error.localizedDescription
        }
        photosPickerItem = nil
    }

    private func geocode(_ location: CLLocation?) async -> String? {
        guard let location else { return nil }
        return await Geocoder.placeName(for: location)
    }
}

/// 日记列表里的一天
private struct DayRowView: View {
    let day: DiaryDay
    @ObservedObject var store: DiaryStore

    var body: some View {
        HStack(spacing: 12) {
            if let imageName = day.entries.first(where: { $0.imageFileName != nil })?.imageFileName,
               let thumbnail = Thumbnailer.image(at: store.imageURL(for: imageName), maxPixelSize: 200) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "text.book.closed")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(day.title)
                    .font(.headline)
                Text("\(day.entries.count) 条记录 · \(day.summary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
