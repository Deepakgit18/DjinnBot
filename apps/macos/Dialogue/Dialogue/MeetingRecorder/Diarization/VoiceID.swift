// VoiceID.swift
// Independent WeSpeaker Voice Identification for MergeEngine
// FluidAudio DiarizerManager (WeSpeaker ResNet34-LM 256-dim) – fully offline, ANE-accelerated

import Accelerate
import FluidAudio
import Foundation
import OSLog

// MARK: - Error

public enum VoiceIDError: Error, LocalizedError {
    case noAudioClips
    case embeddingFailed
    case storageFailed
    case invalidAudio
    case modelsNotLoaded

    public var errorDescription: String? {
        switch self {
        case .noAudioClips: return "No audio clips for enrollment"
        case .embeddingFailed: return "Embedding extraction failed"
        case .storageFailed: return "Failed to save enrolled voices"
        case .invalidAudio: return "Audio must be 16 kHz mono [Float]"
        case .modelsNotLoaded: return "Diarizer models not loaded — call prepare() first"
        }
    }
}

// MARK: - Voice Embedding

public struct VoiceEmbedding: Codable, Equatable, Identifiable {
    public let id: UUID
    public let userID: String
    public let vector: [Float]      // 256-dim, L2-normalized
    public let enrolledAt: Date
    public let clipCount: Int

    public init(userID: String, vector: [Float], clipCount: Int) {
        self.id = UUID()
        self.userID = userID
        self.vector = vector
        self.enrolledAt = Date()
        self.clipCount = clipCount
    }
}

// MARK: - Delegate

public protocol VoiceIDDelegate: AnyObject {
    func voiceID(_ voiceID: VoiceID, didDetectNewSpeaker embedding: [Float], suggestedUserID: String)
}

// MARK: - VoiceID

/// Standalone speaker identification module backed by FluidAudio's
/// `DiarizerManager` (Pyannote segmentation + WeSpeaker embedding, 256-dim).
///
/// All speaker identification flows through this class:
/// - **Enrollment**: record 3 x 10-second clips, extract & average embeddings.
/// - **Identification**: compare a pre-extracted embedding against enrolled
///   voices via cosine similarity, or extract an embedding from raw audio
///   using the full diarization pipeline.
/// - **Storage**: enrolled voices are persisted as JSON in Application Support.
///
/// `MergeEngine` calls `identifySpeaker(fromEmbedding:)` on each diarization
/// segment to resolve auto-generated speaker labels to enrolled user IDs.
public final class VoiceID {

    public static let shared = VoiceID()
    public weak var delegate: VoiceIDDelegate?

    /// The diarizer used for embedding extraction during enrollment.
    /// Lazily prepared via `prepare()`.
    private var diarizer: DiarizerManager?

