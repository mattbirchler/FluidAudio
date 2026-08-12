@preconcurrency import AVFoundation
import Foundation
import OSLog
import os

public struct StreamingAudioSourceFactory {
    private let logger = AppLogger(category: "StreamingAudioSourceFactory")

    public init() {}

    public func makeDiskBackedSource(
        from url: URL,
        targetSampleRate: Int
    ) throws -> (source: DiskBackedAudioSampleSource, loadDuration: TimeInterval) {
        do {
            let startTime = Date()

            let audioFile = try AVAudioFile(forReading: url)
            let inputFormat = audioFile.processingFormat
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            )!

            let tempURL = try makeTemporaryURL()
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw StreamingAudioError.processingFailed("Failed to create temporary audio buffer at \(tempURL.path)")
            }

            let handle = try FileHandle(forWritingTo: tempURL)
            defer {
                try? handle.close()
            }

            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw StreamingAudioError.processingFailed(
                    "Unsupported audio format \(inputFormat); failed to create converter")
            }

            logger.debug(
                "Streaming conversion \(inputFormat.sampleRate)Hz×\(inputFormat.channelCount)ch → \(targetFormat.sampleRate)Hz×\(targetFormat.channelCount)ch"
            )

            let totalSamples: Int
            do {
                totalSamples = try streamConvert(
                    audioFile: audioFile,
                    converter: converter,
                    handle: handle
                )
            } catch {
                logger.error("Streaming conversion failed before file mapping: \(error.localizedDescription)")
                throw error
            }

            try handle.synchronize()
            try handle.close()

            let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            if let fileSize = attributes[.size] as? NSNumber {
                logger.debug("Streaming audio temp file size=\(fileSize.intValue) bytes")
            }
            logger.debug("Streaming audio total samples=\(totalSamples)")

            let mappedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
            let source = DiskBackedAudioSampleSource(mappedData: mappedData, fileURL: tempURL)

            if source.sampleCount != totalSamples {
                logger.warning(
                    "Mapped sample count mismatch (reported=\(source.sampleCount), tracked=\(totalSamples)); continuing"
                )
            }

            let duration = Date().timeIntervalSince(startTime)
            return (source, duration)
        } catch let streamingError as StreamingAudioError {
            throw streamingError
        } catch {
            logger.error("Streaming audio source creation failed: \(error.localizedDescription)")
            throw StreamingAudioError.processingFailed(
                "Streaming audio source creation failed: \(error.localizedDescription)"
            )
        }
    }

    private func makeTemporaryURL() throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        return tempDirectory.appendingPathComponent("fluidaudio-streaming-\(identifier).raw")
    }

    private func streamConvert(
        audioFile: AVAudioFile,
        converter: AVAudioConverter,
        handle: FileHandle
    ) throws -> Int {
        let inputFormat = audioFile.processingFormat
        let targetFormat = converter.outputFormat

        let inputCapacity: AVAudioFrameCount = 16_384
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputCapacity
            )
        else {
            throw StreamingAudioError.failedToAllocateBuffer("Input", requestedFrames: Int(inputCapacity))
        }

        let estimatedOutputFrames = AVAudioFrameCount(
            (Double(inputCapacity) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
        )
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(1024, estimatedOutputFrames)
            )
        else {
            throw StreamingAudioError.failedToAllocateBuffer("Output", requestedFrames: Int(estimatedOutputFrames))
        }

        var totalSamples = 0
        let inputComplete = OSAllocatedUnfairLock(initialState: false)
        let readError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        // Frames left unread when a read fails, so a genuinely truncated file
        // can be told apart from a reported length that overshoots the audio.
        let unreadFrames = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

        // Buffer is only accessed synchronously by AVAudioConverter's input block callback
        nonisolated(unsafe) let capturedInputBuffer = inputBuffer

        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if inputComplete.withLock({ $0 }) {
                status.pointee = .endOfStream
                return nil
            }

            do {
                let remainingFrames = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                let framesToRead = min(inputCapacity, remainingFrames)
                if framesToRead > 0 {
                    try audioFile.read(into: capturedInputBuffer, frameCount: framesToRead)
                } else {
                    capturedInputBuffer.frameLength = 0
                }
            } catch {
                readError.withLock { $0 = error }
                unreadFrames.withLock { $0 = audioFile.length - audioFile.framePosition }
                capturedInputBuffer.frameLength = 0
            }

            guard capturedInputBuffer.frameLength > 0 else {
                inputComplete.withLock { $0 = true }
                status.pointee = .endOfStream
                return nil
            }

            status.pointee = .haveData
            return capturedInputBuffer
        }

        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError,
                withInputFrom: inputBlock
            )

            if let conversionError {
                throw StreamingAudioError.processingFailed(
                    "Audio conversion failed: \(conversionError.localizedDescription)"
                )
            }

            if let error = readError.withLock({ $0 }) {
                // An MP3 written without a Xing/LAME header has no exact sample
                // count, so AVAudioFile reports packets × frames-per-packet.
                // That overshoots the decodable audio by up to a packet, and the
                // read of that phantom tail fails. Dropping a few milliseconds of
                // encoder padding beats failing the file, so only a shortfall too
                // large to be padding is treated as a real read failure.
                let shortfall = unreadFrames.withLock { $0 }
                let toleratedShortfall = AVAudioFramePosition(inputFormat.sampleRate)
                guard totalSamples > 0, shortfall <= toleratedShortfall else {
                    throw StreamingAudioError.processingFailed(
                        "Failed while reading audio: \(error.localizedDescription)"
                    )
                }

                // Reading stopped here, so the stream is already ending and this
                // will not fire again.
                readError.withLock { $0 = nil }
                logger.warning(
                    "Audio ended \(shortfall) frames before its reported length; treating the unreadable tail as end of stream"
                )
            }

            let producedFrames = Int(outputBuffer.frameLength)
            if producedFrames > 0 {
                guard let channelData = outputBuffer.floatChannelData?.pointee else {
                    throw StreamingAudioError.processingFailed("Missing channel data during conversion")
                }
                let byteCount = producedFrames * MemoryLayout<Float>.stride
                let baseAddress = UnsafeRawPointer(channelData)
                let data = Data(bytes: baseAddress, count: byteCount)
                try handle.write(contentsOf: data)
                totalSamples += producedFrames
            }

            if status == .endOfStream {
                break
            }
        }

        return totalSamples
    }
}

public enum StreamingAudioError: Error, LocalizedError {
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

extension StreamingAudioError {
    fileprivate static func failedToAllocateBuffer(_ name: String, requestedFrames: Int) -> StreamingAudioError {
        .processingFailed("Failed to allocate \(name.lowercased()) buffer (\(requestedFrames) frames)")
    }
}
