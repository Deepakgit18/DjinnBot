import Foundation
import SwiftData

// MARK: - Persistent Speaker Profile (SwiftData)

/// Cross-session speaker profile stored via SwiftData.
///
/// Embeddings are averaged over multiple meetings so the system
/// can recognise recurring speakers (e.g. "Alice" in every standup).
@Model
final class SpeakerProfile {
    @Attribute(.unique) var speakerID: String
    var displayName: String
    var embedding: [Float]
    var sampleCount: Int
    var lastSeenDate: Date
    var createdDate: Date

    init(
        speakerID: String,
        displayName: String = "",
        embedding: [Float],
        sampleCount: Int = 1,
        lastSeenDate: Date = .now,
        createdDate: Date = .now
    ) {
        self.speakerID = speakerID
        self.displayName = displayName.isEmpty ? speakerID : displayName
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.lastSeenDate = lastSeenDate
        self.createdDate = createdDate
    }

    /// Incrementally update the running-average embedding with a new observation.
    func updateEmbedding(with newEmbedding: [Float]) {
        guard newEmbedding.count == embedding.count else { return }
        let n = Float(sampleCount)
        let n1 = Float(sampleCount + 1)
        for i in embedding.indices {
            embedding[i] = (embedding[i] * n + newEmbedding[i]) / n1
        }
        sampleCount += 1
        lastSeenDate = .now
    }

    /// Cosine similarity between this profile and a candidate embedding.
    func cosineSimilarity(with other: [Float]) -> Float {
        guard other.count == embedding.count, !embedding.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in embedding.indices {
            dot += embedding[i] * other[i]
            magA += embedding[i] * embedding[i]
            magB += other[i] * other[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}

// MARK: - Speaker Profile Store

/// Manages cross-session speaker lookup and persistence via SwiftData.
///
/// Provides methods to:
/// - Resolve a speaker profile from an embedding (find-or-create)
/// - Load all profiles as FluidAudio `Speaker` objects for `SpeakerManager`
/// - Save/update profiles from post-recording speaker data
actor SpeakerProfileStore {

    /// Shared singleton. `nil` if SwiftData container initialisation failed.
    static let shared: SpeakerProfileStore? = try? SpeakerProfileStore()

    /// The single shared `ModelContainer`. Exposed so views can use the
    /// same container (creating multiple containers for the same schema
    /// causes SwiftData to invalidate model objects).
    let modelContainer: ModelContainer
    private let matchThreshold: Float = 0.75

    init() throws {
        let schema = Schema([SpeakerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        self.modelContainer = try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Resolve (Find or Create)

    /// Find or create a speaker profile matching the given embedding.
    @MainActor
    func resolveProfile(for embedding: [Float], streamPrefix: String) throws -> SpeakerProfile {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SpeakerProfile>(
            sortBy: [SortDescriptor(\.lastSeenDate, order: .reverse)]
        )
        let existing = try context.fetch(descriptor)

        // Find best match above threshold
        var bestMatch: SpeakerProfile?
        var bestScore: Float = matchThreshold
        for profile in existing {
            let score = profile.cosineSimilarity(with: embedding)
            if score > bestScore {
                bestScore = score
                bestMatch = profile
            }
        }

        if let match = bestMatch {
            match.updateEmbedding(with: embedding)
            try context.save()
            return match
        }

        // Create new profile
        let newID = "\(streamPrefix)-Speaker\(existing.count + 1)"
        let profile = SpeakerProfile(speakerID: newID, embedding: embedding)
        context.insert(profile)
        try context.save()
        return profile
    }

    // MARK: - Save / Update from FluidAudio Speaker Data

    /// Save or update a profile from post-recording speaker data.
    ///
    /// If a profile with a matching `speakerID` exists, its embedding is
    /// updated via running average. Otherwise a new profile is created.
    ///
    /// - Parameters:
    ///   - speakerId: Unique speaker identifier (from FluidAudio `Speaker.id`)
    ///   - displayName: Human-readable name (from `Speaker.name`)
    ///   - embedding: 256-d L2-normalised embedding
    @MainActor
    func saveOrUpdateProfile(speakerId: String, displayName: String, embedding: [Float]) throws {
        guard !embedding.isEmpty else { return }

        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SpeakerProfile>(
            sortBy: [SortDescriptor(\.lastSeenDate, order: .reverse)]
        )
        let allProfiles = try context.fetch(descriptor)

        // Check for exact ID match first
        if let existing = allProfiles.first(where: { $0.speakerID == speakerId }) {
            existing.updateEmbedding(with: embedding)
            if !displayName.isEmpty, displayName != speakerId {
                existing.displayName = displayName
            }
            try context.save()
            return
        }

        // Check for embedding similarity match (speaker may have been renamed)
        if let similar = allProfiles.first(where: { $0.cosineSimilarity(with: embedding) > matchThreshold }) {
            similar.updateEmbedding(with: embedding)
            try context.save()
            return
        }

        // Create new profile
        let profile = SpeakerProfile(
            speakerID: speakerId,
            displayName: displayName.isEmpty ? speakerId : displayName,
            embedding: embedding
        )
        context.insert(profile)
        try context.save()
    }

}