    private var enrolledVoices: [String: VoiceEmbedding] = [:]
    private let storageURL: URL
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "VoiceID")

    /// Cosine similarity threshold for a positive match.
    /// Range 0.50–0.90; default 0.65. Configurable in Settings.
    public var similarityThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "voiceID_similarityThreshold")).nonZeroOrDefault(0.65) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "voiceID_similarityThreshold") }
    }

    /// Clustering threshold passed to DiarizerConfig during enrollment embedding extraction.
    /// Range 0.50–0.90; default 0.65. Configurable in Settings.
    public var clusteringThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "voiceID_clusteringThreshold")).nonZeroOrDefault(0.65) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "voiceID_clusteringThreshold") }
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DjinnBot/VoiceID", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("enrolledVoices.json")
        loadFromDisk()
        logger.info("VoiceID initialised with \(self.enrolledVoices.count) enrolled voice(s)")
    }

    // MARK: - Model Preparation

    /// Prepare the DiarizerManager for embedding extraction.
    ///
    /// Reuses models from `ModelPreloader` when available, otherwise
    /// downloads from HuggingFace. Call before the first enrollment.
    /// Not needed for `identifySpeaker(fromEmbedding:)` which only
    /// does vector math.
    public func prepare() async throws {
        guard diarizer == nil else { return }

        let models: DiarizerModels

        if let preloaded = await MainActor.run(body: { ModelPreloader.shared.diarizerModels }) {
            models = preloaded
        } else {
            models = try await DiarizerModels.downloadIfNeeded()
        }

        let config = DiarizerConfig(
            clusteringThreshold: clusteringThreshold,
            minSpeechDuration: 1.0,
            minSilenceGap: 0.5,
            debugMode: true,
            chunkDuration: 10.0
        )
        let mgr = DiarizerManager(config: config)
        mgr.initialize(models: models)
        self.diarizer = mgr

        logger.info("VoiceID diarizer prepared for embedding extraction")
    }

    /// Release the diarizer models (e.g. on memory pressure).
    /// Enrolled voices are retained.
    public func releaseDiarizer() {
        diarizer?.cleanup()
        diarizer = nil
    }

    // MARK: - Public API

    /// Identify a speaker from a diarized audio chunk.
    ///
    /// Runs the full diarization pipeline to extract a 256-d WeSpeaker
    /// embedding, then compares against enrolled voices. Requires
    /// `prepare()` to have been called first.
    ///
    /// For real-time use where embeddings are already available from
    /// the diarization pipeline, prefer `identifySpeaker(fromEmbedding:)`.
    ///
    /// - Parameter audioChunk: 16 kHz mono Float32 samples.
    /// - Returns: `(userID, similarity)` — userID is nil if unrecognised.
    public func identifySpeaker(from audioChunk: [Float]) async -> (userID: String?, similarity: Float) {
        guard !audioChunk.isEmpty else { return (nil, 0) }
        do {
            let query = try extractEmbedding(from: audioChunk)
            return findBestMatch(query)
        } catch {
            logger.error("identifySpeaker failed: \(error.localizedDescription)")
            return (nil, 0)
        }
    }

    /// Identify a speaker from a pre-extracted embedding vector.
    ///
    /// Use this overload when the diarization pipeline already provides
    /// per-segment embeddings (e.g. Pyannote `speakerDatabase`), avoiding
    /// a redundant diarization pass. Does not require `prepare()`.
    ///
    /// - Parameter embedding: L2-normalised 256-d vector.
    /// - Returns: `(userID, similarity)` — userID is nil if unrecognised.
    public func identifySpeaker(fromEmbedding embedding: [Float]) -> (userID: String?, similarity: Float) {
        guard !embedding.isEmpty else { return (nil, 0) }
        return findBestMatch(embedding)
    }

    /// Enroll a speaker from multiple audio clips.
    ///
    /// Each clip should be ~10 seconds of clear solo speech at 16 kHz mono.
    /// Embeddings are extracted independently via `DiarizerManager` and
    /// averaged for robustness. Requires `prepare()` to have been called.
    ///
    /// - Parameters:
    ///   - userID: Unique identifier for this speaker.
    ///   - audioClips: One or more 16 kHz mono Float32 audio clips.
    /// - Returns: The persisted `VoiceEmbedding`.
    @discardableResult
    public func enroll(userID: String, audioClips: [[Float]]) async throws -> VoiceEmbedding {
        guard !audioClips.isEmpty else { throw VoiceIDError.noAudioClips }

        var vectors: [[Float]] = []
        for clip in audioClips {
            let vec = try extractEmbedding(from: clip)
            vectors.append(vec)
        }

        let averaged = averageVectors(vectors)
        let embedding = VoiceEmbedding(userID: userID, vector: averaged, clipCount: audioClips.count)
        enrolledVoices[userID] = embedding
        saveToDisk()

        logger.info("Enrolled '\(userID)' from \(audioClips.count) clip(s)")
        return embedding
    }

    /// Remove an enrolled voice.
    public func remove(userID: String) {
        enrolledVoices.removeValue(forKey: userID)
        saveToDisk()
        logger.info("Removed enrolled voice '\(userID)'")
    }

    /// All enrolled voices, sorted most-recently-enrolled first.
    public func allEnrolledVoices() -> [VoiceEmbedding] {
        Array(enrolledVoices.values).sorted { $0.enrolledAt > $1.enrolledAt }
    }

    /// Whether any voices are enrolled.
    public var hasEnrolledVoices: Bool {
        !enrolledVoices.isEmpty
    }

    // MARK: - Embedding Extraction

    /// Extract a 256-d L2-normalised embedding from raw audio using the
    /// full DiarizerManager pipeline (segmentation + WeSpeaker).
    ///
    /// The clip is expected to contain a single speaker. The first
    /// (dominant) speaker's embedding is returned from
    /// `DiarizationResult.speakerDatabase`.
    ///
    /// - Parameter audio: 16 kHz mono Float32 samples (>= 3 seconds).
    /// - Returns: 256-element normalised vector.
    private func extractEmbedding(from audio: [Float]) throws -> [Float] {
        guard !audio.isEmpty else { throw VoiceIDError.invalidAudio }
        guard let diarizer else { throw VoiceIDError.modelsNotLoaded }

        let result = try diarizer.performCompleteDiarization(audio)

        // Primary: get embedding from speakerDatabase (populated when debugMode=true)
        if let db = result.speakerDatabase, let firstEntry = db.values.first {
            guard firstEntry.count == 256 else { throw VoiceIDError.embeddingFailed }
            return normalizeL2(firstEntry)
        }

        // Fallback: get embedding from SpeakerManager
        let speakers = diarizer.speakerManager.getAllSpeakers()
        if let firstSpeaker = speakers.values.first {
            let emb = firstSpeaker.currentEmbedding
            if emb.count == 256 {
                return normalizeL2(emb)
            }
        }

        throw VoiceIDError.embeddingFailed
    }

    // MARK: - Private — Vector Math (Accelerate)

    private func normalizeL2(_ vector: [Float]) -> [Float] {
        var output = vector
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        var mag = sqrt(sumSq)
        if mag > 1e-6 {
            vDSP_vsdiv(vector, 1, &mag, &output, 1, vDSP_Length(vector.count))
        }
        return output
    }

    private func averageVectors(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            vDSP_vadd(v, 1, sum, 1, &sum, 1, vDSP_Length(first.count))
        }
        var countF = Float(vectors.count)
        vDSP_vsdiv(sum, 1, &countF, &sum, 1, vDSP_Length(first.count))
        return normalizeL2(sum)
    }

    private func findBestMatch(_ query: [Float]) -> (userID: String?, similarity: Float) {
        var best: Float = -1
        var bestID: String?
        for (id, emb) in enrolledVoices {
            let score = cosineSimilarity(query, emb.vector)
            if score > best {
                best = score
                bestID = id
            }
        }
        if best >= similarityThreshold {
            return (bestID, best)
        } else {
            delegate?.voiceID(self, didDetectNewSpeaker: query, suggestedUserID: "speaker_\(UUID().uuidString.prefix(8))")
            return (nil, best)
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA * normB)
        return denom > 1e-6 ? dot / denom : 0
    }

    // MARK: - Private — Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([String: VoiceEmbedding].self, from: data) else { return }
        enrolledVoices = loaded
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(enrolledVoices)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to persist enrolled voices: \(error.localizedDescription)")
        }
    }
}

// MARK: - Float helper

private extension Float {
    /// Returns `self` when non-zero, otherwise `fallback`.
    /// Handles the case where UserDefaults returns 0 for an unset key.
    func nonZeroOrDefault(_ fallback: Float) -> Float {
        self == 0 ? fallback : self
    }
}
