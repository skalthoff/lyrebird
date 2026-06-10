import AVFoundation
import AudioToolbox
import Foundation
import os

private let streamerLog = Logger(subsystem: "org.lyrebird.desktop", category: "dsp")

/// Per-track streaming bridge for the AVAudioEngine DSP path (#39):
///
///   URLSession bytes → `DSPAudioFileStreamParser` (AudioToolbox) →
///   `AVAudioConverter` decode → `AVAudioPCMBuffer` → scheduled on the
///   pipeline's `AVAudioPlayerNode`.
///
/// `AVPlayer` can't host real-time effect nodes and `MTAudioProcessingTap`
/// doesn't work over HTTP streaming, so this is the classic AudioStreamer /
/// SwiftAudioPlayer pattern that feeds a node graph from a network stream.
///
/// One streamer per track; `EngineDSPPipeline` builds a fresh one in `load`
/// and cancels the old one. All parse/decode/schedule work is confined to the
/// serial `decodeQueue`; the owner talks to it from the main actor through
/// thread-safe entry points (`start`, `seek`, `cancel`).
///
/// Memory stays flat (#39 acceptance): decoded PCM is paced against playback
/// (at most `maxScheduledAheadFrames` ahead), parsed-but-undecoded packets are
/// capped, and the URLSession task is suspended when the backlog passes the
/// high-water mark and resumed below the low-water mark — so neither the raw
/// bytes nor the decoded audio of a long track ever accumulate unboundedly.
final class DSPTrackStreamer: NSObject {
    // MARK: - Tunables

    /// Cap on decoded-and-scheduled audio waiting in the player node:
    /// ~8 seconds at the source sample rate. Generous enough to ride out
    /// network jitter, small enough (~2.7 MB of float32 stereo at 44.1 kHz)
    /// to keep memory flat.
    private var maxScheduledAheadFrames: AVAudioFramePosition {
        AVAudioFramePosition(8 * (processingFormat?.sampleRate ?? 44_100))
    }

    /// Frames per scheduled output buffer (~0.37s at 44.1 kHz).
    private let outputBufferFrameCapacity: AVAudioFrameCount = 16_384

    /// Suspend the network task when this many parsed-but-undecoded packets
    /// are queued; resume at half. Roughly 30–60s of compressed audio.
    private let packetQueueHighWater = 2_048

    // MARK: - Owner-facing callbacks (all invoked on the main queue)

    /// Fired once the source format is known and the converter is built.
    /// Carries the engine processing format the owner should wire the node
    /// graph with, plus `framesPerPacket` for seek math.
    var onFormatReady: ((AVAudioFormat) -> Void)?

    /// Fired when the last scheduled buffer of a fully-delivered stream has
    /// been *played back* — the DSP path's `AVPlayerItemDidPlayToEndTime`.
    var onPlaybackFinished: (() -> Void)?

    /// Fired when the stream dies before delivering a complete track
    /// (network failure, unparseable container, decode error).
    var onStreamError: ((String) -> Void)?

    /// Fired after a seek lands, with the *actual* stream frame the stream
    /// resumed from (packet-aligned; may differ slightly from the request,
    /// and is 0 when a ranged request fell back to the start of the track).
    var onSeekCommitted: ((AVAudioFramePosition) -> Void)?

    // MARK: - Immutable per-track inputs

    private let url: URL
    private let authHeader: String?
    private let fileTypeHint: AudioFileTypeID
    /// Duration hint from track metadata (ticks → seconds), used only for
    /// seek-frame estimation on streams without a packet table.
    private let durationHintSeconds: Double?

    private weak var playerNode: AVAudioPlayerNode?

    // MARK: - Decode-queue confined state

