import AVFoundation
import FluidAudio
import Foundation
import OSLog
@preconcurrency import Speech

/// Runs high-accuracy offline diarization (VBx pipeline) and offline ASR on
/// per-stream WAV files after recording stops, then builds a completely new
/// transcript from scratch — replacing the live transcript entirely.
///
/// ## Why full replacement beats surgical patching
///
/// The live transcript is built under real-time constraints: 10s sliding windows,
/// race conditions between ASR and diarization, speaker fragmentation, boundary
/// bleed. Rather than trying to fix each segment individually, we run the full
/// audio through both the offline diarizer (~14% DER vs ~26% online) and offline
/// ASR (no progressive/volatile noise), then merge the two outputs by aligning
/// word-level timestamps against diarization speaker spans.
///
/// ## Flow
///
/// 1. Prepare offline diarizer models and ASR assets
/// 2. Run `OfflineDiarizerManager.process(url)` on each per-stream WAV
/// 3. Run `SpeechTranscriber` (offline mode, with audioTimeRange) on each WAV
/// 4. For each transcribed word, find which diarization speaker span it falls in
/// 5. Group consecutive same-speaker words into transcript segments
/// 6. Map offline speaker IDs to human-readable names using live transcript hints
/// 7. Return the completely rebuilt transcript
///
/// ## Embedding dimension mismatch
///
/// The offline diarizer uses 192-d WeSpeaker embeddings; VoiceID enrolled voices
/// use 256-d. We do NOT compare across embedding spaces. Speaker name mapping
/// uses temporal overlap between live segments and offline diarization segments.

// MARK: - Progress Tracking

/// Observable progress state for the post-recording refinement pipeline.
/// Observed by `StatusFooterView` to show a progress bar.
@MainActor
final class RefinementProgress: ObservableObject {
    static let shared = RefinementProgress()

    enum State: Equatable {
        case idle
        case preparingModels
        case diarizing(name: String, current: Int, total: Int)
        case transcribing(name: String, current: Int, total: Int)
        case buildingTranscript
        case complete(segments: Int, original: Int)
        case failed(String)
    }

    @Published var state: State = .idle

    /// True when refinement is actively running (not idle/complete/failed).
    var isActive: Bool {
        switch state {
        case .idle, .complete, .failed: return false
        default: return true
        }
    }

    /// Fractional progress (0.0–1.0) for the progress bar, or nil if indeterminate.
    var fraction: Double? {
        switch state {
        case .preparingModels: return nil
        case .diarizing(_, let current, let total):
            guard total > 0 else { return nil }
            // Diarizing is 0–40% of total progress
            return 0.4 * Double(current - 1) / Double(total)
        case .transcribing(_, let current, let total):
            guard total > 0 else { return nil }
            // Transcribing is 40–80%
            return 0.4 + 0.4 * Double(current - 1) / Double(total)
        case .buildingTranscript: return 0.9
        case .complete: return 1.0
        default: return nil
        }
    }

    /// Human-readable description of the current stage.
    var description: String {
        switch state {
        case .idle: return ""
        case .preparingModels: return "Preparing refinement models..."
        case .diarizing(let name, let current, let total):
            return "Diarizing \(name) audio (\(current)/\(total))..."
        case .transcribing(let name, let current, let total):
            return "Transcribing \(name) audio (\(current)/\(total))..."
        case .buildingTranscript: return "Building refined transcript..."
        case .complete(let segments, let original):
            return "Refinement complete: \(segments) segments (was \(original))"
        case .failed(let msg): return "Refinement failed: \(msg)"
        }
    }

    private init() {}
}

// MARK: - PostRecordingRefiner

