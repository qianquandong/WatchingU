import Foundation
import Combine
import HealthKit

/// All context is optional. Reading a recording's health window runs on iPhone, never on Watch.
@MainActor
final class PhoneContextService: ObservableObject {
    @Published private(set) var settings: RecordingContextSettings
    @Published private(set) var status = "健康与位置记录默认关闭"
    @Published private(set) var errorText: String?
    @Published private(set) var currentSnapshot: HealthContextSnapshot?
    @Published private(set) var refreshing = false
    private let context: RecordingContextStore
    private let audioStore: ClipStore
    private let connectivity: Connectivity
    private let health = HKHealthStore()
    private var refreshID = UUID()
    private var settingsObserver: NSObjectProtocol?
    private var contextObserver: NSObjectProtocol?
    private var healthSettingID = UUID()

    init(store: ClipStore, connectivity: Connectivity) throws {
        audioStore = store; self.connectivity = connectivity
        context = try RecordingContextStore(root: store.root)
        settings = try context.settings()
        if settings.healthEnabled || settings.locationEnabled { status = "按已开启的选项关联可用情境数据" }
        settingsObserver = NotificationCenter.default.addObserver(forName: .recordingContextSettingsChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let value = try? self.context.settings() else { return }
                self.settings = value
                if !value.healthEnabled { self.refreshID = UUID(); self.currentSnapshot = nil; self.refreshing = false }
            }
        }
        contextObserver = NotificationCenter.default.addObserver(forName: .recordingContextChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }
    deinit {
        if let observer = settingsObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = contextObserver { NotificationCenter.default.removeObserver(observer) }
    }
    var healthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    func setLocationEnabled(_ enabled: Bool) {
        do {
            var next = try context.settings(); next.locationEnabled = enabled
            try connectivity.configureContextSettings(next)
            settings = next; errorText = nil
            status = enabled ? "已请求手表按低频率记录大致位置；首次使用需允许位置权限" : "位置记录已关闭"
        } catch { errorText = "位置设置未保存，请重试。" }
    }
    func setHealthEnabled(_ enabled: Bool) async {
        let settingID = UUID(); healthSettingID = settingID
        if enabled {
            guard healthAvailable else { errorText = "此设备无法读取 Apple 健康数据。"; return }
            do {
                let identifiers: [HKQuantityTypeIdentifier] = [.heartRate, .heartRateVariabilitySDNN, .stepCount, .activeEnergyBurned]
                let quantities: [HKObjectType] = identifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
                var read = Set(quantities)
                if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { read.insert(sleep) }
                try await health.requestAuthorization(toShare: [], read: read)
                guard healthSettingID == settingID else { return }
                try saveHealthSetting(true)
                // HealthKit deliberately does not reveal whether individual read permissions were granted.
                status = "健康关联已开启；仅显示已授权且存在的样本，不推断情绪或诊断压力"
            } catch { errorText = "未能开启健康关联，录音仍可使用。" }
        } else {
            do {
                try saveHealthSetting(false); refreshID = UUID(); currentSnapshot = nil; refreshing = false
                status = "健康关联已关闭"
            } catch { errorText = "健康设置未保存，请重试。" }
        }
    }
    private func saveHealthSetting(_ enabled: Bool) throws {
        var next = try context.settings(); next.healthEnabled = enabled
        try connectivity.configureContextSettings(next); settings = next; errorText = nil
    }
    func marks(for clip: Clip) -> [RecordingMark] {
        try? context.resolveMarks(clips: [clip])
        return ((try? context.marks()) ?? []).filter { $0.clipID == clip.id }
    }
    func allMarks() -> [RecordingMark] {
        if let clips = try? audioStore.clips() { try? context.resolveMarks(clips: clips) }
        return (try? context.marks()) ?? []
    }
    func location(for clip: Clip) -> RecordingContextPacket? { try? context.location(for: clip) }
    func healthSnapshot(for clip: Clip) -> HealthContextSnapshot? {
        guard settings.healthEnabled else { return nil }
        return try? context.health(for: clip.id)
    }
    func deleteContext(for clip: Clip) throws {
        try context.deleteContext(for: clip)
        refreshID = UUID(); refreshing = false
        if currentSnapshot?.clipID == clip.id { currentSnapshot = nil }
        NotificationCenter.default.post(name: .recordingContextChanged, object: nil)
    }
    func refresh(for clip: Clip) async {
        guard settings.healthEnabled, healthAvailable else { currentSnapshot = nil; return }
        let id = UUID(); refreshID = id; refreshing = true
        defer { if refreshID == id { refreshing = false } }
        let start = clip.startedAt, end = clip.startedAt.addingTimeInterval(clip.duration)
        do {
            async let heart = quantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, from: start, to: end)
            async let hrv = quantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), options: .discreteAverage, from: start, to: end)
            async let steps = quantity(.stepCount, unit: .count(), options: .cumulativeSum, from: start, to: end)
            async let energy = quantity(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, from: start, to: end)
            async let sleeping = sleepMinutes(from: start, to: end)
            let value = try await HealthContextSnapshot(clipID: clip.id, intervalStart: start, intervalEnd: end,
                capturedAt: Date(), averageHeartRate: heart, averageHRVSDNN: hrv, stepCount: steps,
                activeEnergyKilocalories: energy, sleepMinutes: sleeping)
            try Task.checkCancellation()
            guard settings.healthEnabled, refreshID == id else { return }
            try context.saveHealth(value); currentSnapshot = value; errorText = nil
            status = "同时间范围的可用健康样本已关联"
            NotificationCenter.default.post(name: .recordingContextChanged, object: nil)
        } catch is CancellationError { }
        catch { if refreshID == id { errorText = "暂时无法读取健康样本；未授权或没有样本时不会补造数据。" } }
    }
    private func quantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, options: HKStatisticsOptions,
                          from start: Date, to end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        guard settings.healthEnabled else { return nil }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, result, error in
                if let error = error { continuation.resume(throwing: error); return }
                let quantity = options.contains(.cumulativeSum) ? result?.sumQuantity() : result?.averageQuantity()
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }
            health.execute(query)
        }
    }
    private func sleepMinutes(from start: Date, to end: Date) async throws -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        guard settings.healthEnabled else { return nil }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1000, sortDescriptors: nil) { _, result, error in
                if let error = error { continuation.resume(throwing: error); return }
                let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue])
                let samples = (result as? [HKCategorySample] ?? []).filter { asleep.contains($0.value) }
                guard !samples.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: HealthContextMath.sleepMinutes(intervals: samples.map { ($0.startDate, $0.endDate) }, from: start, to: end))
            }
            health.execute(query)
        }
    }
}
