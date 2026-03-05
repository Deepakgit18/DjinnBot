import Combine
import Foundation
import OSLog

// MARK: - Supporting Types

/// Timestamp-tracked unattributed ASR segment awaiting resolution.
public struct UnattributedEntry: Sendable {
    public let asr: ASRSegment
    /// Wall-clock time when this entry was first added to the unattributed buffer.
    public let addedAt: Date
}

/// Per-speaker profile maintained by the speaker registry.
/// Tracks the best (longest, cleanest) embedding and a duration-weighted centroid.
public struct RegistrySpeakerProfile {
    public var name: String
    public var stream: StreamType
    /// Duration-weighted running average of all embeddings for this speaker.
    public var centroid: [Float]
    /// Embedding from the single longest segment — the cleanest reference.
    public var bestEmbedding: [Float]
    /// Duration of the segment that produced `bestEmbedding`.
    public var bestSegmentDuration: TimeInterval
    /// Total accumulated speech duration across all segments.
    public var totalSpeechDuration: TimeInterval
    /// Number of segments committed to this speaker.
    public var segmentCount: Int
}

// MARK: - MergeEngine

/// Merges ASR transcript segments and diarization speaker segments from
/// both mic and meeting streams onto a single shared audio timeline.
///
/// ## Progressive Refinement
///
/// The engine maintains a **Speaker Registry** that improves over time:
/// - Each speaker's best embedding comes from their longest, cleanest segment
/// - A duration-weighted centroid accumulates as more speech is collected
/// - Periodic refinement passes merge fragmented speakers, auto-rename
///   enrolled voices, and re-attribute suspect segments
///
/// ## Resolution Priority (for unattributed segments)
///
/// 1. **Diarization overlap** (>= 0.5s) — immediate
/// 2. **Embedding extraction vs registry** (segments >= 2s) — async
/// 3. **Refinement pass** (every 15s) — catches short segments & corrections
/// 4. **Permanent Speaker-?** (30s timeout) — genuinely unknown
///
/// No temporal adjacency fallback — attribution is always acoustic or diarization-based.
@MainActor
public final class MergeEngine: ObservableObject {

    public static let shared = MergeEngine()

    // MARK: - Published Output

    @Published public var mergedSegments: [TaggedSegment] = []

    // MARK: - Internal State

    /// Committed diarization segments (speaker labels, may have text from finals).
    private var diarizationSegments: [TaggedSegment] = []

    /// Finalized ASR segments waiting to be merged with diarization.
    private var finalASRBuffer: [ASRSegment] = []

    /// ASR finals with no diarization overlap, awaiting resolution.
    private var unattributedASR: [UnattributedEntry] = []

    /// One "live partial" per stream for immediate display.
    private var livePartials: [StreamType: ASRSegment] = [:]

    /// Debounce timer for batch merge operations.
    private var mergeTimer: Timer?
    private let mergeInterval: TimeInterval = 0.25

    /// Minimum temporal overlap (seconds) for ASR↔diarization matching.
    private let minOverlapThreshold: TimeInterval = 0.5

    /// Minimum ASR segment duration to attempt embedding extraction.
    /// Shorter segments can't produce reliable embeddings (10s window
    /// would be dominated by other speakers' audio).
    private let minDurationForExtraction: TimeInterval = 2.0

    /// How long (seconds) before an unattributed entry becomes permanent Speaker-?.
    private let permanentTimeoutDelay: TimeInterval = 30.0

    // MARK: - Speaker Registry

    /// Per-speaker profiles with best embeddings and centroids.
    /// Keyed by speaker name (e.g. "Remote-2", "sky").
    private var speakerRegistry: [String: RegistrySpeakerProfile] = [:]

    /// Speaker merge threshold — if two speakers' centroids are more similar
    /// than this, they are merged into one.
    private let speakerMergeThreshold: Float = 0.85

    // MARK: - Embedding Extraction

    /// Registered per-stream diarization managers for embedding extraction.
    /// Stored as `Any` to avoid `@available` on stored properties.
    private var _diarizationManagers: [StreamType: Any] = [:]

    /// In-flight extraction tasks (keyed by ASR start time).
    private var pendingExtractions: Set<TimeInterval> = []

    /// Number of extraction attempts per ASR start time. Used to cap retries.
    private var extractionAttempts: [TimeInterval: Int] = [:]

    /// Maximum number of embedding extraction retries before giving up.
    private let maxExtractionRetries = 5