@available(macOS 26.0, *)
final class PostRecordingRefiner {

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "PostRecordingRefiner")

    /// Per-stream offline diarization result.
    private struct DiarizationResult {
        let stream: StreamType
        let segments: [TimedSpeakerSegment]
        /// Per-speaker averaged 256-d embedding from the offline pipeline.
        let speakerDatabase: [String: [Float]]
    }

    /// Per-stream offline ASR result: words with timing.
    private struct TranscriptionResult {
        let stream: StreamType
        let words: [WordTiming]
    }

    // MARK: - Public API

    /// Build a completely new transcript using offline diarization + offline ASR.
    ///
    /// The live transcript (`liveSegments`) is used ONLY for mapping offline
    /// speaker IDs to human-readable names — the actual text and speaker
    /// boundaries come entirely from the offline pipeline.
    ///
    /// - Parameters:
    ///   - localWavURL: Path to local (mic) WAV file
    ///   - remoteWavURL: Path to remote (meeting app) WAV file
    ///   - liveSegments: The live transcript segments (used only for name mapping)
    /// - Returns: Completely rebuilt transcript segments
    func refine(
        localWavURL: URL?,
        remoteWavURL: URL?,
        liveSegments: [TaggedSegment]
    ) async throws -> [TaggedSegment] {
        logger.info("[REFINE] Starting full offline refinement")
        let progress = RefinementProgress.shared

        // ── 1. Identify streams to process ──
        let fm = FileManager.default
        var streamJobs: [(url: URL, stream: StreamType, name: String)] = []
        if let localURL = localWavURL, fm.fileExists(atPath: localURL.path) {
            streamJobs.append((localURL, .mic, "Local"))
        }
        if let remoteURL = remoteWavURL, fm.fileExists(atPath: remoteURL.path) {
            streamJobs.append((remoteURL, .meeting, "Remote"))
        }
        guard !streamJobs.isEmpty else {
            logger.warning("[REFINE] No WAV files found; returning live transcript unchanged")
            return liveSegments
        }

        // ── 2. Prepare offline diarizer models ──
        await MainActor.run { progress.state = .preparingModels }
        let diarizerConfig = OfflineDiarizerConfig.default
        let diarizer = OfflineDiarizerManager(config: diarizerConfig)

        logger.info("[REFINE] Preparing offline diarizer models...")
        try await diarizer.prepareModels()
        logger.info("[REFINE] Offline diarizer models ready")

        // ── 3. Run offline diarization on each stream ──
        var diarizationResults: [DiarizationResult] = []

        for (index, job) in streamJobs.enumerated() {
            await MainActor.run {
                progress.state = .diarizing(name: job.name, current: index + 1, total: streamJobs.count)
            }
            logger.info("[REFINE] Diarizing \(job.name) audio...")
            do {
                let result = try await diarizer.process(job.url)
                diarizationResults.append(DiarizationResult(
                    stream: job.stream,
                    segments: result.segments,
                    speakerDatabase: result.speakerDatabase ?? [:]
                ))
                let speakers = Set(result.segments.map(\.speakerId))
                logger.info("[REFINE] \(job.name) diarization: \(result.segments.count) segments, \(speakers.count) speakers: \(speakers.sorted().joined(separator: ", "))")
            } catch {
                logger.warning("[REFINE] \(job.name) diarization failed: \(error.localizedDescription)")
            }
        }

        // ── 4. Run offline ASR on each stream ──
        var transcriptionResults: [TranscriptionResult] = []

        for (index, job) in streamJobs.enumerated() {
            await MainActor.run {
                progress.state = .transcribing(name: job.name, current: index + 1, total: streamJobs.count)
            }
            logger.info("[REFINE] Transcribing \(job.name) audio...")
            do {
                let words = try await transcribeFile(url: job.url)
                transcriptionResults.append(TranscriptionResult(
                    stream: job.stream,
                    words: words
                ))
                logger.info("[REFINE] \(job.name) transcription: \(words.count) words")
            } catch {
                logger.warning("[REFINE] \(job.name) transcription failed: \(error.localizedDescription)")
            }
        }

        // If both diarization and transcription failed entirely, return live transcript
        guard !diarizationResults.isEmpty, !transcriptionResults.isEmpty else {
            logger.warning("[REFINE] Insufficient offline results; returning live transcript unchanged")
            await MainActor.run { progress.state = .idle }
            return liveSegments
        }

        // ── 5. Build name mapping from live transcript hints ──
        await MainActor.run { progress.state = .buildingTranscript }

        let nameMapping = buildNameMapping(
            liveSegments: liveSegments,
            diarizationResults: diarizationResults
        )

        // ── 6. Build the new transcript ──
        var allSegments: [TaggedSegment] = []

        for transcription in transcriptionResults {
            // Find matching diarization for this stream
            let diarization = diarizationResults.first { $0.stream == transcription.stream }

            let segments = buildStreamTranscript(
                words: transcription.words,
                diarizationSegments: diarization?.segments ?? [],
                stream: transcription.stream,
                nameMapping: nameMapping
            )
            allSegments.append(contentsOf: segments)
        }

        // For streams that had diarization but no transcription, we can't build
        // anything — those segments are just lost. The live transcript for that
        // stream could be kept, but mixing live + offline is confusing.
        // Streams with transcription but no diarization get a generic speaker name.

        // Sort by start time across all streams
        allSegments.sort { $0.start < $1.start }

        let originalCount = liveSegments.filter { $0.isFinal && $0.hasSubstantialContent }.count
        logger.info("[REFINE] Complete: \(allSegments.count) segments built from scratch (was \(originalCount) live segments)")

        await MainActor.run {
            progress.state = .complete(segments: allSegments.count, original: originalCount)
        }

        // Auto-dismiss after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .complete = progress.state {
                progress.state = .idle
            }
        }

        return allSegments
    }

    // MARK: - Offline ASR

    /// Transcribe a WAV file using the offline SpeechTranscriber pipeline.
    /// Returns word-level timing for every word in the file.
    private func transcribeFile(url: URL) async throws -> [WordTiming] {
        // Match locale (same as live ASR)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw RefinementError.unsupportedLocale
        }

        // Create transcriber with offline-quality settings + word timing.
        // Use explicit options to ensure audioTimeRange is included.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Check/download ASR assets if needed (usually already installed from live recording)
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            logger.info("[REFINE] ASR assets need downloading...")
            try await downloader.downloadAndInstall()
            logger.info("[REFINE] ASR assets installed")
        }

        // Set up analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results on a child task while analyzeSequence feeds data
        async let wordsFuture = collectWords(from: transcriber)

        // Feed the entire file through the analyzer
        let audioFile = try AVAudioFile(forReading: url)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await wordsFuture
    }

    /// Iterate the transcriber's result stream and extract per-word timing.
    private func collectWords(from transcriber: SpeechTranscriber) async throws -> [WordTiming] {
        var words: [WordTiming] = []

        for try await result in transcriber.results {
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                // Keep all non-empty runs (including punctuation-adjacent words)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                if let timeRange = run.audioTimeRange {
                    words.append(WordTiming(
                        word: text,
                        start: timeRange.start.seconds,
                        end: timeRange.end.seconds
                    ))
                } else {
                    // Word without timing — still include it with estimated timing
                    // based on the result's overall range
                    let range = result.range
                    words.append(WordTiming(
                        word: text,
                        start: range.start.seconds,
                        end: range.end.seconds
                    ))
                }
            }
        }

        return words
    }

    // MARK: - Transcript Building

    /// Build transcript segments for one stream by aligning ASR words with
    /// diarization speaker spans.
    ///
    /// For each word, finds the diarization speaker span that contains the
    /// word's midpoint. Consecutive same-speaker words are grouped into segments.
    private func buildStreamTranscript(
        words: [WordTiming],
        diarizationSegments: [TimedSpeakerSegment],
        stream: StreamType,
        nameMapping: [String: String]
    ) -> [TaggedSegment] {
        guard !words.isEmpty else { return [] }

        let fallbackSpeaker = "\(stream.rawValue)-Unknown"

        // Assign each word to a speaker based on time range overlap
        var wordSpeakers: [(word: WordTiming, speaker: String)] = []

        for word in words {
            let speaker = findSpeakerForWord(
                wordStart: word.start,
                wordEnd: word.end,
                diarizationSegments: diarizationSegments,
                stream: stream,
                nameMapping: nameMapping,
                fallback: fallbackSpeaker
            )
            wordSpeakers.append((word: word, speaker: speaker))
        }

        // Group consecutive same-speaker words into segments
        var segments: [TaggedSegment] = []
        var currentSpeaker = wordSpeakers[0].speaker
        var currentWords: [WordTiming] = [wordSpeakers[0].word]

        for i in 1..<wordSpeakers.count {
            let (word, speaker) = wordSpeakers[i]

            // Same speaker and not too big a gap — continue the segment
            let gap = word.start - (currentWords.last?.end ?? word.start)
            if speaker == currentSpeaker && gap < 3.0 {
                currentWords.append(word)
            } else {
                // Commit the current segment
                if let seg = makeSegment(
                    words: currentWords, speaker: currentSpeaker, stream: stream
                ) {
                    segments.append(seg)
                }
                currentSpeaker = speaker
                currentWords = [word]
            }
        }

        // Commit the last segment
        if let seg = makeSegment(
            words: currentWords, speaker: currentSpeaker, stream: stream
        ) {
            segments.append(seg)
        }

        return segments
    }

    /// Find which diarization speaker a word belongs to based on time range overlap.
    ///
    /// If any part of the word's time span overlaps any part of a diarization
    /// segment, the word belongs to that speaker. When multiple segments overlap
    /// (rare — only at speaker transitions), the one with the most overlap wins.
    /// If no overlap at all, falls back to the nearest segment by time distance.
    private func findSpeakerForWord(
        wordStart: TimeInterval,
        wordEnd: TimeInterval,
        diarizationSegments: [TimedSpeakerSegment],
        stream: StreamType,
        nameMapping: [String: String],
        fallback: String
    ) -> String {
        guard !diarizationSegments.isEmpty else { return fallback }

        // Find the diarization segment with the most overlap
        var bestSeg: TimedSpeakerSegment?
        var bestOverlap: TimeInterval = 0

        for seg in diarizationSegments {
            let segStart = Double(seg.startTimeSeconds)
            let segEnd = Double(seg.endTimeSeconds)
            let overlapStart = max(wordStart, segStart)
            let overlapEnd = min(wordEnd, segEnd)
            let overlap = overlapEnd - overlapStart

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSeg = seg
            }
        }

        if let seg = bestSeg {
            let key = "\(stream.rawValue)-\(seg.speakerId)"
            return nameMapping[key] ?? "\(stream.rawValue)-\(seg.speakerId)"
        }

        // No overlap — assign to the nearest segment by time distance
        var nearestSeg = diarizationSegments[0]
        var nearestDist: TimeInterval = .greatestFiniteMagnitude

        for seg in diarizationSegments {
            let segStart = Double(seg.startTimeSeconds)
            let segEnd = Double(seg.endTimeSeconds)
            let dist = wordEnd <= segStart ? segStart - wordEnd
                     : wordStart >= segEnd ? wordStart - segEnd
                     : 0
            if dist < nearestDist {
                nearestDist = dist
                nearestSeg = seg
            }
        }

        let key = "\(stream.rawValue)-\(nearestSeg.speakerId)"
        return nameMapping[key] ?? "\(stream.rawValue)-\(nearestSeg.speakerId)"
    }

    /// Create a TaggedSegment from a group of words.
    private func makeSegment(
        words: [WordTiming],
        speaker: String,
        stream: StreamType
    ) -> TaggedSegment? {
        guard !words.isEmpty else { return nil }

        let text = words.map(\.word).joined()
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Skip segments that are only whitespace/punctuation
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }

        return TaggedSegment(
            stream: stream,
            speaker: speaker,
            start: words.first!.start,
            end: words.last!.end,
            text: trimmed,
            isFinal: true,
            wordTimings: words
        )
    }

    // MARK: - Name Mapping

    /// Build a mapping from offline speaker IDs to human-readable names.
    ///
    /// **Strategy (two-pass)**:
    ///
    /// 1. **Direct embedding match** — Compare each offline speaker's 256-d
    ///    embedding (from `speakerDatabase`) against VoiceID enrolled voices.
    ///    Both pipelines use WeSpeaker models producing 256-d vectors. If
    ///    cosine similarity exceeds the recognition threshold, map directly.
    ///    This is the most reliable method — pure acoustic matching.
    ///
    /// 2. **Temporal overlap fallback** — For speakers not matched by embedding,
    ///    find which live speaker name has the most temporal overlap and transfer
    ///    that name. This handles non-enrolled speakers that the live pipeline
    ///    had already identified (e.g., "Local-2").
    private func buildNameMapping(
        liveSegments: [TaggedSegment],
        diarizationResults: [DiarizationResult]
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        let enrolledVoices = VoiceID.shared.allEnrolledVoices()
        let recognitionThreshold = VoiceID.shared.similarityThreshold

        for diarResult in diarizationResults {
            let stream = diarResult.stream
            var usedNames: Set<String> = []

            // Group offline segments by speaker for duration ranking
            var offlineSpeakerSegments: [String: [TimedSpeakerSegment]] = [:]
            for seg in diarResult.segments {
                offlineSpeakerSegments[seg.speakerId, default: []].append(seg)
            }

            // Sort offline speakers by total speech duration (most speech first)
            let rankedOfflineSpeakers = offlineSpeakerSegments.keys.sorted { a, b in
                let aDur = offlineSpeakerSegments[a]?.reduce(0.0) { $0 + Double($1.durationSeconds) } ?? 0
                let bDur = offlineSpeakerSegments[b]?.reduce(0.0) { $0 + Double($1.durationSeconds) } ?? 0
                return aDur > bDur
            }

            // ── Pass 1: Direct embedding comparison against enrolled voices ──
            for offlineSpeakerID in rankedOfflineSpeakers {
                let key = "\(stream.rawValue)-\(offlineSpeakerID)"
                guard let offlineEmbedding = diarResult.speakerDatabase[offlineSpeakerID],
                      !offlineEmbedding.isEmpty else { continue }

                var bestMatch: (userID: String, similarity: Float)?

                for voice in enrolledVoices {
                    guard !usedNames.contains(voice.userID) else { continue }
                    let sim = cosineSimilarity(offlineEmbedding, voice.vector)
                    if sim >= recognitionThreshold {
                        if bestMatch == nil || sim > bestMatch!.similarity {
                            bestMatch = (userID: voice.userID, similarity: sim)
                        }
                    }
                }

                if let match = bestMatch {
                    mapping[key] = match.userID
                    usedNames.insert(match.userID)
                    logger.info("[REFINE] Mapping offline \(offlineSpeakerID) → '\(match.userID)' (embedding similarity \(String(format: "%.3f", match.similarity)))")
                }
            }

            // ── Pass 2: Temporal overlap for unmapped speakers ──
            let streamLiveSegments = liveSegments.filter {
                $0.stream == stream && $0.isFinal && !$0.text.isEmpty
            }

            for offlineSpeakerID in rankedOfflineSpeakers {
                let key = "\(stream.rawValue)-\(offlineSpeakerID)"
                guard mapping[key] == nil else { continue } // Already mapped by embedding

                guard let offlineSegs = offlineSpeakerSegments[offlineSpeakerID] else {
                    mapping[key] = "\(stream.rawValue)-\(offlineSpeakerID)"
                    continue
                }

                // Calculate overlap with each live speaker
                var liveSpeakerOverlaps: [String: TimeInterval] = [:]
                for offlineSeg in offlineSegs {
                    let oStart = Double(offlineSeg.startTimeSeconds)
                    let oEnd = Double(offlineSeg.endTimeSeconds)

                    for liveSeg in streamLiveSegments {
                        let overlapStart = max(oStart, liveSeg.start)
                        let overlapEnd = min(oEnd, liveSeg.end)
                        let overlap = max(0, overlapEnd - overlapStart)
                        if overlap > 0 {
                            liveSpeakerOverlaps[liveSeg.speaker, default: 0] += overlap
                        }
                    }
                }

                let ranked = liveSpeakerOverlaps.sorted { $0.value > $1.value }

                // Pick the best live name that isn't already used
                var bestName: String?
                for (liveName, _) in ranked {
                    if !usedNames.contains(liveName) {
                        bestName = liveName
                        break
                    }
                }

                let resolvedName = bestName ?? "\(stream.rawValue)-\(offlineSpeakerID)"
                mapping[key] = resolvedName
                usedNames.insert(resolvedName)

                let dur = String(format: "%.1f", liveSpeakerOverlaps.values.reduce(0, +))
                logger.info("[REFINE] Mapping offline \(offlineSpeakerID) → '\(resolvedName)' (\(dur)s temporal overlap)")
            }
        }

        return mapping
    }

    // MARK: - Utilities

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA * normB)
        return denom > 1e-6 ? dot / denom : 0
    }
}

// MARK: - Errors

enum RefinementError: Error, LocalizedError {
    case unsupportedLocale

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "No supported locale for offline speech transcription."
        }
    }
}
