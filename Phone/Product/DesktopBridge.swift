import Foundation
import Combine
import Network
import CryptoKit
import Darwin
import SwiftUI
import UIKit

private struct BridgeRequest: Decodable {
    let id: String
    let timestamp: Double
    let command: String
    let query: String?
    let day: String?
    let clipID: UUID?
}

@MainActor
final class DesktopBridge: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "电脑接入未开启"
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var pairingKey = ""
    @Published var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var endDate = Date()
    @Published var allowAudio = false
    private let store: ClipStore
    private let intelligence: IntelligenceController
    private var listener: NWListener?
    private var key = Data()
    private var generation = UUID()
    private var seen: Set<String> = []
    private var connections: [UUID:NWConnection] = [:]
    init(store: ClipStore, intelligence: IntelligenceController) { self.store = store; self.intelligence = intelligence }
    var address: String {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return "请连接 Wi-Fi" }
        defer { freeifaddrs(addresses) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            if let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: item.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = item.ifa_next
        }
        return "请连接 Wi-Fi"
    }
    var pairingJSON: String {
        let value: [String:Any] = ["host":address, "port":Int(port), "key":pairingKey]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    func start() {
        stop()
        guard startDate <= endDate else { status = "请选择有效的日期范围"; return }
        guard UIApplication.shared.applicationState == .active else { status = "请在前台打开此页面再开启接入"; return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            let random = SymmetricKey(size: .bits256)
            key = random.withUnsafeBytes { Data($0) }; pairingKey = key.base64EncodedString()
            let current = UUID(); generation = current; seen.removeAll()
            listener.service = NWListener.Service(name: "DayTape-" + String(current.uuidString.prefix(6)), type: "_daytape._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self = self, self.generation == current else { return }
                    if case .ready = state { self.port = listener?.port?.rawValue ?? 0; self.running = true; self.status = "电脑可在选定范围内只读访问" }
                    if case .failed = state { self.stop(); self.status = "本地连接不可用，请检查 Wi-Fi 与本地网络权限" }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, generation: current) }
            }
            self.listener = listener; status = "正在开启本地接入…"
            listener.start(queue: DispatchQueue(label: "daytape.desktop.listener"))
        } catch { stop(); status = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        key.removeAll(); pairingKey = ""; port = 0; seen.removeAll(); running = false
        status = "电脑接入已关闭"
    }
    private func accept(_ connection: NWConnection, generation current: UUID) {
        guard current == generation, running, connections.count < 3 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "daytape.desktop.connection"))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { connection.cancel() }
        readBridgeBytes(connection, count: 4) { [weak self] header in
            guard let header = header, header.count == 4 else { connection.cancel(); return }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 28, length <= 64 * 1024 else { connection.cancel(); return }
            readBridgeBytes(connection, count: Int(length)) { bytes in
                Task { @MainActor in
                    guard let self = self else { connection.cancel(); return }
                    defer { self.connections.removeValue(forKey: id) }
                    guard let bytes = bytes, self.generation == current, self.running else { connection.cancel(); return }
                    do {
                        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        guard !self.seen.contains(hash), self.seen.count < 1024 else { throw BridgeCrypto.Failure.invalidFrame }
                        let plaintext = try BridgeCrypto.open(bytes, key: self.key)
                        let request = try JSONDecoder().decode(BridgeRequest.self, from: plaintext)
                        guard request.timestamp.isFinite, abs(Date().timeIntervalSince1970 - request.timestamp) < 120,
                              request.id.utf8.count <= 80 else { throw BridgeCrypto.Failure.invalidFrame }
                        self.seen.insert(hash)
                        let response = try self.response(request)
                        let message = try JSONSerialization.data(withJSONObject: ["id":request.id, "timestamp":Date().timeIntervalSince1970, "result":response], options: [.sortedKeys])
                        guard message.count <= 4 * 1024 * 1024 else { throw IntelligenceError.message("结果过大，请缩小日期范围。") }
                        let encrypted = try BridgeCrypto.seal(message, key: self.key)
                        var size = UInt32(encrypted.count).bigEndian
                        var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(encrypted)
                        connection.send(content: frame, completion: .contentProcessed { _ in connection.cancel() })
                    } catch { connection.cancel() }
                }
            }
        }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func response(_ request: BridgeRequest) throws -> Any {
        let calendar = DailySchedule().calendar
        let begin = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        let clips = try store.clips().filter { $0.startedAt >= begin && $0.startedAt < end }
        let ids = Set(clips.map(\.id))
        let documents = intelligence.documents.filter { ids.contains($0.clipID) }
        switch request.command {
        case "status": return ["recordings":clips.count, "transcripts":documents.count, "audioAllowed":allowAudio]
        case "search":
            let query = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.utf8.count <= 1024 else { return [] }
            let hits = documents.flatMap { document in document.segments.filter { $0.text.localizedCaseInsensitiveContains(query) }.map {
                SourceCitation(clipID: document.clipID, offset: $0.offset, text: $0.text)
            }}
            return try object(Array(hits.prefix(100)))
        case "day":
            let day = request.day ?? ""
            return try object(Array(documents.filter { DailySchedule().dayKey($0.startedAt) == day }.prefix(200)))
        case "reviews": return try object(Array(intelligence.reviews.filter { ArchiveScopePolicy.permits($0.inputClipIDs, within: ids) }.suffix(50)))
        case "memories": return try object(Array(intelligence.memories.filter { $0.isActive && ArchiveScopePolicy.permits($0.inputClipIDs, within: ids) }.prefix(100)))
        case "audio":
            guard allowAudio, let id = request.clipID, let clip = clips.first(where: { $0.id == id }),
                  clip.byteCount <= 2 * 1024 * 1024, store.retainAudio(id) else { return ["error":"原声未授权、不在所选范围或本机未保留"] }
            defer { store.releaseAudio(id) }
            let data = try Data(contentsOf: store.audioURL(id))
            return ["clipID":id.uuidString, "mimeType":"audio/mp4", "sha256":clip.sha256, "base64":data.base64EncodedString()]
        default: return ["error":"只支持 status、search、day、reviews、memories、audio 只读请求"]
        }
    }
}

