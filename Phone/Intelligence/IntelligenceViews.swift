import SwiftUI
import UIKit

private let intelligenceMint = Color(red: 0.55, green: 0.94, blue: 0.77)

@MainActor
struct IntelligenceSettingsView: View {
    @ObservedObject var controller: IntelligenceController
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var configurationError: String?
    @State private var asrEndpoint = ""
    @State private var asrModel = ""
    @State private var asrLanguage = ""
    @State private var asrResponseFormat = "verbose_json"
    @State private var asrKey = ""
    @State private var asrError: String?
    private var hasUnsavedProvider: Bool {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != controller.settings.apiBaseURL ||
        model.trimmingCharacters(in: .whitespacesAndNewlines) != controller.settings.model || !apiKey.isEmpty
    }
    private var languages: [String] {
        Array(Set((IntelligenceController.supportedLocales.map { $0.identifier.replacingOccurrences(of: "_", with: "-") }) +
                  [controller.settings.localeIdentifier])).sorted()
    }
    private var hasUnsavedASRProvider: Bool {
        asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != (controller.settings.remoteASRBaseURL ?? "") ||
        asrModel.trimmingCharacters(in: .whitespacesAndNewlines) != (controller.settings.remoteASRModel ?? "") ||
        asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines) != (controller.settings.remoteASRLanguage ?? "") ||
        asrResponseFormat != (controller.settings.remoteASRResponseFormat ?? "verbose_json") || !asrKey.isEmpty
    }
    var body: some View {
        Form {
            Section {
                Picker("转写方式", selection: Binding(get: { controller.transcriptionBackend }, set: {
                    controller.settings.transcriptionBackend = $0; controller.saveSettings()
                })) {
                    ForEach(IntelligenceSettings.TranscriptionBackend.allCases) { backend in Text(backend.title).tag(backend) }
                }
                if controller.transcriptionBackend == .onDevice {
                    Picker("本机转写语言", selection: Binding(get: { controller.settings.localeIdentifier }, set: {
                    controller.settings.localeIdentifier = $0; controller.saveSettings()
                    })) {
                        ForEach(languages, id: \.self) { language in
                            Text(Locale(identifier: "zh-CN").localizedString(forIdentifier: language) ?? language).tag(language)
                        }
                    }
                }
                Toggle("自动转写收到的录音", isOn: Binding(get: { controller.settings.automaticTranscription }, set: {
                    controller.settings.automaticTranscription = $0; controller.saveSettings()
                }))
                Button(controller.isProcessing ? "暂停转写" : "开始或继续转写") {
                    if controller.isProcessing { controller.pauseTranscription() }
                    else { controller.startTranscription() }
                }
                if controller.isProcessing { ProgressView("正在按所选方式处理") }
            } header: { Text("转写") } footer: {
                Text("本机模型不可用时会提示，不会自动改为上传。自动服务转写只在手机充电时运行；手动开始可在电池供电时执行。后台处理受系统运行机会限制。")
            }
            if controller.transcriptionBackend == .configuredService { remoteASRSection }
            Section {
                LabeledContent("待处理", value: "\(controller.jobs.filter { $0.state != .completed }.count) 段")
                LabeledContent("已完成", value: "\(controller.documents.filter(\.isComplete).count) 段")
                IntelligenceStatus(controller: controller)
                ForEach(Array(controller.jobs.filter { $0.state != .completed }.prefix(12))) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.clipID.uuidString.prefix(8)).font(.caption.monospaced())
                            Spacer()
                            Text(jobLabel(job.state)).font(.caption).foregroundStyle(.secondary)
                        }
                        if job.completedOffset > 0 { Text("已保存 \(Int(job.completedOffset)) 秒进度").font(.caption).foregroundStyle(.secondary) }
                        if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                if controller.jobs.contains(where: { $0.state == .failed }) {
                    Button("重试未完成任务") { controller.retryFailed() }.disabled(controller.isProcessing)
                }
            } header: { Text("处理队列") }
            Section {
                TextField("HTTPS API 地址，例如 https://…/v1", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(controller.hasAPIKey ? "输入新密钥以替换" : "API 密钥", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if controller.hasAPIKey { Label("密钥已存入本机钥匙串", systemImage: "key.fill").font(.caption).foregroundStyle(intelligenceMint) }
                Button("保存服务配置") { saveProvider() }
                if let configurationError { Text(configurationError).font(.caption).foregroundStyle(.orange) }
                Toggle("允许远程 AI 处理相关文字", isOn: Binding(get: { controller.settings.remoteAIEnabled }, set: {
                    if $0 && hasUnsavedProvider { configurationError = "请先保存服务配置，再开启远程 AI。"; return }
                    controller.settings.remoteAIEnabled = $0; controller.saveSettings()
                }))
                Button("测试连接") { Task { await controller.testConnection() } }
                    .disabled(!controller.settings.remoteAIEnabled || controller.isAIProcessing || hasUnsavedProvider)
                if controller.isAIProcessing { ProgressView("正在请求所选服务") }
                if controller.isAIProcessing { Button("暂停 AI 处理") { controller.pauseAIProcessing() } }
                if controller.hasAPIKey {
                    Button("删除 API 密钥并关闭远程 AI", role: .destructive) {
                        do { try controller.setAPIKey(""); apiKey = "" }
                        catch { configurationError = error.localizedDescription }
                    }
                }
            } header: { Text("可选 AI 服务") } footer: {
                Text("开启后，生成或测试操作会访问你配置的服务，并可能产生服务商费用。仅发送相关转写和启用的记忆，不发送原始录音。")
            }
            Section {
                Toggle("自动生成每日总结与回顾", isOn: Binding(get: { controller.settings.automaticReview }, set: {
                    controller.settings.automaticReview = $0; controller.saveSettings()
                })).disabled(!controller.settings.remoteAIEnabled)
            } header: { Text("每日回顾") } footer: {
                Text("每天录音截止后，在手机充电且系统允许运行时，等待当天录音收齐并完成转写，再生成总结与回顾。")
            }
        }
        .navigationTitle("转写与 AI").tint(intelligenceMint).preferredColorScheme(.dark)
        .onAppear {
            endpoint = controller.settings.apiBaseURL; model = controller.settings.model
            asrEndpoint = controller.settings.remoteASRBaseURL ?? ""; asrModel = controller.settings.remoteASRModel ?? ""
            asrLanguage = controller.settings.remoteASRLanguage ?? ""; asrResponseFormat = controller.settings.remoteASRResponseFormat ?? "verbose_json"
            controller.refresh()
        }
    }
    private var remoteASRSection: some View {
        Section {
            TextField("HTTPS 转写 API 地址，例如 https://…/v1", text: $asrEndpoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("转写模型名称", text: $asrModel).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("语言代码（可选，例如 zh；留空自动识别）", text: $asrLanguage)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("响应格式", selection: $asrResponseFormat) {
                Text("带时间戳 · verbose_json").tag("verbose_json")
                Text("文字 · json").tag("json")
            }
            SecureField(controller.hasRemoteASRKey ? "输入新转写密钥以替换" : "转写服务独立 API 密钥", text: $asrKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if controller.hasRemoteASRKey { Label("转写密钥已单独保存", systemImage: "key.fill").font(.caption).foregroundStyle(intelligenceMint) }
            Button("保存转写服务") { saveASRProvider() }
            if let address = try? RemoteSpeechTranscriber.endpoint(controller.settings.remoteASRBaseURL ?? "") {
                LabeledContent("录音接收地址", value: address.absoluteString).font(.caption).textSelection(.enabled)
            }
            Toggle("允许向此服务分享原始录音", isOn: Binding(get: { controller.settings.remoteASRSharingEnabled == true }, set: {
                if $0 && hasUnsavedASRProvider { asrError = "请先保存转写服务，再明确允许分享录音。"; return }
                controller.settings.remoteASRSharingEnabled = $0; controller.saveSettings()
            }))
            if let asrError { Text(asrError).font(.caption).foregroundStyle(.orange) }
            if controller.hasRemoteASRKey {
                Button("删除转写密钥并停止分享录音", role: .destructive) {
                    do { try controller.setRemoteASRKey(""); asrKey = "" } catch { asrError = error.localizedDescription }
                }
            }
        } header: { Text("可选云端或自建转写") } footer: {
            Text("这个独立开关允许将录音片段发送到上方服务，服务商可能收费。它不同于下方只发送文字的 AI 开关。关闭后会立即暂停远程转写，原声保留在本机。")
        }
    }
    private func saveASRProvider() {
        do {
            _ = try RemoteSpeechTranscriber.endpoint(asrEndpoint)
            guard !asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IntelligenceError.message("请输入转写模型名称。") }
            if !asrKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try controller.setRemoteASRKey(asrKey) }
            controller.settings.remoteASRBaseURL = asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.settings.remoteASRModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.settings.remoteASRLanguage = asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.settings.remoteASRResponseFormat = asrResponseFormat
            controller.saveSettings()
            if controller.lastError == nil { asrKey = ""; asrError = nil }
        } catch { asrError = error.localizedDescription }
    }
    private func saveProvider() {
        do {
            _ = try CompatibleAIClient.endpoint(endpoint)
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IntelligenceError.message("请输入服务商的模型名称。") }
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try controller.setAPIKey(apiKey) }
            controller.settings.apiBaseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.saveSettings()
            if controller.lastError == nil { apiKey = ""; configurationError = nil }
        } catch { configurationError = error.localizedDescription }
    }
    private func jobLabel(_ state: TranscriptionJob.State) -> String {
        switch state {
        case .pending: return "等待"
        case .running: return "正在处理"
        case .paused: return "已暂停"
        case .failed: return "需要重试"
        case .completed: return "完成"
        }
    }
}

