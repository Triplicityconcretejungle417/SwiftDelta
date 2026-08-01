//===--- OperationProgress.swift - SwiftDelta ------------------------------------------===//
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

/// A bounded unit of progress for work whose size is known.
///
/// The textual progress stream remains the durable human-readable record.
/// Measurements are a separate presentation hint and never affect results.
public struct OperationProgressMeasurement: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let label: String

    public init(completed: Int, total: Int, label: String) {
        self.total = max(1, total)
        self.completed = min(max(0, completed), self.total)
        self.label = label
    }
}

/// Emits durable, line-oriented progress without sharing the report stream.
///
/// Callers choose the destination. The terminal application turns progress
/// into bounded UI events, while library clients and tests may provide their
/// own sink or use `silent`.
public final class OperationProgress: @unchecked Sendable {
    public typealias Sink = @Sendable (String) -> Void
    public typealias MeasurementSink =
        @Sendable (OperationProgressMeasurement?) -> Void

    private let quiet: Bool
    private let sink: Sink
    private let measurementSink: MeasurementSink
    private let clock: any OperationProgressClock
    private let startedAt: Date
    private let heartbeatDelay: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let lock = NSLock()
    private var activePhases: [UUID] = []

    public init(
        quiet: Bool = false,
        heartbeatDelay: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 60,
        measurementSink: @escaping MeasurementSink = { _ in },
        sink: @escaping Sink
    ) {
        let clock = SystemOperationProgressClock()
        self.quiet = quiet
        self.sink = sink
        self.measurementSink = measurementSink
        self.clock = clock
        self.startedAt = clock.now
        self.heartbeatDelay = heartbeatDelay
        self.heartbeatInterval = heartbeatInterval
    }

    init(
        quiet: Bool = false,
        heartbeatDelay: TimeInterval = 30,
        heartbeatInterval: TimeInterval = 60,
        clock: any OperationProgressClock,
        measurementSink: @escaping MeasurementSink = { _ in },
        sink: @escaping Sink
    ) {
        self.quiet = quiet
        self.sink = sink
        self.measurementSink = measurementSink
        self.clock = clock
        self.startedAt = clock.now
        self.heartbeatDelay = heartbeatDelay
        self.heartbeatInterval = heartbeatInterval
    }

    public static var silent: OperationProgress {
        OperationProgress(quiet: true, sink: { _ in })
    }

    public func message(_ text: String) {
        emit(text)
    }

    /// Updates presentation with a real completed/total measurement.
    ///
    /// Callers should use this only when the total is known. Other work
    /// remains indeterminate instead of estimating a percentage.
    public func measure(completed: Int, total: Int, label: String) {
        guard !quiet else { return }
        measurementSink(
            OperationProgressMeasurement(
                completed: completed,
                total: total,
                label: label
            )
        )
    }

    @discardableResult
    public func phase<T>(
        _ startedMessage: String,
        completedMessage: String? = nil,
        operation: () throws -> T
    ) rethrows -> T {
        let phaseID = UUID()
        let phaseStart = clock.now
        lock.withLock {
            activePhases.append(phaseID)
        }
        if !quiet {
            measurementSink(nil)
        }
        emit(startedMessage)
        let heartbeat = makeHeartbeat(
            phaseID: phaseID,
            message: startedMessage,
            phaseStart: phaseStart
        )
        do {
            let result = try operation()
            heartbeat?.cancel()
            finish(phaseID)
            let completion = completedMessage ?? completedText(for: startedMessage)
            emit("\(completion) — \(duration(clock.now.timeIntervalSince(phaseStart)))")
            return result
        } catch {
            heartbeat?.cancel()
            finish(phaseID)
            emit(
                "Failed \(lowercasedInitial(startedMessage)) — "
                    + "\(duration(clock.now.timeIntervalSince(phaseStart))): "
                    + error.localizedDescription
            )
            throw error
        }
    }

    private func makeHeartbeat(
        phaseID: UUID,
        message: String,
        phaseStart: Date
    ) -> (any OperationProgressHeartbeat)? {
        guard !quiet, heartbeatDelay > 0, heartbeatInterval > 0 else {
            return nil
        }
        return clock.schedule(
            after: heartbeatDelay,
            repeating: heartbeatInterval
        ) { [weak self] in
            guard let self else { return }
            let isMostSpecific = self.lock.withLock {
                self.activePhases.last == phaseID
            }
            guard isMostSpecific else { return }
            let elapsed = self.clock.now.timeIntervalSince(phaseStart)
            self.emit(
                "Still \(self.lowercasedInitial(message)) — "
                    + "\(self.duration(elapsed)) elapsed"
            )
        }
    }

    private func emit(_ message: String) {
        guard !quiet else { return }
        sink("[\(timestamp(clock.now.timeIntervalSince(startedAt)))] \(message)\n")
    }

    private func finish(_ phaseID: UUID) {
        lock.withLock {
            activePhases.removeAll { $0 == phaseID }
        }
    }

    private func completedText(for started: String) -> String {
        let words = started.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first else { return "Completed" }
        let remainder = words.count > 1 ? " \(words[1])" : ""
        let completedVerb = [
            "Applying": "Applied",
            "Building": "Built",
            "Capturing": "Captured",
            "Collecting": "Collected",
            "Comparing": "Compared",
            "Discovering": "Discovered",
            "Extracting": "Extracted",
            "Generating": "Generated",
            "Reading": "Read",
            "Resolving": "Resolved",
            "Selecting": "Selected",
            "Verifying": "Verified",
        ][verb] ?? "Completed"
        return completedVerb + remainder
    }

    private func lowercasedInitial(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }

    private func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

protocol OperationProgressHeartbeat: Sendable {
    func cancel()
}

protocol OperationProgressClock: Sendable {
    var now: Date { get }

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any OperationProgressHeartbeat
}

private struct SystemOperationProgressClock: OperationProgressClock {
    var now: Date {
        Date()
    }

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any OperationProgressHeartbeat {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "org.swiftdelta.progress-heartbeat")
        )
        timer.schedule(deadline: .now() + delay, repeating: interval)
        timer.setEventHandler(handler: action)
        timer.resume()
        return DispatchOperationProgressHeartbeat(timer: timer)
    }
}

private final class DispatchOperationProgressHeartbeat:
    OperationProgressHeartbeat,
    @unchecked Sendable
{
    private let timer: DispatchSourceTimer

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        timer.cancel()
    }
}
