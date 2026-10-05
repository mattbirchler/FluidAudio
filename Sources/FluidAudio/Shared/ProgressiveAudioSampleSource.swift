@preconcurrency import AVFoundation
import Foundation

/// Raised when a file holds more audio than its header promised, so the buffer
/// reserved for it is too small. Callers fall back to decoding the whole file
/// before transcribing, which needs no estimate.
enum ProgressiveAudioError: Error {
    case capacityExceeded(capacity: Int)
    case released
}

/// An audio sample source that decodes in the background while its samples
/// are already being read.
///
/// Decoding a long file to 16 kHz mono takes seconds, and chunked transcription
/// only ever needs the samples up to the end of the window it is about to
/// start. Decoding in the background lets the first window start at once
/// instead of after the whole file has been converted.
///
/// Samples are written through a memory-mapped temporary file, so memory use
/// stays roughly constant however long the file is, as with
/// `DiskBackedAudioSampleSource`. The mapping is sized from the file header's
/// length plus slack; if the audio runs past it, decoding fails with
/// `ProgressiveAudioError.capacityExceeded`.
///
/// Readers must only ask for samples they know exist: either a range that
/// `finalCountUnlessBeyond` has confirmed, or anything once decoding is done.
public final class ProgressiveAudioSampleSource: StreamingAudioSampleSource, @unchecked Sendable {
    /// Sample count estimated from the file header. The true count is known
    /// only once decoding finishes.
    public let estimatedSampleCount: Int

    private let base: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mappedBytes: Int

    // Everything below is guarded by `state`.
    private let state = NSCondition()
    private var decoded = 0
    private var finished = false
    private var failure: Error?
    private var stopRequested = false
    private var released = false
    private var waiters: [Int: Waiter] = [:]
    private var cancelledWaiters: Set<Int> = []
    private var nextWaiterID = 0

    private struct Waiter {
        let threshold: Int
        let continuation: CheckedContinuation<Int?, Error>
    }

    /// Opens the file and starts decoding it straight away.
    /// - Parameters:
    ///   - url: the audio file to decode.
    ///   - targetSampleRate: sample rate of the mono Float32 output.
    ///   - capacityOverride: buffer size in samples, for tests that need to
    ///     exercise a header that understates the audio.
    init(url: URL, targetSampleRate: Int, capacityOverride: Int? = nil) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let ratio = Double(targetSampleRate) / inputFormat.sampleRate
        let estimate = Int((Double(audioFile.length) * ratio).rounded(.up))
        estimatedSampleCount = estimate

