import AVFoundation
import XCTest

@testable import FluidAudio

final class ProgressiveAudioSampleSourceTests: XCTestCase {
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("progressive-fixture-\(UUID().uuidString).wav")
        // Stereo 44.1 kHz so the source has to both downmix and resample.
        try Self.writeFixture(to: fixtureURL, seconds: 90, sampleRate: 44_100, channels: 2)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureURL)
    }

    /// A deterministic, non-periodic signal, so a misplaced block would show.
    private static func writeFixture(to url: URL, seconds: Int, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let blockFrames = AVAudioFrameCount(sampleRate)
        var generator: UInt64 = 0x9E37_79B9_7F4A_7C15
        for second in 0..<seconds {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)!
            buffer.frameLength = blockFrames
            for channel in 0..<Int(channels) {
                let data = buffer.floatChannelData![channel]
                for frame in 0..<Int(blockFrames) {
                    generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let noise = Float(generator >> 40) / Float(1 << 24) - 0.5
                    let tone = sinf(Float(second * Int(blockFrames) + frame) * 0.01 * Float(channel + 1))
                    data[frame] = 0.4 * tone + 0.2 * noise
                }
            }
            try file.write(from: buffer)
        }
    }

    private func readAll(_ source: StreamingAudioSampleSource, count: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        try samples.withUnsafeMutableBufferPointer { pointer in
            try source.copySamples(into: pointer.baseAddress!, offset: 0, count: count)
        }
        return samples
    }

    func testSamplesMatchTheDecodeFirstSource() async throws {
        let (reference, _) = try StreamingAudioSourceFactory().makeDiskBackedSource(
            from: fixtureURL, targetSampleRate: 16_000)
        defer { reference.cleanup() }

        let progressive = try ProgressiveAudioSampleSource(url: fixtureURL, targetSampleRate: 16_000)
        defer { progressive.cleanup() }

        let total = try await progressive.finalSampleCount()
        XCTAssertEqual(total, reference.sampleCount)
        XCTAssertEqual(progressive.sampleCount, reference.sampleCount)
        // 90 s of audio at 16 kHz, give or take the resampler's edges.
        XCTAssertEqual(Double(total), 90 * 16_000, accuracy: 16_000)
        XCTAssertEqual(Double(progressive.estimatedSampleCount), Double(total), accuracy: 1_600)

        let expected = try readAll(reference, count: total)
        let actual = try readAll(progressive, count: total)
        XCTAssertEqual(actual, expected)
    }

    func testReportsWhetherAudioExtendsPastASample() async throws {
        let progressive = try ProgressiveAudioSampleSource(url: fixtureURL, targetSampleRate: 16_000)
        defer { progressive.cleanup() }

        // Well inside the file: the answer arrives while decoding is under way.
        let early = try await progressive.finalCountUnlessBeyond(16_000)
        XCTAssertNil(early)

        // A window that has been confirmed can be read straight away.
        var window = [Float](repeating: 0, count: 16_000)
        try window.withUnsafeMutableBufferPointer { pointer in
            try progressive.copySamples(into: pointer.baseAddress!, offset: 0, count: 16_000)
        }
        XCTAssertTrue(window.contains { $0 != 0 })

        let total = try await progressive.finalSampleCount()
        // The last sample index is not "beyond"; one before it is.
        let atEnd = try await progressive.finalCountUnlessBeyond(total)
        XCTAssertEqual(atEnd, total)
        let pastEnd = try await progressive.finalCountUnlessBeyond(total + 5_000)
        XCTAssertEqual(pastEnd, total)
        let justInside = try await progressive.finalCountUnlessBeyond(total - 1)
        XCTAssertNil(justInside)
    }

    func testFailsWhenAudioOutgrowsTheBuffer() async throws {
        // Room for one second of a 90 second file, as if the header had lied.
        let progressive = try ProgressiveAudioSampleSource(
            url: fixtureURL, targetSampleRate: 16_000, capacityOverride: 16_000)
        defer { progressive.cleanup() }

        do {
            _ = try await progressive.finalSampleCount()
            XCTFail("Expected the decode to fail")
        } catch ProgressiveAudioError.capacityExceeded(let capacity) {
            XCTAssertEqual(capacity, 16_000)
        }

        // Samples decoded before the failure are still readable...
        var head = [Float](repeating: 0, count: 1_000)
        try head.withUnsafeMutableBufferPointer { pointer in
            try progressive.copySamples(into: pointer.baseAddress!, offset: 0, count: 1_000)
        }
        // ...and a read that needs audio the decoder never produced fails.
        var tail = [Float](repeating: 0, count: 1_000)
        XCTAssertThrowsError(
            try tail.withUnsafeMutableBufferPointer { pointer in
                try progressive.copySamples(into: pointer.baseAddress!, offset: 400_000, count: 1_000)
            })
    }

    func testCancellingAWaitReturnsPromptly() async throws {
        let progressive = try ProgressiveAudioSampleSource(url: fixtureURL, targetSampleRate: 16_000)
        defer { progressive.cleanup() }
        let total = try await progressive.finalSampleCount()

        // Decoding is over, so a wait that cannot be satisfied resolves at
        // once. A cancelled one must throw instead of hanging.
        let waiter = Task { try await progressive.finalCountUnlessBeyond(total + 1) }
        let value = try await waiter.value
        XCTAssertEqual(value, total)

        let cancelled = Task { () -> Int? in
            try Task.checkCancellation()
            return try await progressive.finalCountUnlessBeyond(Int.max - 1)
        }
        cancelled.cancel()
        _ = try? await cancelled.value
    }

    func testCleanupStopsADecodeInProgressAndLeavesNoFile() async throws {
        let longURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("progressive-long-\(UUID().uuidString).wav")
        try Self.writeFixture(to: longURL, seconds: 600, sampleRate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: longURL) }

        let before = try Self.temporaryBufferFiles()
        let progressive = try ProgressiveAudioSampleSource(url: longURL, targetSampleRate: 16_000)
        // The backing file is unlinked as soon as it is mapped, so nothing is
        // left behind even if the process dies mid-decode.
        XCTAssertTrue(try Self.temporaryBufferFiles().subtracting(before).isEmpty)

        // Wait for decoding to start, then pull the plug partway through.
        _ = try await progressive.finalCountUnlessBeyond(16_000)
        progressive.cleanup()
        progressive.cleanup()  // idempotent

        XCTAssertTrue(try Self.temporaryBufferFiles().subtracting(before).isEmpty)
        XCTAssertLessThan(progressive.sampleCount, 600 * 16_000)

        var scratch = [Float](repeating: 0, count: 10)
        XCTAssertThrowsError(
            try scratch.withUnsafeMutableBufferPointer { pointer in
                try progressive.copySamples(into: pointer.baseAddress!, offset: 0, count: 10)
            })
    }

    func testMissingFileThrowsAtInit() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try ProgressiveAudioSampleSource(url: missing, targetSampleRate: 16_000))
    }

    private static func temporaryBufferFiles() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        return Set(names.filter { $0.hasPrefix("fluidaudio-progressive-") })
    }
}
