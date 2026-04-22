// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObjectModeV2ForegroundMaskedVideoTranscoder.swift
// Aether3D
//
// Transcodes a recorded MOV into a new MOV where the background is blacked out
// on every frame via VNGenerateForegroundInstanceMaskRequest (iOS 17+).
// The output MOV has identical resolution, timebase, and orientation to the
// source. The server-side pipeline (extract_frames → curate → slam3r → sparse2dgs
// → matcha) processes the masked video with no changes: black pixels are
// feature-less, so reconstruction implicitly focuses on the foreground subject.
//
// This mirrors Polycam's "Object Masking" behavior but runs entirely on device
// using Apple's Vision framework — no external models, no additional downloads,
// hardware-accelerated on the Neural Engine.
//

import Foundation

#if canImport(AVFoundation) && canImport(CoreImage) && canImport(Vision) && canImport(UIKit)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Vision
import UIKit
import ImageIO

@available(iOS 17.0, *)
final class ObjectModeV2ForegroundMaskedVideoTranscoder {
    enum TranscodeError: Error {
        case sourceUnreadable
        case writerUnavailable
        case sessionFailed(String)
    }

    struct Summary {
        let sourceFrameCount: Int
        let maskedFrameCount: Int
        let fallbackBlackFrameCount: Int
        let elapsedSeconds: Double
        let outputBytes: Int64
    }

    private let ciContext: CIContext

    init() {
        // Metal-backed CIContext runs compositing on the GPU — keeps the
        // Neural Engine free for Vision segmentation work.
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        } else {
            self.ciContext = CIContext()
        }
    }

    func transcode(
        sourceURL: URL,
        destinationURL: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> Summary {
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw TranscodeError.sourceUnreadable
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw TranscodeError.sourceUnreadable
        }
        reader.add(readerOutput)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)

        let targetBitrate = max(Int(estimatedDataRate), 2_000_000)
        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(nominalFPS > 0 ? nominalFPS : 30)),
        ]
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw TranscodeError.writerUnavailable
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw TranscodeError.sessionFailed("reader.startReading: \(String(describing: reader.error))")
        }
        guard writer.startWriting() else {
            throw TranscodeError.sessionFailed("writer.startWriting: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let startTime = CFAbsoluteTimeGetCurrent()
        var sourceCount = 0
        var maskedCount = 0
        var blackFallbackCount = 0
        let totalSeconds = max(0.001, duration.seconds)

        // Reuse a single Vision request per frame (it owns its own internal state).
        // Creating a fresh one per frame keeps the implementation thread-safe and
        // avoids accidental result reuse across frames.

        let queue = DispatchQueue(label: "aether3d.mask.transcode", qos: .userInitiated)

        // Drive everything via the writer's readiness callback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var finished = false
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard !finished else { return }
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        if !finished {
                            finished = true
                            writerInput.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                    guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        continue
                    }
                    sourceCount += 1
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let maskedBuffer = self.applyForegroundMask(to: sourceBuffer, width: width, height: height)
                    if let buffer = maskedBuffer.pixelBuffer {
                        if maskedBuffer.hadForeground {
                            maskedCount += 1
                        } else {
                            blackFallbackCount += 1
                        }
                        _ = adaptor.append(buffer, withPresentationTime: pts)
                    }
                    if sourceCount & 7 == 0 {
                        let progress = min(1.0, pts.seconds / totalSeconds)
                        DispatchQueue.main.async { onProgress(progress) }
                    }
                }
            }
        }

        // Flush
        await writer.finishWriting()
        if writer.status == .failed {
            throw TranscodeError.sessionFailed("writer finished with error: \(String(describing: writer.error))")
        }

        let outputSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
        return Summary(
            sourceFrameCount: sourceCount,
            maskedFrameCount: maskedCount,
            fallbackBlackFrameCount: blackFallbackCount,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime,
            outputBytes: outputSize
        )
    }

    private struct MaskedFrame {
        let pixelBuffer: CVPixelBuffer?
        let hadForeground: Bool
    }

    private func applyForegroundMask(
        to source: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> MaskedFrame {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }
        guard let observation = request.results?.first else {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }

        // Pull the soft mask at source resolution. `generateScaledMaskForImage`
        // returns a single-channel Float32 buffer in [0,1] with the same extent
        // as the source. We then composite: result = source * mask + black * (1-mask).
        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }

        let sourceCI = CIImage(cvPixelBuffer: source)
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
            .clampedToExtent()
            .cropped(to: sourceCI.extent)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: sourceCI.extent)

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }
        blendFilter.setValue(sourceCI, forKey: kCIInputImageKey)
        blendFilter.setValue(black, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let blended = blendFilter.outputImage else {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }

        var outputBuffer: CVPixelBuffer?
        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, pixelBufferAttrs as CFDictionary, &outputBuffer)
        guard status == kCVReturnSuccess, let target = outputBuffer else {
            return MaskedFrame(pixelBuffer: makeBlackBuffer(width: width, height: height), hadForeground: false)
        }
        ciContext.render(blended, to: target)
        return MaskedFrame(pixelBuffer: target, hadForeground: true)
    }

    private func makeBlackBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let out = buffer else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(out) * height)
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }
}

#endif