        // Resampling can add a few samples beyond the estimate. The slack is
        // far larger than that so a slightly wrong header still fits.
        capacity = max(1, capacityOverride ?? (estimate + estimate / 8 + targetSampleRate * 30))
        mappedBytes = capacity * MemoryLayout<Float>.stride

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw StreamingAudioError.processingFailed(
                "Unsupported audio format \(inputFormat); failed to create converter")
        }

        base = try Self.mapTemporaryFile(bytes: mappedBytes)

        // Decode on the concurrency pool, where the decode-first path also
        // runs, so both paths do the work in the same kind of context.
        Task.detached(priority: .userInitiated) { [self] in
            do {
                _ = try StreamingAudioSourceFactory.streamConvert(
                    audioFile: audioFile,
                    converter: converter
                ) { samples, count in
                    try self.append(samples, count: count)
                }
                self.finish(with: nil)
            } catch {
                self.finish(with: error)
            }
        }
    }

    /// Opens the file and starts decoding it straight away.
    public convenience init(url: URL, targetSampleRate: Int) throws {
        try self.init(url: url, targetSampleRate: targetSampleRate, capacityOverride: nil)
    }

    deinit {
        cleanup()
    }

    /// Creates a sparse file of `bytes` and maps it shared, so written samples
    /// are backed by disk rather than by anonymous memory.
    ///
    /// The file is unlinked as soon as it is mapped. The mapping keeps its
    /// storage alive, and the space is returned when the mapping goes away,
    /// including when the process is killed mid-transcription.
    private static func mapTemporaryFile(bytes: Int) throws -> UnsafeMutablePointer<Float> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidaudio-progressive-\(UUID().uuidString).raw")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw StreamingAudioError.processingFailed("Failed to create temporary audio buffer at \(url.path)")
        }
        defer {
            close(descriptor)
            unlink(url.path)
        }

        guard ftruncate(descriptor, off_t(bytes)) == 0,
            let raw = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
            raw != MAP_FAILED
        else {
            throw StreamingAudioError.processingFailed("Failed to map temporary audio buffer (\(bytes) bytes)")
        }
        return raw.bindMemory(to: Float.self, capacity: bytes / MemoryLayout<Float>.stride)
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        state.lock()
        defer { state.unlock() }
        return try body()
    }

    // MARK: - Decoding

    /// Copies one converted block into the buffer, then publishes the new
    /// count. Readers only touch samples below the published count, so a read
    /// and this write never overlap.
    private func append(_ samples: UnsafePointer<Float>, count: Int) throws {
        let written = try withState { () -> Int in
            if stopRequested { throw CancellationError() }
            return decoded
        }
        guard written + count <= capacity else {
            throw ProgressiveAudioError.capacityExceeded(capacity: capacity)
        }
        (base + written).update(from: samples, count: count)

        let ready = withState { () -> [Waiter] in
            decoded = written + count
            let satisfied = waiters.filter { decoded > $0.value.threshold }
            for id in satisfied.keys { waiters.removeValue(forKey: id) }
            return Array(satisfied.values)
        }
        for waiter in ready {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func finish(with error: Error?) {
        let (pending, total) = withState { () -> ([Waiter], Int) in
            failure = error
            finished = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            state.broadcast()
            return (pending, decoded)
        }
        for waiter in pending {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume(returning: total > waiter.threshold ? nil : total)
            }
        }
    }

    // MARK: - Reading

    /// Waits, without blocking a thread, until it is known whether the audio
    /// extends past `sample`.
    /// - Returns: nil once more than `sample` samples have been decoded, or the
    ///   final sample count if the audio ended at or before that point.
    public func finalCountUnlessBeyond(_ sample: Int) async throws -> Int? {
        let id = withState { () -> Int in
            nextWaiterID += 1
            return nextWaiterID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int?, Error>) in
                let outcome = withState { () -> Result<Int?, Error>? in
                    if cancelledWaiters.remove(id) != nil { return .failure(CancellationError()) }
                    if let failure { return .failure(failure) }
                    if decoded > sample { return .success(nil) }
                    if finished { return .success(decoded) }
                    waiters[id] = Waiter(threshold: sample, continuation: continuation)
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let waiter = withState { () -> Waiter? in
                if let waiter = waiters.removeValue(forKey: id) { return waiter }
                cancelledWaiters.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The true sample count, available once decoding has finished. Throws if
    /// decoding failed.
    public func finalSampleCount() async throws -> Int {
        // Nothing is ever beyond Int.max, so this only returns at the end.
        try await finalCountUnlessBeyond(Int.max) ?? 0
    }

    /// The true sample count. Blocks the calling thread until decoding has
    /// finished, so prefer `finalSampleCount()` from async code.
    public var sampleCount: Int {
        withState {
            while !finished { state.wait() }
            return decoded
        }
    }

    public func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard count > 0 else { return }
        let start = max(0, offset)
        let (available, failure, released) = withState { (decoded, self.failure, self.released) }
        if released { throw ProgressiveAudioError.released }
        // A failed decode leaves the samples before the failure intact. Only a
        // read that needs audio the decoder never produced has to fail.
        if let failure, start + count > available { throw failure }
        guard start < available else { return }
        destination.update(from: base + start, count: min(available - start, count))
    }

    /// Stops decoding if it is still running, then releases the buffer and
    /// the disk space behind it. Safe to call more than once. No reads may be
    /// in flight.
    public func cleanup() {
        let shouldRelease = withState { () -> Bool in
            stopRequested = true
            // The decoder notices the stop request on its next block.
            // Wait for it so the mapping is never released under a write.
            while !finished { state.wait() }
            if released { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        munmap(base, mappedBytes)
    }
}
