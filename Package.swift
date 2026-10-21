// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DayTapeStorage",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "ClipStorage", targets: ["ClipStorage"])],
    targets: [
        .target(name: "RecorderRules", path: "Shared", sources: ["RecorderRules.c"], publicHeadersPath: "."),
        .target(name: "ClipStorage", dependencies: ["RecorderRules"], path: "Shared", sources: ["Models.swift", "ArchiveModels.swift", "DailySchedule.swift", "BackupClock.swift", "DayArchive.swift", "ClipStore.swift"]),
        .testTarget(name: "ClipStorageTests", dependencies: ["ClipStorage"], path: "Tests", sources: ["StorageTests.swift", "ScheduleTests.swift", "DayArchiveTests.swift", "BackupClockTests.swift"])
    ])