    /// Set to true when recording stops and extractors are being torn down.
    /// Prevents new extraction requests from being enqueued.
    private var extractionsStopped = false

    /// Completed extraction results awaiting consumption.
    private var completedEmbeddings: [TimeInterval: [Float]] = [:]

    /// Minimum cosine similarity for embedding-based speaker matching.
    /// Configurable via Settings ("Embedding Match Threshold").
    private var embeddingMatchThreshold: Float {
        let v = UserDefaults.standard.float(forKey: "embeddingMatchThreshold")
        return v > 0 ? v : 0.40
    }

    // MARK: - Refinement

    /// Timer for periodic refinement passes.
    private var refinementTimer: Timer?
    private let refinementInterval: TimeInterval = 15.0

    // MARK: - VoiceID (Sortformer only)

    /// Speaker renames discovered via VoiceID (Sortformer) or refinement (Pyannote).
    private var speakerRenames: [String: String] = [:]
    private var identifiedSpeakers: Set<String> = []
    private var speakerDurations: [String: TimeInterval] = [:]
    private let minDurationForVoiceID: TimeInterval = 3.0

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MergeEngine")

    private init() {}

    // MARK: - Registration

    func registerDiarizationManager(_ manager: RealtimeDiarizationManager, for stream: StreamType) {
        _diarizationManagers[stream] = manager
    }

    // MARK: - Ingestion

    public func add(_ segment: TaggedSegment) {
        var seg = segment
        if let rename = speakerRenames[seg.speaker] {
            seg.speaker = rename
        }
        diarizationSegments.append(seg)

        // Update the speaker registry with this new segment
        updateRegistry(speaker: seg.speaker, stream: seg.stream,
                       embedding: seg.embedding, duration: seg.duration)

        // Sortformer-only VoiceID identification
        attemptVoiceIdentification(for: segment)

        scheduleMerge()
    }

    /// Add a batch of diarization segments in a single MainActor hop.
    /// Called by RealtimeDiarizationManager to avoid N separate MainActor
    /// hops per Pyannote chunk (which causes diarization lag).
    public func addBatch(_ segments: [TaggedSegment]) {
        for segment in segments {
            var seg = segment
            if let rename = speakerRenames[seg.speaker] {
                seg.speaker = rename
            }
            diarizationSegments.append(seg)

            updateRegistry(speaker: seg.speaker, stream: seg.stream,
                           embedding: seg.embedding, duration: seg.duration)

            attemptVoiceIdentification(for: segment)
        }

        if !segments.isEmpty {
            scheduleMerge()
        }
    }

    public func addASR(_ segment: ASRSegment) {
        if segment.isFinal {
            finalASRBuffer.append(segment)
            livePartials.removeValue(forKey: segment.stream)
        } else {
            livePartials[segment.stream] = segment
        }
        scheduleMerge()
    }

    // MARK: - Speaker Registry

    /// Update the registry with a new segment for a speaker.
    private func updateRegistry(speaker: String, stream: StreamType,
                                embedding: [Float], duration: TimeInterval) {
        if var profile = speakerRegistry[speaker] {
            let oldTotal = profile.totalSpeechDuration
            profile.totalSpeechDuration += duration
            profile.segmentCount += 1

            if !embedding.isEmpty {
                if profile.centroid.isEmpty {
                    profile.centroid = embedding
                } else {
                    // Duration-weighted running average
                    let newTotal = profile.totalSpeechDuration
                    let oldWeight = Float(oldTotal / newTotal)
                    let newWeight = Float(duration / newTotal)
                    var updated = [Float](repeating: 0, count: embedding.count)
                    for i in 0..<embedding.count {
                        updated[i] = profile.centroid[i] * oldWeight + embedding[i] * newWeight
                    }
                    // L2 normalize
                    let norm = sqrt(updated.reduce(Float(0)) { $0 + $1 * $1 })
                    if norm > 1e-6 {
                        for i in 0..<updated.count { updated[i] /= norm }
                    }
                    profile.centroid = updated
                }

                // Update best embedding if this segment is longer
                if duration > profile.bestSegmentDuration {
                    profile.bestEmbedding = embedding
                    profile.bestSegmentDuration = duration
                }
            }
            speakerRegistry[speaker] = profile
        } else {
            speakerRegistry[speaker] = RegistrySpeakerProfile(
                name: speaker, stream: stream,
                centroid: embedding,
                bestEmbedding: embedding,
                bestSegmentDuration: embedding.isEmpty ? 0 : duration,
                totalSpeechDuration: duration,
                segmentCount: 1
            )
        }
    }

