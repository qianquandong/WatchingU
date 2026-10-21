import Foundation
#if DAYTAPE_HEALTHKIT
import HealthKit
#endif

/// A sleep sample is evidence, not a live sleep-onset alarm. Health data never enters upload payloads.
@MainActor
final class SleepMonitor {
    var onEvidence: ((Date) -> Void)?
    var onError: ((Error) -> Void)?
    #if DAYTAPE_HEALTHKIT
    private let health = HKHealthStore()
    private let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private var observer: HKObserverQuery?
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    func requestAccess() async throws {
        guard available else { throw CloudArchiveError.invalidResponse }
        try await health.requestAuthorization(toShare: [], read: [sleep])
        start()
    }
    func start() {
        guard available, observer == nil else { return }
        let query = HKObserverQuery(sampleType: sleep, predicate: nil) { [weak self] _, completion, error in
            Task { @MainActor in
                defer { completion() }
                guard let self = self else { return }
                if let error = error { self.onError?(error); return }
                do { if let end = try await self.latestSleep() { self.onEvidence?(end) } }
                catch { self.onError?(error) }
            }
        }
        observer = query; health.execute(query)
        health.enableBackgroundDelivery(for: sleep, frequency: .immediate) { [weak self] success, error in
            if !success, let error = error { Task { @MainActor in self?.onError?(error) } }
        }
    }
    func stop() {
        if let observer = observer { health.stop(observer); self.observer = nil }
        health.disableBackgroundDelivery(for: sleep) { _,_ in }
    }
    func latestSleep() async throws -> Date? {
        guard available else { return nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Date?, Error>) in
            let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-36 * 3600), end: Date(), options: .strictEndDate)
            let query = HKSampleQuery(sampleType: sleep, predicate: predicate, limit: 500,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _,samples,error in
                if let error = error { continuation.resume(throwing: error); return }
                let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                  HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                  HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                  HKCategoryValueSleepAnalysis.asleepREM.rawValue])
                let end = (samples as? [HKCategorySample])?.filter {
                    asleep.contains($0.value) && $0.endDate > $0.startDate &&
                    ($0.metadata?[HKMetadataKeyWasUserEntered] as? Bool != true)
                }.map(\.endDate).max()
                continuation.resume(returning: end)
            }
            health.execute(query)
        }
    }
    #else
    var available: Bool { false }
    func requestAccess() async throws { throw CloudArchiveError.setupRequired }
    func start() {}
    func stop() {}
    func latestSleep() async throws -> Date? { nil }
    #endif
}
