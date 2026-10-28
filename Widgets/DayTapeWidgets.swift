import WidgetKit
import SwiftUI

struct TapeEntry: TimelineEntry {
    let date: Date
    let snapshot: DayTapeWidgetSnapshot?
}

struct TapeProvider: TimelineProvider {
    func placeholder(in context: Context) -> TapeEntry { TapeEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (TapeEntry) -> Void) {
        completion(TapeEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TapeEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [TapeEntry(date: now, snapshot: WidgetSnapshotStore.load())],
                            policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct TapeWidgetView: View {
    let entry: TapeEntry
    @Environment(\.widgetFamily) private var family
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)
    private var minutes: String { "\(Int((entry.snapshot?.recordedSeconds ?? 0) / 60)) 分钟" }
    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 2) {
                    Image(systemName: "mic.fill").foregroundStyle(mint)
                    Text("\(Int((entry.snapshot?.recordedSeconds ?? 0) / 60))").font(.caption.monospacedDigit())
                }
            } else if family == .accessoryInline {
                Text(entry.snapshot.map { "DayTape · \($0.recordingState) · \(minutes)" } ?? "打开 DayTape")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Label("DAYTAPE", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(mint)
                    if let snapshot = entry.snapshot {
                        Text(minutes).font(.title3.monospacedDigit()).bold()
                        Text(snapshot.recordingState).font(.caption)
                        #if os(iOS)
                        if family == .systemMedium {
                            Text("\(snapshot.clipCount) 段 · 待备份 \(snapshot.pendingCount) 段").font(.caption)
                            if let title = snapshot.reviewTitle { Text(title).font(.caption).lineLimit(2).privacySensitive() }
                        }
                        #endif
                        Text(snapshot.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    } else { Text("打开 App 更新状态").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.06, green: 0.10, blue: 0.09) }
        #if os(watchOS)
        .widgetURL(URL(string: "daytape://record"))
        #else
        .widgetURL(URL(string: "daytape://library"))
        #endif
    }
}

@main
struct DayTapeWidgets: Widget {
    let kind = "DayTapeStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TapeProvider()) { TapeWidgetView(entry: $0) }
            .configurationDisplayName("录音与回顾")
            .description("查看最近更新的录音状态和当天时长。")
            #if os(watchOS)
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
            #endif
    }
}