    private let decodeQueue = DispatchQueue(label: "org.lyrebird.desktop.dsp-decode")
    private lazy var sessionDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = decodeQueue
        return queue
    }()

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var parser: DSPAudioFileStreamParser?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var processingFormat: AVAudioFormat?
    private var sourceASBD = AudioStreamBasicDescription()
    private var isSourceLPCM = false
    private var framesPerPacket: AVAudioFramePosition = 0

    /// Parsed-but-undecoded packets, in arrival order.
    private var packetQueue: [(data: Data, description: AudioStreamPacketDescription?)] = []
    /// Raw bytes that arrived before the parser was ready get replayed
    /// through it (never happens in practice — ParseBytes consumes
    /// everything — kept nil-cost for clarity).

    /// Frames scheduled onto the node so far, in stream coordinates
    /// (starts at the seek target after a seek).
    private var scheduledFrames: AVAudioFramePosition = 0
    /// Frames the node has *played* of what we scheduled (advanced by
    /// buffer completions). Pacing = scheduledFrames - playedFrames.
    private var playedFrames: AVAudioFramePosition = 0

    /// The stream byte offset the *current* HTTP response body started at.
    private var responseStartByteOffset: Int64 = 0
    /// Bytes of the current response consumed so far (for diagnostics).
    private var receivedByteCount: Int64 = 0

    private var networkDone = false
    private var converterSawEndOfStream = false
    private var taskSuspended = false
    private var cancelled = false

    /// Owner transport hint (#1048). While the transport is paused nothing
    /// drains the decode pacing, so an open response idles until CFNetwork's
    /// request timeout kills the task — which is not a track failure. With
    /// this set, a task failure parks (`pendingReconnect`) instead of firing
    /// `onStreamError`, and unpausing re-issues a ranged request from the
    /// first byte the dead response never delivered.
    private var transportPaused = false
    /// A transfer died while `transportPaused`; `setTransportPaused(false)`
    /// reconnects.
    private var pendingReconnect = false
    /// The in-flight response is a byte-exact continuation of a previous
    /// one (reconnect after a paused-idle timeout) — its first bytes are
    /// contiguous with already-parsed data, unlike a seek's.
    private var isContinuationResponse = false

    /// Scheduling stays gated until the owner has rewired the node graph
    /// for this stream's format (`beginScheduling`). Scheduling a buffer
    /// whose format mismatches the node's output connection raises an
    /// NSException inside AVFoundation, so decoded audio must wait for the
    /// graph — packets simply queue up in the meantime.
    private var schedulingAllowed = false

    /// Bumped on every seek/cancel; stale buffer-completion callbacks and
    /// stale response handling compare against it and bail.
    private var generation: Int = 0

    /// Set while a seek's ranged request is in flight so a `200 OK`
    /// (range-unsupported) response can be detected and handled as a
    /// restart-from-zero.
    private var pendingSeekFrame: AVAudioFramePosition?

    init(
        url: URL,
        authHeader: String?,
        playerNode: AVAudioPlayerNode,
        fileTypeHint: AudioFileTypeID = 0,
        durationHintSeconds: Double? = nil
    ) {
        self.url = url
        self.authHeader = authHeader
        self.playerNode = playerNode
        self.fileTypeHint = fileTypeHint
        self.durationHintSeconds = durationHintSeconds
        super.init()
    }

    // MARK: - Owner entry points (thread-safe)

    /// Begin fetching + decoding from the start of the stream.
    func start() {
        decodeQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            do {
                let parser = try DSPAudioFileStreamParser(fileTypeHint: self.fileTypeHint)
                self.wireParser(parser)
                self.parser = parser
            } catch {
                self.failOnDecodeQueue("Unsupported audio container: \(error.localizedDescription)")
                return
            }
            self.startRequest(fromByte: 0)
        }
    }

    /// Seek to (approximately) `targetFrame` in stream coordinates. The
    /// owner must stop the player node first (dropping its scheduled
    /// buffers); the streamer flushes its own backlog, issues a ranged
    /// request, and reports the packet-aligned landing frame via
    /// `onSeekCommitted` before new buffers start arriving.
    func seek(toFrame targetFrame: AVAudioFramePosition) {
        decodeQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            guard let parser = self.parser, parser.isReadyToProducePackets, self.converter != nil else {
                // Header not parsed yet — nothing meaningful to seek within.
                return
            }

            // Tear down the in-flight transfer + backlog. A parked reconnect
            // is superseded — the seek's fresh ranged request replaces it.
            self.generation &+= 1
            self.dataTask?.cancel()
            self.dataTask = nil
            self.taskSuspended = false
            self.pendingReconnect = false
            self.packetQueue.removeAll(keepingCapacity: true)
            self.converter?.reset()
            self.converterSawEndOfStream = false
            self.networkDone = false

            // Map the requested frame onto a packet boundary, then onto a
            // byte offset. Prefer the parser's packet table / bitrate
            // estimate; fall back to a byte-fraction guess for streams
            // without one (chunked transcodes).
            var landingFrame: AVAudioFramePosition = 0
            var byteOffset: Int64 = 0
            if self.framesPerPacket > 0,
               let mapped = parser.seekByteOffset(forPacket: targetFrame / self.framesPerPacket) {
                landingFrame = (targetFrame / self.framesPerPacket) * self.framesPerPacket
                byteOffset = mapped.byteOffset
            } else if parser.audioDataByteCount > 0,
                      let duration = self.durationHintSeconds, duration > 0,
                      let format = self.processingFormat {
                let totalFrames = AVAudioFramePosition(duration * format.sampleRate)
                let fraction = min(1, max(0, Double(targetFrame) / Double(max(1, totalFrames))))
                byteOffset = parser.dataOffset + Int64(fraction * Double(parser.audioDataByteCount))
                landingFrame = targetFrame
            } else {
                // No packet table, no length — restart from the top.
                byteOffset = 0
                landingFrame = 0
            }

            self.scheduledFrames = landingFrame
            self.playedFrames = landingFrame
            self.pendingSeekFrame = landingFrame
            self.startRequest(fromByte: byteOffset)
        }
    }

    /// Unblock buffer scheduling. The owner calls this once the engine
    /// graph is connected with the format delivered by `onFormatReady` —
    /// never before, or a format mismatch can raise inside AVFoundation.
    func beginScheduling() {
        decodeQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.schedulingAllowed = true
            self.pump()
        }
    }

    /// Owner transport hint (#1048): while paused, a dead transfer parks for
    /// a ranged reconnect instead of failing the track; flipping back to
    /// unpaused performs the parked reconnect. The parsed backlog and the
    /// node's scheduled buffers stay valid across the reconnect — only the
    /// network transfer restarts, from exactly the next undelivered byte.
    func setTransportPaused(_ paused: Bool) {
        decodeQueue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.transportPaused = paused
            guard !paused, self.pendingReconnect else { return }
            self.pendingReconnect = false
            self.startRequest(
                fromByte: self.responseStartByteOffset + self.receivedByteCount,
                continuation: true
            )
        }
    }

    /// Stop the transfer and drop all backlog. Safe to call repeatedly.
    func cancel() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.generation &+= 1
            self.dataTask?.cancel()
            self.dataTask = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.packetQueue.removeAll()
            self.parser = nil
            self.converter = nil
        }
    }

    // MARK: - Network

    private func startRequest(fromByte byteOffset: Int64, continuation: Bool = false) {
        if session == nil {
            let config = URLSessionConfiguration.default
            config.networkServiceType = .avStreaming
            session = URLSession(configuration: config, delegate: self, delegateQueue: sessionDelegateQueue)
        }
        guard let session else { return }

        var request = URLRequest(url: url)
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        if byteOffset > 0 {
            request.setValue("bytes=\(byteOffset)-", forHTTPHeaderField: "Range")
        }
        isContinuationResponse = continuation
        responseStartByteOffset = byteOffset
        receivedByteCount = 0
        let task = session.dataTask(with: request)
        dataTask = task
        taskSuspended = false
        task.resume()
    }

    // MARK: - Parse → decode → schedule (decode queue)

    private func wireParser(_ parser: DSPAudioFileStreamParser) {
        parser.onReadyToProducePackets = { [weak self] asbd, magicCookie in
            self?.handleFormatReady(asbd, magicCookie: magicCookie)
        }
        parser.onPackets = { [weak self] batch in
            self?.enqueue(batch)
        }
    }

    private func handleFormatReady(_ asbd: AudioStreamBasicDescription, magicCookie: Data?) {
        var asbd = asbd
        sourceASBD = asbd
        isSourceLPCM = asbd.mFormatID == kAudioFormatLinearPCM
        framesPerPacket = AVAudioFramePosition(asbd.mFramesPerPacket)

        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else {
            failOnDecodeQueue("Unsupported stream format")
            return
        }
        sourceFormat = inputFormat

        // Canonical engine format: float32, deinterleaved, source sample
        // rate, source channel count (folded to stereo beyond 2 channels —
        // AVAudioConverter downmixes). The main mixer resamples to the
        // output device rate, so no fidelity is lost here.
        let channels = min(max(asbd.mChannelsPerFrame, 1), 2)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            failOnDecodeQueue("Could not build engine processing format")
            return
        }
        processingFormat = outputFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            failOnDecodeQueue("No decoder available for this stream")
            return
        }
        if let magicCookie {
            converter.magicCookie = magicCookie
        }
        self.converter = converter

        DispatchQueue.main.async { [weak self] in
            self?.onFormatReady?(outputFormat)
        }
    }

    private func enqueue(_ batch: DSPAudioFileStreamParser.PacketBatch) {
        guard !cancelled else { return }
        if let descriptions = batch.packetDescriptions {
            for description in descriptions {
                let start = Int(description.mStartOffset)
                let length = Int(description.mDataByteSize)
                guard start >= 0, length > 0, start + length <= batch.data.count else { continue }
                var rebased = description
                rebased.mStartOffset = 0
                packetQueue.append((batch.data.subdata(in: start..<(start + length)), rebased))
            }
        } else {
            // CBR / LPCM: contiguous frame-aligned bytes, no descriptions.
            packetQueue.append((batch.data, nil))
        }
        applyNetworkBackpressure()
        pump()
    }

    /// Suspend the transfer while the parsed backlog is deep; resume once
    /// the decoder works it back down. Keeps long FLAC tracks from buffering
    /// the whole file into `packetQueue`.
    private func applyNetworkBackpressure() {
        guard let task = dataTask else { return }
        if packetQueue.count > packetQueueHighWater, !taskSuspended {
            task.suspend()
            taskSuspended = true
        } else if packetQueue.count < packetQueueHighWater / 2, taskSuspended {
            task.resume()
            taskSuspended = false
        }
    }

    /// Decode + schedule while there's input available and the node isn't
    /// already holding `maxScheduledAheadFrames` of unplayed audio. Called
    /// whenever packets arrive or a scheduled buffer finishes playing.
    private func pump() {
        guard !cancelled, schedulingAllowed, let converter, let outputFormat = processingFormat, let node = playerNode else { return }

        while scheduledFrames - playedFrames < maxScheduledAheadFrames {
            if packetQueue.isEmpty && !networkDone {
                return // wait for more bytes
            }
            if packetQueue.isEmpty && converterSawEndOfStream {
                return // fully drained; completion fires off the last buffer
            }

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputBufferFrameCapacity) else {
                failOnDecodeQueue("Buffer allocation failed")
                return
            }

            var conversionError: NSError?
            let status = converter.convert(to: pcmBuffer, error: &conversionError) { [weak self] requestedPackets, outStatus in
                guard let self else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard !self.packetQueue.isEmpty else {
                    if self.networkDone {
                        self.converterSawEndOfStream = true
                        outStatus.pointee = .endOfStream
                    } else {
                        outStatus.pointee = .noDataNow
                    }
                    return nil
                }
                guard let inputBuffer = self.dequeueInputBuffer(maxPackets: Int(requestedPackets)) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                if pcmBuffer.frameLength > 0 {
                    schedule(pcmBuffer, on: node)
                }
                if status == .endOfStream || (packetQueue.isEmpty && !networkDone) {
                    // Either truly finished, or out of input until the
                    // network delivers more.
                    if status == .endOfStream {
                        converterSawEndOfStream = true
                        checkForCompletion()
                    }
                    applyNetworkBackpressure()
                    return
                }
            case .error:
                failOnDecodeQueue(conversionError?.localizedDescription ?? "Audio decode failed")
                return
            @unknown default:
                return
            }
        }
        applyNetworkBackpressure()
    }

    /// Build the converter's next input buffer from the packet queue:
    /// an `AVAudioCompressedBuffer` for encoded sources, an interleaved
    /// `AVAudioPCMBuffer` for LPCM containers (WAV/AIFF).
    private func dequeueInputBuffer(maxPackets: Int) -> AVAudioBuffer? {
        guard let inputFormat = sourceFormat else { return nil }
        let take = min(max(1, maxPackets), packetQueue.count, 256)
        let slice = Array(packetQueue.prefix(take))
        packetQueue.removeFirst(take)

        if isSourceLPCM {
            // LPCM "packets" are frames; concatenate and wrap as PCM.
            var combined = Data()
            for entry in slice { combined.append(entry.data) }
            let bytesPerFrame = Int(sourceASBD.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return nil }
            let frames = combined.count / bytesPerFrame
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            combined.withUnsafeBytes { raw in
                if let base = raw.baseAddress, let dest = buffer.audioBufferList.pointee.mBuffers.mData {
                    memcpy(dest, base, min(raw.count, Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)))
                }
            }
            return buffer
        }

        let maxPacketSize = Int(parser?.maxPacketSize ?? 32_768)
        let buffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(slice.count),
            maximumPacketSize: maxPacketSize
        )
        var byteOffset = 0
        var packetIndex = 0
        for entry in slice {
            let length = entry.data.count
            guard byteOffset + length <= Int(buffer.byteCapacity) else { break }
            entry.data.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(buffer.data.advanced(by: byteOffset), base, length)
                }
            }
            if let descriptions = buffer.packetDescriptions {
                descriptions[packetIndex] = AudioStreamPacketDescription(
                    mStartOffset: Int64(byteOffset),
                    mVariableFramesInPacket: entry.description?.mVariableFramesInPacket ?? 0,
                    mDataByteSize: UInt32(length)
                )
            }
            byteOffset += length
            packetIndex += 1
        }
        buffer.packetCount = AVAudioPacketCount(packetIndex)
        buffer.byteLength = UInt32(byteOffset)
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        scheduledFrames += frames
        let scheduleGeneration = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.decodeQueue.async {
                guard !self.cancelled, scheduleGeneration == self.generation else { return }
                self.playedFrames += frames
                self.pump()
                self.checkForCompletion()
            }
        }
    }

    /// End-of-track: the network delivered everything, the converter drained,
    /// and the node has played back every frame we scheduled.
    private func checkForCompletion() {
        guard networkDone, converterSawEndOfStream, packetQueue.isEmpty else { return }
        guard playedFrames >= scheduledFrames else { return }
        guard !cancelled else { return }
        // One-shot: bump the generation so a straggling completion can't
        // re-fire it.
        generation &+= 1
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackFinished?()
        }
    }

    #if DEBUG
    /// Test seam: synchronous snapshot of decode/schedule progress, read
    /// off the decode queue so tests don't race the pump.
    func progressSnapshotForTesting() -> (scheduledFrames: AVAudioFramePosition, playedFrames: AVAudioFramePosition, queuedPackets: Int, networkDone: Bool) {
        decodeQueue.sync {
            (scheduledFrames, playedFrames, packetQueue.count, networkDone)
        }
    }
    #endif

    private func failOnDecodeQueue(_ message: String) {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        dataTask?.cancel()
        dataTask = nil
        packetQueue.removeAll()
        streamerLog.error("DSP stream failed: \(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onStreamError?(message)
        }
    }
}