private func readBridgeBytes(_ connection: NWConnection, count: Int, buffer: Data = Data(), completion: @escaping (Data?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, complete, error in
        guard error == nil, let data = data, !data.isEmpty else { completion(nil); return }
        var next = buffer; next.append(data)
        if next.count == count { completion(next) }
        else if complete { completion(nil) }
        else { readBridgeBytes(connection, count: count, buffer: next, completion: completion) }
    }
}

struct DesktopBridgeView: View {
    @ObservedObject var bridge: DesktopBridge
    @State private var copied = false
    var body: some View {
        Form {
            Section("允许电脑读取的范围") {
                DatePicker("开始日期", selection: $bridge.startDate, displayedComponents: .date)
                DatePicker("结束日期", selection: $bridge.endDate, displayedComponents: .date)
                Toggle("允许读取保留的原声", isOn: $bridge.allowAudio)
            }.disabled(bridge.running)
            Section {
                Button(bridge.running ? "关闭电脑接入" : "开启本地只读接入") { if bridge.running { bridge.stop() } else { bridge.start() } }
                Text(bridge.status).font(.caption).foregroundStyle(.secondary)
                if bridge.running {
                    LabeledContent("手机地址", value: bridge.address)
                    LabeledContent("端口", value: "\(bridge.port)")
                    Button(copied ? "连接配置已复制" : "复制加密连接配置") { UIPasteboard.general.string = bridge.pairingJSON; copied = true }
                    Text("保持此页在前台，并让电脑与手机连接同一 Wi-Fi。关闭接入后，本次连接配置立即失效。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("电脑只读接入")
        .onDisappear { bridge.stop() }
    }
}
