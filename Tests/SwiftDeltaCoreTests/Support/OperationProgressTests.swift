//===--- OperationProgressTests.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Foundation
@testable import SwiftDeltaCore
import XCTest

final class OperationProgressTests: XCTestCase {
    func testProgressIsConciseLineOrientedAndSeparateFromReportData() throws {
        let capture = ProgressCapture()
        let progress = OperationProgress(sink: capture.append)
        let report = Data(#"{"reportFormatVersion":"2.1"}"#.utf8)

        let value = progress.phase(
            "Extracting FictionalSDK from Xcode 27.0",
            completedMessage: "Extracted FictionalSDK — 42 public symbols"
        ) {
            42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(report, Data(#"{"reportFormatVersion":"2.1"}"#.utf8))
        let lines = capture.text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Extracting FictionalSDK"))
        XCTAssertTrue(lines[1].contains("Extracted FictionalSDK — 42 public symbols"))
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("[00:00]") })
    }

    func testQuietProgressSuppressesAllMessages() {
        let capture = ProgressCapture()
        let measurements = ProgressMeasurementCapture()
        let progress = OperationProgress(
            quiet: true,
            measurementSink: measurements.append,
            sink: capture.append
        )

        progress.message("Discovering project")
        progress.measure(completed: 1, total: 2, label: "Modules")
        _ = progress.phase("Building candidate") { true }

        XCTAssertEqual(capture.text, "")
        XCTAssertTrue(measurements.values.isEmpty)
    }

    func testMeasurementsAreBoundedAndResetAtPhaseBoundaries() {
        let measurements = ProgressMeasurementCapture()
        let progress = OperationProgress(
            measurementSink: measurements.append,
            sink: { _ in }
        )

        progress.measure(completed: -2, total: 0, label: "Modules")
        progress.phase("Extracting modules") {
            progress.measure(completed: 8, total: 4, label: "Modules")
        }

        XCTAssertEqual(
            measurements.values,
            [
                OperationProgressMeasurement(
                    completed: 0,
                    total: 1,
                    label: "Modules"
                ),
                nil,
                OperationProgressMeasurement(
                    completed: 4,
                    total: 4,
                    label: "Modules"
                ),
            ]
        )
    }

    func testLongPhaseEmitsRestrainedHeartbeat() {
        let capture = ProgressCapture()
        let progress = OperationProgress(
            heartbeatDelay: 0.01,
            heartbeatInterval: 1,
            sink: capture.append
        )

        progress.phase("Extracting FictionalSDK") {
            Thread.sleep(forTimeInterval: 0.04)
        }

        XCTAssertTrue(capture.text.contains("Still extracting FictionalSDK"))
        XCTAssertLessThanOrEqual(
            capture.text.split(whereSeparator: \.isNewline).count,
            3
        )
    }

    func testNestedPhaseSuppressesParentHeartbeatUntilChildCompletes() {
        let capture = ProgressCapture()
        let clock = ControlledProgressClock()
        let progress = OperationProgress(
            heartbeatDelay: 30,
            heartbeatInterval: 60,
            clock: clock,
            sink: capture.append
        )

        progress.phase("Collecting evidence") {
            clock.advance(by: 31)
            progress.phase("Extracting FictionalSDK") {
                clock.advance(by: 31)
            }
            clock.advance(by: 60)
        }

        let heartbeats = capture.text
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("Still ") }
            .map(String.init)
        XCTAssertEqual(heartbeats.count, 3)
        XCTAssertTrue(heartbeats[0].contains("Still collecting evidence"))
        XCTAssertTrue(heartbeats[1].contains("Still extracting FictionalSDK"))
        XCTAssertTrue(heartbeats[2].contains("Still collecting evidence"))
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage += value
        }
    }
}

private final class ProgressMeasurementCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OperationProgressMeasurement?] = []

    var values: [OperationProgressMeasurement?] {
        lock.withLock { storage }
    }

    func append(_ value: OperationProgressMeasurement?) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class ControlledProgressClock:
    OperationProgressClock,
    @unchecked Sendable
{
    private struct Scheduled {
        let id: UUID
        var next: Date
        let interval: TimeInterval
        let action: @Sendable () -> Void
        var cancelled: Bool
    }

    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    private var scheduled: [UUID: Scheduled] = [:]

    var now: Date {
        lock.withLock { current }
    }

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any OperationProgressHeartbeat {
        let id = UUID()
        lock.withLock {
            scheduled[id] = Scheduled(
                id: id,
                next: current.addingTimeInterval(delay),
                interval: interval,
                action: action,
                cancelled: false
            )
        }
        return ControlledHeartbeat { [weak self] in
            self?.lock.withLock {
                self?.scheduled[id]?.cancelled = true
            }
        }
    }

    func advance(by interval: TimeInterval) {
        let actions: [@Sendable () -> Void] = lock.withLock {
            current = current.addingTimeInterval(interval)
            var due: [@Sendable () -> Void] = []
            for id in scheduled.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard var item = scheduled[id], !item.cancelled else {
                    continue
                }
                while item.next <= current {
                    due.append(item.action)
                    item.next = item.next.addingTimeInterval(item.interval)
                }
                scheduled[id] = item
            }
            return due
        }
        actions.forEach { $0() }
    }
}

private final class ControlledHeartbeat:
    OperationProgressHeartbeat,
    @unchecked Sendable
{
    private let cancellation: @Sendable () -> Void

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}
