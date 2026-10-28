// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let uiOnlyShared = ["Connectivity.swift", "DailyNotifications.swift"]
let storageSources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Shared").path)
    .filter { $0.hasSuffix(".swift") && !uiOnlyShared.contains($0) }.sorted()
let testSources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Tests").path)
    .filter { $0.hasSuffix(".swift") }.sorted()
let package = Package(
    name: "DayTapeStorage",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "ClipStorage", targets: ["ClipStorage"])],
    targets: [
        .target(name: "RecorderRules", path: "Shared", sources: ["RecorderRules.c"], publicHeadersPath: "."),
        .target(name: "ClipStorage", dependencies: ["RecorderRules"], path: "Shared",
                exclude: uiOnlyShared + ["RecorderRules.c", "RecorderRules.h", "PrivacyInfo.xcprivacy"], sources: storageSources),
        .testTarget(name: "ClipStorageTests", dependencies: ["ClipStorage"], path: "Tests", exclude: ["RulesTests.c"], sources: testSources)
    ])
