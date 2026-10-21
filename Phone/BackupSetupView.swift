import SwiftUI
import GoogleSignInSwift

@MainActor
struct BackupSetupView: View {
    private enum Step { case account, time, done }
    private enum Preset: String { case atStop, later, custom }
    @ObservedObject var archive: NightArchiveController
    @ObservedObject var connection: DriveConnection
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var clock: BackupClock
    @State private var preset: Preset
    @State private var wifiOnly: Bool
    @State private var keepOneDay: Bool
    @State private var saving = false
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)

    init(archive: NightArchiveController, reconnect: Bool = false) {
        self.archive = archive; self.connection = archive.connection
        let value = archive.uploadClock
        _clock = State(initialValue: value)
        _preset = State(initialValue: value == BackupClock() ? .atStop : (value == BackupClock(hour: 23, minute: 0) ? .later : .custom))
        _wifiOnly = State(initialValue: archive.settings.wifiOnly)
        _keepOneDay = State(initialValue: archive.settings.purgeAfterVerification)
        _step = State(initialValue: reconnect || archive.connection.accountID == nil ? .account : .time)
    }
    private var timeSelection: Binding<Date> {
        Binding(get: {
            archive.routine.calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = archive.routine.calendar.dateComponents([.hour, .minute], from: date)
            clock = BackupClock(hour: parts.hour ?? 22, minute: parts.minute ?? 0)
        })
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
                Picker("每天备份时间", selection: $preset) {
                    Text("22:00").tag(Preset.atStop)
                    Text("23:00").tag(Preset.later)
                    Text("自定义").tag(Preset.custom)
                }.pickerStyle(.segmented)
                if preset == .custom {
                    DatePicker("每天备份时间", selection: timeSelection, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, archive.routine.calendar.timeZone)
                }
                if !clock.isValid(for: archive.routine) {
                    Text("时间范围：22:00–07:59").foregroundStyle(.orange)
                }
            } header: { Text("备份时间") }
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
                        if await archive.saveAutomaticBackup(clock: clock, wifiOnly: wifiOnly, keepOneDay: keepOneDay) {
                            step = .done
                            await archive.configureRoutine()
                        }
                        saving = false
                    }
                } label: {
                    HStack { Spacer(); if saving { ProgressView() }; Text(saving ? "正在保存…" : "完成并开启").bold(); Spacer() }
                }.disabled(saving || !clock.isValid(for: archive.routine))
            }
        }
        .onChange(of: preset) { _, value in
            if value == .atStop { clock = BackupClock() }
            if value == .later { clock = BackupClock(hour: 23, minute: 0) }
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