@MainActor
struct ArchiveSearchView: View {
    @ObservedObject var controller: IntelligenceController
    let store: ClipStore
    @ObservedObject var playback: Playback
    @State private var query = ""
    @State private var question = ""
    @State private var semantic = true
    @State private var didSearch = false
    var body: some View {
        List {
            Section {
                TextField("关键词或你记得的意思", text: $query)
                    .submitLabel(.search).onSubmit { search() }
                Toggle("同时使用本机语义搜索", isOn: $semantic)
                Button("搜索本地记录", systemImage: "magnifyingglass") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("查找录音") }
            if didSearch {
                Section {
                    if controller.searchResults.isEmpty {
                        ContentUnavailableView("暂未找到片段", systemImage: "text.magnifyingglass", description: Text("换一个记录中出现过的词语，或先完成转写。"))
                    }
                    ForEach(controller.searchResults) { hit in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(hit.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(hit.text).textSelection(.enabled)
                            IntelligenceSourceRow(source: SourceCitation(clipID: hit.clipID, offset: hit.offset, text: hit.text),
                                                  store: store, playback: playback)
                        }.padding(.vertical, 4)
                    }
                } header: { Text("本地结果 · \(controller.searchResults.count)") }
            }
            Section {
                TextField("例如：我答应下周交付什么？", text: $question, axis: .vertical).lineLimit(2...5)
                Button("查历史并提问", systemImage: "bubble.left.and.text.bubble.right") {
                    Task { await controller.ask(question) }
                }.disabled(controller.isAIProcessing || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.settings.remoteAIEnabled)
                if !controller.settings.remoteAIEnabled {
                    NavigationLink("配置并开启远程 AI") { IntelligenceSettingsView(controller: controller) }
                }
                if controller.isAIProcessing { ProgressView("正在依据相关片段回答") }
                if let answer = controller.answer { IntelligenceReviewCard(review: answer, store: store, playback: playback) }
            } header: { Text("历史问答") } footer: {
                Text("提问时先在本机检索，再将相关文字发送给已启用的服务。点原始片段可回听核对。")
            }
            Section { IntelligenceStatus(controller: controller) }
        }
        .navigationTitle("搜索与问答").tint(intelligenceMint).preferredColorScheme(.dark)
        .onAppear { controller.refresh() }
    }
    private func search() { didSearch = true; controller.search(query, semantic: semantic) }
}

