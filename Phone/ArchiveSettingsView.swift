import SwiftUI

@MainActor
struct ArchiveSettingsView: View {
    @ObservedObject var archive: NightArchiveController
    @ObservedObject var connection: DriveConnection
    @State private var showBackupSetup = false
    @State private var reconnectGoogle = false
    private var automaticBackup: Binding<Bool> {
        Binding(get: { archive.settings.enabled }, set: { enabled in
            if enabled { reconnectGoogle = false; showBackupSetup = true }
            else { Task { await archive.enable(false) } }
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("自动备份", isOn: automaticBackup)
                if archive.settings.enabled {
                    LabeledContent("每天备份", value: archive.uploadClock.label)
                    LabeledContent("手机保留", value: archive.settings.purgeAfterVerification ? "最近一天" : "全部录音")
                    LabeledContent("网络", value: archive.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 或移动网络")
                    Button("修改备份设置") { reconnectGoogle = false; showBackupSetup = true }
                    Text(archive.status).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("录音备份") }
            if !archive.settings.enabled, connection.accountID != nil {
                Section {
                    Text(connection.accountLabel).font(.subheadline)
                    Button("断开 Google Drive 连接", role: .destructive) { archive.disconnect() }.disabled(archive.activeCount > 0)
                } header: { Text("已连接账户") }
            }
            if archive.settings.enabled {
                Section {
                    Text(connection.accountLabel).font(.subheadline)
                    Button("重新连接 Google Drive") { reconnectGoogle = true; showBackupSetup = true }.disabled(archive.activeCount > 0)
                    Button("断开连接", role: .destructive) { archive.disconnect() }.disabled(archive.activeCount > 0)
                } header: { Text("Google Drive") }
                Section {
                    if let error = archive.errorText { Text(error).foregroundStyle(.orange) }
                    if let day = archive.latestCompleteDay { LabeledContent("最近完整备份日", value: day) }
                    Text("本地 \(archive.localCount) 段 · 已备份 \(archive.cloudCount) 段").font(.subheadline)
                    Button("立即备份") { archive.archiveNow() }
                    Button("接收备份完成通知") { Task { await archive.configureRoutine() } }
                    if let hint = archive.notificationHint { Text(hint).font(.caption).foregroundStyle(.orange) }
                } header: { Text("备份状态") }
            }
            Section {
                LabeledContent("早晨提醒", value: "08:00")
                LabeledContent("停止录音", value: "22:00")
            } header: { Text("录音 · 达拉斯时间") }
        }
        .navigationTitle("录音与备份")
        .sheet(isPresented: $showBackupSetup) { BackupSetupView(archive: archive, reconnect: reconnectGoogle) }
        .task { await archive.restoreBackupConnection() }
    }
}
