import SwiftUI
import GoogleSignInSwift

@MainActor
struct BackupSetupView: View {
    private enum Step { case account, time, done }
    @ObservedObject var archive: NightArchiveController
    @ObservedObject var connection: DriveConnection
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var wifiOnly: Bool
    @State private var keepOneDay: Bool
    @State private var saving = false
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)

    init(archive: NightArchiveController, reconnect: Bool = false) {
        self.archive = archive; self.connection = archive.connection
        _wifiOnly = State(initialValue: archive.settings.wifiOnly)
        _keepOneDay = State(initialValue: archive.settings.purgeAfterVerification)
        _step = State(initialValue: reconnect || archive.connection.accountID == nil ? .account : .time)
    }
    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .account: accountStep
                case .time: timeStep
                case .done: doneStep
                }
            }
            .navigationTitle(step == .done ? "设置完成" : "开启自动备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(archive.settings.enabled ? "取消" : "暂不开启") { dismiss() }.disabled(saving || archive.connectingBackup)
                    }
                }
            }
        }
        .tint(mint).preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving || archive.connectingBackup)
        .onAppear { archive.beginBackupSetup() }
    }
    private var accountStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "externaldrive.badge.icloud").font(.system(size: 54)).foregroundStyle(mint)
                Text("连接 Google Drive").font(.title.bold())
                if let error = archive.backupSetupError { Text(error).font(.callout).foregroundStyle(.orange) }
                if archive.connectingBackup {
                    HStack { ProgressView(); Text("正在连接 Google…") }
                } else {
                    GoogleSignInButton(scheme: .light, style: .wide) {
                        Task { if await archive.connectBackupAccount() { step = .time } }
                    }.frame(height: 50)
                }
            }.padding(24)
        }
    }
    private var timeStep: some View {
        Form {
            Section {
                Label(connection.accountLabel, systemImage: "checkmark.circle.fill").foregroundStyle(mint)
                Button("使用其他 Google 账户") { step = .account }.disabled(saving || archive.activeCount > 0)
            } header: { Text("已连接 Google Drive") }
            Section {
                LabeledContent("自动上传", value: "iPhone 充电时")
                LabeledContent("积压提醒", value: "超过 24 小时")
            } header: { Text("备份条件") }
            Section {
                Toggle("仅在 Wi-Fi 下上传", isOn: $wifiOnly)
                Picker("手机保留", selection: $keepOneDay) {
                    Text("最近一天").tag(true)
                    Text("全部录音").tag(false)
                }
            } header: { Text("其他选项") }
            Section {
                if let error = archive.backupSetupError { Text(error).foregroundStyle(.orange) }
                Button {
                    saving = true
                    Task {
                        if await archive.saveAutomaticBackup(wifiOnly: wifiOnly, keepOneDay: keepOneDay) {
                            step = .done
                            await archive.configureRoutine()
                        }
                        saving = false
                    }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() }; Text(saving ? "正在保存…" : "完成并开启").bold(); Spacer() }
                }.disabled(saving)
            }
        }
    }
    private var doneStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 68)).foregroundStyle(mint)
            Text("自动备份已开启").font(.title.bold())
            if let hint = archive.notificationHint { Text(hint).font(.caption).foregroundStyle(.orange) }
            Button("完成") { dismiss() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }.padding(28)
    }
}