@MainActor
struct DailyReviewsView: View {
    @ObservedObject var controller: IntelligenceController
    let store: ClipStore
    @ObservedObject var playback: Playback
    @State private var selectedDate = Date()
    private var selectedReviews: [AIReview] {
        controller.reviews.filter { $0.kind != .answer && DailySchedule().calendar.isDate($0.day, inSameDayAs: selectedDate) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var dayDocuments: [TranscriptDocument] {
        controller.documents.filter { DailySchedule().calendar.isDate($0.startedAt, inSameDayAs: selectedDate) }
    }
    var body: some View {
        List {
            Section {
                DatePicker("录音日期", selection: $selectedDate, displayedComponents: .date)
                    .environment(\.timeZone, DailySchedule().calendar.timeZone)
                LabeledContent("已转写", value: "\(dayDocuments.filter(\.isComplete).count) 段")
                Button("转写这一天的录音") { controller.startTranscription(day: selectedDate) }.disabled(controller.isProcessing)
                if controller.isProcessing { Button("暂停转写") { controller.pauseTranscription() } }
            } header: { Text("按天回顾 · 达拉斯时间") }
            Section {
                ForEach([AIReview.Kind.summary, .highlights, .reflection]) { kind in
                    Button("生成\(kind.title)") { Task { await controller.generateReview(day: selectedDate, kind: kind) } }
                        .disabled(controller.isAIProcessing || !controller.settings.remoteAIEnabled || dayDocuments.isEmpty)
                }
                if controller.isAIProcessing { ProgressView("正在处理所选日期") }
                if let progress = controller.reviewProgress,
                   DailySchedule().calendar.isDate(progress.day, inSameDayAs: selectedDate) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: Double(progress.completedBlocks), total: Double(max(1, progress.totalBlocks)))
                        Text(progress.message).font(.caption).foregroundStyle(.secondary)
                        if progress.pendingTranscripts > 0 {
                            Text("当天尚有 \(progress.pendingTranscripts) 段录音未转写").font(.caption).foregroundStyle(.orange)
                        }
                        if !controller.isAIProcessing && (progress.phase == .paused || progress.phase == .failed) {
                            Button("继续\(progress.kind.title)") { Task { await controller.generateReview(day: progress.day, kind: progress.kind) } }
                                .disabled(!controller.settings.remoteAIEnabled)
                        }
                    }
                }
                if controller.isAIProcessing { Button("暂停 AI 处理") { controller.pauseAIProcessing() } }
                if !controller.settings.remoteAIEnabled {
                    NavigationLink("配置并开启远程 AI") { IntelligenceSettingsView(controller: controller) }
                }
                IntelligenceStatus(controller: controller)
            } header: { Text("生成") }
            Section {
                if selectedReviews.isEmpty {
                    ContentUnavailableView("还没有回顾", systemImage: "sparkles", description: Text("完成转写后，选择生成总结、高光或每日回顾。"))
                }
                ForEach(selectedReviews) { review in
                    IntelligenceReviewCard(review: review, store: store, playback: playback).padding(.vertical, 6)
                }
            } header: { Text("已保存") }
        }
        .navigationTitle("每日回顾").tint(intelligenceMint).preferredColorScheme(.dark)
        .onAppear { controller.refresh() }
    }
}