// MARK: - URLSessionDataDelegate (delegate queue == decodeQueue)

extension DSPTrackStreamer: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !cancelled, dataTask === self.dataTask else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                completionHandler(.cancel)
                failOnDecodeQueue("Stream request failed (HTTP \(http.statusCode))")
                return
            }
            // A reconnect continuation only works if the server honoured the
            // Range header — a `200 OK` body restarts at byte zero, which
            // cannot be stitched onto the already-parsed stream. Fail the
            // track; the owner's ordinary skip/error path takes over.
            if isContinuationResponse, responseStartByteOffset > 0, http.statusCode != 206 {
                completionHandler(.cancel)
                failOnDecodeQueue("Stream reconnect failed (server ignored Range)")
                return
            }
            // A ranged (seek) request that came back `200 OK` means the
            // server ignored the Range header — the body restarts at byte
            // zero. Land the seek at frame 0 so position stays honest.
            if let seekFrame = pendingSeekFrame {
                let landed: AVAudioFramePosition
                if responseStartByteOffset > 0 && http.statusCode != 206 {
                    landed = 0
                    responseStartByteOffset = 0
                    scheduledFrames = 0
                    playedFrames = 0
                } else {
                    landed = seekFrame
                }
                pendingSeekFrame = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onSeekCommitted?(landed)
                }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, dataTask === self.dataTask, let parser else { return }
        // A mid-stream response start is a parse discontinuity after a seek,
        // but NOT after a reconnect continuation — those bytes are contiguous
        // with already-parsed data, and flagging them would make the parser
        // flush a partial frame the previous response half-delivered.
        let discontinuity = receivedByteCount == 0
            && responseStartByteOffset > 0
            && !isContinuationResponse
        receivedByteCount += Int64(data.count)
        do {
            try parser.parse(data, discontinuity: discontinuity)
        } catch {
            failOnDecodeQueue(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled, task === self.dataTask else { return }
        self.dataTask = nil
        if let error {
            let nsError = error as NSError
            // Explicit cancels (seek teardown) are not failures.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            // While the transport is paused nothing drains the decode pacing,
            // so an open response idles until CFNetwork's request timeout
            // (default 60s) kills the task. That is not a track failure —
            // park the stream and reconnect on resume (#1048). Everything
            // already parsed/scheduled stays valid.
            if transportPaused {
                pendingReconnect = true
                taskSuspended = false
                streamerLog.notice("DSP stream interrupted while paused; reconnecting on resume: \(nsError.localizedDescription, privacy: .public)")
                return
            }
            failOnDecodeQueue(nsError.localizedDescription)
            return
        }
        networkDone = true
        // The transfer is finished for good — release the session's strong
        // reference to this delegate so a fully-played streamer doesn't
        // linger until the next `cancel()`. (A subsequent seek re-creates
        // the session lazily in `startRequest`.)
        session.finishTasksAndInvalidate()
        self.session = nil
        // Wake the pump so it can drain the converter to end-of-stream even
        // if no further completions are pending.
        pump()
        checkForCompletion()
    }
}