    /// Match an embedding against the registry's best embeddings for a given stream.
    private func matchAgainstRegistry(
        _ embedding: [Float], stream: StreamType
    ) -> (name: String, similarity: Float)? {
        let threshold = embeddingMatchThreshold
        var bestName: String?
        var bestSim: Float = -1

        for (name, profile) in speakerRegistry where profile.stream == stream {
            // Prefer bestEmbedding (from longest segment), fall back to centroid
            let ref = !profile.bestEmbedding.isEmpty ? profile.bestEmbedding : profile.centroid
            guard !ref.isEmpty else { continue }
            let sim = cosineSimilarity(embedding, ref)
            if sim > bestSim {
                bestSim = sim
                bestName = name
            }
        }

        guard let name = bestName, bestSim >= threshold else { return nil }
        return (name: name, similarity: bestSim)
    }

    // MARK: - VoiceID Identification (Sortformer only)

    private func attemptVoiceIdentification(for segment: TaggedSegment) {
        let key = segment.speaker
        let modeRaw = UserDefaults.standard.string(forKey: "diarizationMode") ?? ""
        let mode = DiarizationMode(rawValue: modeRaw) ?? .pyannoteStreaming
        guard mode == .sortformer else { return }
        guard !identifiedSpeakers.contains(key),
              VoiceID.shared.hasEnrolledVoices else { return }

        speakerDurations[key, default: 0] += segment.duration
        guard speakerDurations[key, default: 0] >= minDurationForVoiceID else { return }
        guard !segment.embedding.isEmpty else { return }

        identifiedSpeakers.insert(key)
        let (userID, similarity) = VoiceID.shared.identifySpeaker(fromEmbedding: segment.embedding)
        if let userID {
            speakerRenames[key] = userID
            renameSpeaker(from: key, to: userID)
            logger.info("VoiceID: '\(key)' → '\(userID)' (similarity \(String(format: "%.3f", similarity)))")
        } else {
            logger.info("VoiceID: '\(key)' unrecognised (best similarity \(String(format: "%.3f", similarity)))")
        }
    }

    private func renameSpeaker(from oldName: String, to newName: String) {
        for i in diarizationSegments.indices where diarizationSegments[i].speaker == oldName {
            diarizationSegments[i].speaker = newName
        }

        // Update registry: merge old profile into new name
        if let oldProfile = speakerRegistry.removeValue(forKey: oldName) {
            if var newProfile = speakerRegistry[newName] {
                // Merge: keep the better bestEmbedding
                newProfile.totalSpeechDuration += oldProfile.totalSpeechDuration
                newProfile.segmentCount += oldProfile.segmentCount
                if oldProfile.bestSegmentDuration > newProfile.bestSegmentDuration
                    && !oldProfile.bestEmbedding.isEmpty {
                    newProfile.bestEmbedding = oldProfile.bestEmbedding
                    newProfile.bestSegmentDuration = oldProfile.bestSegmentDuration
                }
                speakerRegistry[newName] = newProfile
            } else {
                var renamed = oldProfile
                renamed.name = newName
                speakerRegistry[newName] = renamed
            }
        }

        scheduleMerge()
    }

    // MARK: - Merge Logic