@MainActor
struct MemoriesView: View {
    @ObservedObject var controller: IntelligenceController
    @State private var newMemory = ""
    @State private var editing: MemoryFact?
    var body: some View {
        List {
            Section {
                TextField("添加希望 AI 记住的事实", text: $newMemory, axis: .vertical).lineLimit(2...5)
                Button("保存记忆") {
                    controller.saveMemory(newMemory)
                    if controller.lastError == nil { newMemory = "" }
                }.disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("手动记忆") }
            Section {
                if controller.memories.isEmpty { Text("还没有记忆").foregroundStyle(.secondary) }
                ForEach(controller.memories.sorted { $0.updatedAt > $1.updatedAt }) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(memory.text).textSelection(.enabled)
                        Toggle(memory.isActive ? "已启用" : "未启用", isOn: Binding(get: { memory.isActive }, set: { _ in controller.toggleMemory(memory.id) }))
                            .font(.caption)
                        HStack {
                            Button("编辑") { editing = memory }
                            Spacer()
                            Button("删除", role: .destructive) { controller.deleteMemory(memory.id) }
                        }.font(.caption)
                        if !memory.sourceCitations.isEmpty {
                            Text("来自 \(memory.sourceCitations.count) 个录音片段").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
            } header: { Text("可管理的记忆") } footer: {
                Text("AI 提出的记忆建议默认停用。仅启用的记忆会用于之后的远程 AI 请求；停用不会改写已保存的回顾。")
            }
            if let error = controller.lastError { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
        }
        .navigationTitle("记忆").tint(intelligenceMint).preferredColorScheme(.dark)
        .sheet(item: $editing) { memory in IntelligenceMemoryEditor(controller: controller, memory: memory) }
    }
}

@MainActor
private struct IntelligenceMemoryEditor: View {
    @ObservedObject var controller: IntelligenceController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MemoryFact
    init(controller: IntelligenceController, memory: MemoryFact) {
        self.controller = controller; _draft = State(initialValue: memory)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $draft.text).frame(minHeight: 180)
                Toggle("启用此记忆", isOn: $draft.isActive)
                if let error = controller.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            .navigationTitle("编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        controller.updateMemory(draft)
                        if controller.lastError == nil { dismiss() }
                    }.disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.tint(intelligenceMint).preferredColorScheme(.dark)
    }
}

@MainActor
private struct IntelligenceStatus: View {
    @ObservedObject var controller: IntelligenceController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if let error = controller.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

@MainActor
private struct IntelligenceReviewCard: View {
    let review: AIReview
    let store: ClipStore
    @ObservedObject var playback: Playback
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.headline)
            Text((try? AttributedString(markdown: review.body)) ?? AttributedString(review.body)).textSelection(.enabled)
            if let coverage = review.coverageNote { Text(coverage).font(.caption).foregroundStyle(.orange) }
            ForEach(review.citations) { source in IntelligenceSourceRow(source: source, store: store, playback: playback) }
            Button("复制文字", systemImage: "doc.on.doc") { UIPasteboard.general.string = review.title + "\n\n" + review.body }
                .font(.caption)
            Text(review.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct IntelligenceSourceRow: View {
    let source: SourceCitation
    let store: ClipStore
    @ObservedObject var playback: Playback
    private var clip: Clip? { (try? store.clips())?.first { $0.id == source.clipID } }
    private var clock: String {
        let seconds = source.offset.isFinite ? max(0, Int(source.offset)) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let clip, store.hasLocalAudio(source.clipID) {
                Button { playback.play(clip, store: store, offset: source.offset) } label: {
                    Label("回听原始片段 · \(clock)", systemImage: playback.playingID == source.clipID ? "waveform" : "play.circle")
                }.font(.caption)
            } else if let url = store.cloudReceipt(source.clipID)?.viewURL {
                Link(destination: url) { Label("在 Drive 打开原声 · \(clock)", systemImage: "arrow.up.right.square") }.font(.caption)
            } else { Label("原声暂不可用 · \(clock)", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