    private func scheduleMerge() {
        mergeTimer?.invalidate()
        mergeTimer = Timer.scheduledTimer(withTimeInterval: mergeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.performMerge() }
        }
    }

    /// Start the periodic refinement timer. Called once at recording start.
    public func startRefinementTimer() {
        refinementTimer?.invalidate()
        refinementTimer = Timer.scheduledTimer(withTimeInterval: refinementInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performRefinement() }
        }
    }

    private func performMerge() {
        let modeRaw = UserDefaults.standard.string(forKey: "diarizationMode") ?? ""
        let currentMode = DiarizationMode(rawValue: modeRaw) ?? .pyannoteStreaming

        // ── 1a. Retry unattributed ASR finals ──
        var stillUnattributed: [UnattributedEntry] = []
        for entry in unattributedASR {
            let age = Date().timeIntervalSince(entry.addedAt)
            let key = entry.asr.start
            let duration = entry.asr.end - entry.asr.start

            // Priority 1: Check for completed embedding extraction
            if let embedding = completedEmbeddings.removeValue(forKey: key) {
                if let speaker = matchAgainstRegistry(embedding, stream: entry.asr.stream) {
                    let asrS = String(format: "%.1f", entry.asr.start)
                    let asrE = String(format: "%.1f", entry.asr.end)
                    logger.info("[MERGE] \(entry.asr.stream.rawValue) [\(asrS)s-\(asrE)s] → '\(speaker.name)' (embedding similarity \(String(format: "%.3f", speaker.similarity))): \"\(entry.asr.text)\"")
                    let resolved = TaggedSegment(
                        stream: entry.asr.stream, speaker: speaker.name,
                        start: entry.asr.start, end: entry.asr.end,
                        text: entry.asr.text, embedding: embedding, isFinal: true,
                        wordTimings: entry.asr.wordTimings
                    )
                    diarizationSegments.append(resolved)
                    updateRegistry(speaker: speaker.name, stream: entry.asr.stream,
                                   embedding: embedding, duration: duration)
                    continue
                }
                // Embedding didn't match any speaker above threshold — keep waiting
            }

            // Priority 2: Try diarization overlap (may have caught up)
            if let resolved = resolveASR(entry.asr) {
                commitResolved(asr: entry.asr, match: resolved)
                continue
            }

            // Priority 3: Trigger extraction for segments >= 2s (if not already in flight)
            if duration >= minDurationForExtraction && !pendingExtractions.contains(key) {
                triggerEmbeddingExtraction(for: entry)
            }
            // Short segments (<2s) just wait for the refinement pass.

            // Permanent timeout — commit as Speaker-?
            if age >= permanentTimeoutDelay {
                let asrS = String(format: "%.1f", entry.asr.start)
                let asrE = String(format: "%.1f", entry.asr.end)
                logger.warning("[MERGE] \(entry.asr.stream.rawValue) [\(asrS)s-\(asrE)s] → 'Speaker-?' (timeout \(String(format: "%.0f", age))s): \"\(entry.asr.text)\"")
                let fallback = TaggedSegment(
                    stream: entry.asr.stream, speaker: "Speaker-?",
                    start: entry.asr.start, end: entry.asr.end,
                    text: entry.asr.text, isFinal: true,
                    wordTimings: entry.asr.wordTimings
                )
                diarizationSegments.append(fallback)
                continue
            }

            stillUnattributed.append(entry)
        }
        unattributedASR = stillUnattributed

        // ── 1b. Process new ASR finals ──
        var deferred: [ASRSegment] = []
        for asr in finalASRBuffer {
            let sameStreamDiar = diarizationSegments.filter { $0.stream == asr.stream }
            let asrStart = String(format: "%.1f", asr.start)
            let asrEnd = String(format: "%.1f", asr.end)
            let streamName = asr.stream.rawValue

            if sameStreamDiar.isEmpty {
                deferred.append(asr)
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] DEFERRED (no diar segs yet): \"\(asr.text)\"")
            } else if let resolved = resolveASR(asr) {
                commitResolved(asr: asr, match: resolved)
            } else if currentMode == .sortformer {
                let recentDiar = sameStreamDiar.max { $0.end < $1.end }
                let fallbackSpeaker = recentDiar?.speaker ?? "\(asr.stream.rawValue)-Unknown"
                let fallback = TaggedSegment(
                    stream: asr.stream, speaker: fallbackSpeaker,
                    start: asr.start, end: asr.end,
                    text: asr.text, isFinal: true,
                    wordTimings: asr.wordTimings
                )
                diarizationSegments.append(fallback)
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → '\(fallbackSpeaker)' (Sortformer nearest): \"\(asr.text)\"")
            } else {
                // Pyannote: hold as unattributed
                let entry = UnattributedEntry(asr: asr, addedAt: Date())
                unattributedASR.append(entry)
                // Only trigger extraction for segments >= 2s
                if (asr.end - asr.start) >= minDurationForExtraction {
                    triggerEmbeddingExtraction(for: entry)
                }
                let diarCount = sameStreamDiar.count
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] UNATTRIBUTED (\(diarCount) diar segs): \"\(asr.text)\"")
            }
        }
        finalASRBuffer = deferred

        // ── 2. Build output ──
        buildOutput()
    }

    /// Build the merged output from committed segments + unattributed + partials.
    private func buildOutput() {
        var output = collapseAdjacentSegments(diarizationSegments)

        // Unattributed as "Speaker-?"
        for entry in unattributedASR {
            let placeholder = TaggedSegment(
                stream: entry.asr.stream, speaker: "Speaker-?",
                start: entry.asr.start, end: entry.asr.end,
                text: entry.asr.text, isFinal: true,
                wordTimings: entry.asr.wordTimings
            )
            output.append(placeholder)
        }

        // Live partials
        for (partialStream, partial) in livePartials {
            let streamDiarSegs = diarizationSegments.filter { $0.stream == partialStream }
            let recentDiar = streamDiarSegs.max { $0.end < $1.end }
            let speaker = recentDiar?.speaker ?? "\(partialStream.rawValue)-..."
            let partialSeg = TaggedSegment(
                stream: partialStream, speaker: speaker,
                start: partial.start, end: partial.end,
                text: partial.text, isFinal: false
            )
            output.append(partialSeg)
        }

        let withText = output.filter { $0.hasSubstantialContent }
        let finals = withText.filter { $0.isFinal }.sorted { $0.start < $1.start }
        let partials = withText.filter { !$0.isFinal }.sorted { $0.end < $1.end }
        mergedSegments = finals + partials
    }

    // MARK: - Refinement Pass

    /// Periodic refinement that progressively improves accuracy:
    /// 1. Merge fragmented speakers (centroids too similar)
    /// 2. Auto-rename speakers matching enrolled voices
    /// 3. Re-attribute suspect segments against improved registry
    /// 4. Resolve short unattributed segments using surrounding context
    private func performRefinement() {
        guard !diarizationSegments.isEmpty else { return }

        let changesMade = mergeSimilarSpeakers()
            || matchEnrolledVoices()
            || reAttributeSuspectSegments()
            || resolveShortUnattributed()

        if changesMade {
            logger.info("[REFINEMENT] Pass complete, changes applied")
            buildOutput()
        }
    }

    /// Merge speakers whose centroids are too similar (fragmentation fix).
    /// Returns true if any merges occurred.
    @discardableResult
    private func mergeSimilarSpeakers() -> Bool {
        var merged = false
        let speakers = Array(speakerRegistry.keys)

        for i in 0..<speakers.count {
            for j in (i + 1)..<speakers.count {
                let nameA = speakers[i]
                let nameB = speakers[j]
                guard let a = speakerRegistry[nameA],
                      let b = speakerRegistry[nameB],
                      a.stream == b.stream else { continue }

                let refA = !a.bestEmbedding.isEmpty ? a.bestEmbedding : a.centroid
                let refB = !b.bestEmbedding.isEmpty ? b.bestEmbedding : b.centroid
                guard !refA.isEmpty, !refB.isEmpty else { continue }

                let sim = cosineSimilarity(refA, refB)
                if sim >= speakerMergeThreshold {
                    // Merge B into A (keep the one with more speech)
                    let (keepName, mergeName) = a.totalSpeechDuration >= b.totalSpeechDuration
                        ? (nameA, nameB) : (nameB, nameA)

                    logger.info("[REFINEMENT] Merging '\(mergeName)' into '\(keepName)' (similarity \(String(format: "%.3f", sim)))")

                    // Rename all segments
                    for idx in diarizationSegments.indices where diarizationSegments[idx].speaker == mergeName {
                        diarizationSegments[idx].speaker = keepName
                    }

                    // Merge registry profiles
                    if let mergedProfile = speakerRegistry.removeValue(forKey: mergeName),
                       var keepProfile = speakerRegistry[keepName] {
                        keepProfile.totalSpeechDuration += mergedProfile.totalSpeechDuration
                        keepProfile.segmentCount += mergedProfile.segmentCount
                        if mergedProfile.bestSegmentDuration > keepProfile.bestSegmentDuration
                            && !mergedProfile.bestEmbedding.isEmpty {
                            keepProfile.bestEmbedding = mergedProfile.bestEmbedding
                            keepProfile.bestSegmentDuration = mergedProfile.bestSegmentDuration
                        }
                        speakerRegistry[keepName] = keepProfile
                    }

                    speakerRenames[mergeName] = keepName
                    merged = true
                }
            }
        }
        return merged
    }

    /// Check if any registry speaker matches an enrolled voice that
    /// Pyannote's SpeakerManager missed. Returns true if renames occurred.
    @discardableResult
    private func matchEnrolledVoices() -> Bool {
        guard VoiceID.shared.hasEnrolledVoices else { return false }
        var renamed = false

        for (name, profile) in speakerRegistry {
            // Skip if already an enrolled voice name or already checked
            guard !identifiedSpeakers.contains(name) else { continue }

            let ref = !profile.bestEmbedding.isEmpty ? profile.bestEmbedding : profile.centroid
            guard !ref.isEmpty else { continue }

            identifiedSpeakers.insert(name)

            let (userID, similarity) = VoiceID.shared.identifySpeaker(fromEmbedding: ref)
            if let userID, userID != name {
                logger.info("[REFINEMENT] '\(name)' matches enrolled voice '\(userID)' (similarity \(String(format: "%.3f", similarity)))")
                renameSpeaker(from: name, to: userID)
                renamed = true
            }
        }
        return renamed
    }

    /// Re-evaluate committed segments against the improved registry.
    /// Segments with embeddings that now better match a different speaker
    /// are re-attributed. Returns true if any changes occurred.
    @discardableResult
    private func reAttributeSuspectSegments() -> Bool {
        var changed = false
        let threshold = embeddingMatchThreshold
        let reAttributeMargin: Float = 0.05 // must beat current speaker by this margin

        for i in diarizationSegments.indices {
            let seg = diarizationSegments[i]
            guard !seg.embedding.isEmpty, seg.isFinal, !seg.text.isEmpty else { continue }

            // Check current speaker's score
            guard let currentProfile = speakerRegistry[seg.speaker] else { continue }
            let currentRef = !currentProfile.bestEmbedding.isEmpty
                ? currentProfile.bestEmbedding : currentProfile.centroid
            let currentSim = currentRef.isEmpty ? Float(0) : cosineSimilarity(seg.embedding, currentRef)

            // Check all other speakers on same stream
            var bestOtherName: String?
            var bestOtherSim: Float = -1
            for (name, profile) in speakerRegistry where profile.stream == seg.stream && name != seg.speaker {
                let ref = !profile.bestEmbedding.isEmpty ? profile.bestEmbedding : profile.centroid
                guard !ref.isEmpty else { continue }
                let sim = cosineSimilarity(seg.embedding, ref)
                if sim > bestOtherSim {
                    bestOtherSim = sim
                    bestOtherName = name
                }
            }

            if let otherName = bestOtherName,
               bestOtherSim >= threshold,
               bestOtherSim > currentSim + reAttributeMargin {
                let ts = String(format: "%.1f", seg.start)
                let te = String(format: "%.1f", seg.end)
                logger.info("[REFINEMENT] Re-attribute [\(ts)s-\(te)s] '\(seg.speaker)' → '\(otherName)' (sim \(String(format: "%.3f", currentSim)) → \(String(format: "%.3f", bestOtherSim)))")
                diarizationSegments[i].speaker = otherName
                changed = true
            }
        }
        return changed
    }

    /// Resolve short unattributed segments that couldn't be extracted.
    /// Uses diarization overlap (may have caught up by now) or, if the segment
    /// is surrounded by the same speaker, assigns to that speaker.
    @discardableResult
    private func resolveShortUnattributed() -> Bool {
        var resolved: [Int] = [] // indices to remove

        for (idx, entry) in unattributedASR.enumerated() {
            // Try diarization overlap first (it may have caught up)
            if let match = resolveASR(entry.asr) {
                commitResolved(asr: entry.asr, match: match)
                resolved.append(idx)
                continue
            }

            // Check surrounding committed segments (same stream, with text)
            let sameStream = diarizationSegments.filter {
                $0.stream == entry.asr.stream && !$0.text.isEmpty && $0.isFinal
            }
            let asrStart = entry.asr.start
            let asrEnd = entry.asr.end

            let preceding = sameStream
                .filter { $0.end <= asrStart + 0.5 }
                .max { (a: TaggedSegment, b: TaggedSegment) in a.end < b.end }
            let following = sameStream
                .filter { $0.start >= asrEnd - 0.5 }
                .min { (a: TaggedSegment, b: TaggedSegment) in a.start < b.start }

            // If both neighbours are the same speaker, it's very likely this segment too
            if let prev = preceding, let next = following, prev.speaker == next.speaker {
                let speaker = prev.speaker
                let ts = String(format: "%.1f", asrStart)
                let te = String(format: "%.1f", asrEnd)
                logger.info("[REFINEMENT] Short segment [\(ts)s-\(te)s] → '\(speaker)' (same speaker before & after): \"\(entry.asr.text)\"")
                let seg = TaggedSegment(
                    stream: entry.asr.stream, speaker: speaker,
                    start: asrStart, end: asrEnd,
                    text: entry.asr.text, isFinal: true,
                    wordTimings: entry.asr.wordTimings
                )
                diarizationSegments.append(seg)
                resolved.append(idx)
            }
        }

        // Remove resolved entries (reverse order to preserve indices)
        for idx in resolved.sorted().reversed() {
            unattributedASR.remove(at: idx)
        }
        return !resolved.isEmpty
    }

    // MARK: - Embedding Extraction

    private func triggerEmbeddingExtraction(for entry: UnattributedEntry) {
        let key = entry.asr.start
        guard !extractionsStopped else { return }
        guard !pendingExtractions.contains(key) else { return }

        // Cap retries to avoid infinite retry loops after recording stops.
        let attempts = extractionAttempts[key, default: 0]
        guard attempts < maxExtractionRetries else { return }
        extractionAttempts[key] = attempts + 1

        guard
              let manager = _diarizationManagers[entry.asr.stream] as? RealtimeDiarizationManager else { return }

        pendingExtractions.insert(key)
        let asr = entry.asr

        Task { @MainActor [weak self] in
            guard let self else { return }
            let embedding = await manager.extractEmbedding(
                startTime: asr.start, endTime: asr.end
            )
            self.pendingExtractions.remove(key)

            if embedding.isEmpty {
                let attempt = self.extractionAttempts[key, default: 0]
                if attempt >= self.maxExtractionRetries {
                    self.logger.info("[MERGE] Embedding extraction failed after \(attempt) attempts for \(asr.stream.rawValue) [\(String(format: "%.1f", asr.start))s-\(String(format: "%.1f", asr.end))s]")
                } else {
                    self.logger.info("[MERGE] Embedding extraction empty for \(asr.stream.rawValue) [\(String(format: "%.1f", asr.start))s-\(String(format: "%.1f", asr.end))s], will retry (\(attempt)/\(self.maxExtractionRetries))")
                }
            } else {
                self.completedEmbeddings[key] = embedding
            }
            self.scheduleMerge()
        }
    }

    // MARK: - Collapse & Helpers

    private func collapseAdjacentSegments(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [TaggedSegment] = []
        let maxGap: TimeInterval = 1.5

        for segment in sorted {
            if var last = result.last,
               last.speaker == segment.speaker,
               last.stream == segment.stream,
               last.speaker != "Speaker-?",   // Never collapse unattributed placeholders
               segment.start - last.end < maxGap {
                last.end = max(last.end, segment.end)
                if !segment.text.isEmpty {
                    last.text = last.text.isEmpty ? segment.text : last.text + " " + segment.text
                }
                // Merge word timings from collapsed segments
                if !segment.wordTimings.isEmpty {
                    last.wordTimings += segment.wordTimings
                }
                last.isFinal = segment.isFinal
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private func resolveASR(_ asr: ASRSegment) -> (index: Int, segment: TaggedSegment)? {
        let candidates = diarizationSegments.enumerated().filter {
            $0.element.stream == asr.stream && overlapDuration($0.element, asr) >= minOverlapThreshold
        }
        guard let best = candidates.max(by: { a, b in
            overlapDuration(a.element, asr) < overlapDuration(b.element, asr)
        }) else { return nil }
        return (index: best.offset, segment: best.element)
    }

    private func commitResolved(asr: ASRSegment, match: (index: Int, segment: TaggedSegment)) {
        let (index, matched) = match
        let asrStart = String(format: "%.1f", asr.start)
        let asrEnd = String(format: "%.1f", asr.end)
        let overlap = String(format: "%.2f", overlapDuration(matched, asr))
        let ms = String(format: "%.1f", matched.start)
        let me = String(format: "%.1f", matched.end)
        logger.info("[MERGE] \(asr.stream.rawValue) [\(asrStart)s-\(asrEnd)s] → \(matched.speaker) [\(ms)s-\(me)s] overlap=\(overlap)s: \"\(asr.text)\"")

        if diarizationSegments[index].text.isEmpty {
            diarizationSegments[index].text = asr.text
            diarizationSegments[index].isFinal = true
            diarizationSegments[index].wordTimings = asr.wordTimings
        } else {
            let extra = TaggedSegment(
                stream: asr.stream, speaker: matched.speaker,
                start: asr.start, end: asr.end,
                text: asr.text, embedding: matched.embedding, isFinal: true,
                wordTimings: asr.wordTimings
            )
            diarizationSegments.append(extra)
        }

        // Update registry
        updateRegistry(speaker: matched.speaker, stream: asr.stream,
                       embedding: matched.embedding, duration: asr.end - asr.start)
    }

    private func overlapDuration(_ diar: TaggedSegment, _ asr: ASRSegment) -> TimeInterval {
        let overlapStart = max(diar.start, asr.start)
        let overlapEnd = min(diar.end, asr.end)
        return max(0, overlapEnd - overlapStart)
    }

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

    // MARK: - Flush (end-of-recording)

    /// Stop the merge and refinement timers immediately.
    /// Called before pipeline teardown to prevent the 30s timeout from
    /// committing segments as Speaker-? while diarization still has data to process.
    public func stopTimers() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        refinementTimer?.invalidate()
        refinementTimer = nil
    }

    /// Final resolution pass before saving the transcript.
    ///
    /// Called after all pipelines are stopped (ASR has emitted its final segments).
    /// Processes remaining deferred ASR finals, unattributed segments, and runs
    /// a last refinement pass.
    public func flushUnattributed() {
        // Stop new extraction requests — extractors are being torn down.
        extractionsStopped = true

        // Stop the refinement timer — we'll run one final pass manually.
        refinementTimer?.invalidate()
        refinementTimer = nil

        // Process any remaining deferred ASR finals (never got diarization segments).
        // Move them to unattributed so they can be resolved or committed as Speaker-?.
        for asr in finalASRBuffer {
            if let resolved = resolveASR(asr) {
                commitResolved(asr: asr, match: resolved)
            } else {
                let entry = UnattributedEntry(asr: asr, addedAt: Date())
                unattributedASR.append(entry)
            }
        }
        finalASRBuffer.removeAll()

        // Run a final refinement pass with the complete data
        performRefinement()

        // Resolve any remaining unattributed
        for entry in unattributedASR {
            let key = entry.asr.start

            // Try completed embedding
            if let embedding = completedEmbeddings.removeValue(forKey: key),
               let speaker = matchAgainstRegistry(embedding, stream: entry.asr.stream) {
                let ts = String(format: "%.1f", entry.asr.start)
                let te = String(format: "%.1f", entry.asr.end)
                logger.info("[MERGE] \(entry.asr.stream.rawValue) [\(ts)s-\(te)s] → '\(speaker.name)' (flush embedding \(String(format: "%.3f", speaker.similarity))): \"\(entry.asr.text)\"")
                let seg = TaggedSegment(
                    stream: entry.asr.stream, speaker: speaker.name,
                    start: entry.asr.start, end: entry.asr.end,
                    text: entry.asr.text, embedding: embedding, isFinal: true,
                    wordTimings: entry.asr.wordTimings
                )
                diarizationSegments.append(seg)
            } else if let match = resolveASR(entry.asr) {
                commitResolved(asr: entry.asr, match: match)
            } else {
                // Permanent Speaker-? — will be resolved by post-recording refinement
                let ts = String(format: "%.1f", entry.asr.start)
                let te = String(format: "%.1f", entry.asr.end)
                logger.info("[MERGE] \(entry.asr.stream.rawValue) [\(ts)s-\(te)s] → 'Speaker-?' (flush): \"\(entry.asr.text)\"")
                let seg = TaggedSegment(
                    stream: entry.asr.stream, speaker: "Speaker-?",
                    start: entry.asr.start, end: entry.asr.end,
                    text: entry.asr.text, isFinal: true,
                    wordTimings: entry.asr.wordTimings
                )
                diarizationSegments.append(seg)
            }
        }
        unattributedASR.removeAll()
        pendingExtractions.removeAll()
        extractionAttempts.removeAll()
        completedEmbeddings.removeAll()

        buildOutput()
    }

    // MARK: - Reset

    public func reset() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        refinementTimer?.invalidate()
        refinementTimer = nil
        diarizationSegments.removeAll()
        finalASRBuffer.removeAll()
        unattributedASR.removeAll()
        pendingExtractions.removeAll()
        extractionAttempts.removeAll()
        extractionsStopped = false
        completedEmbeddings.removeAll()
        livePartials.removeAll()
        mergedSegments.removeAll()
        speakerRegistry.removeAll()
        speakerRenames.removeAll()
        identifiedSpeakers.removeAll()
        speakerDurations.removeAll()
        _diarizationManagers.removeAll()
    }
}
