import Foundation
import OSLog

/// Manages the two-phase meeting intelligence pipeline:
///
/// 1. **Ingest**: POST transcript to `/v1/ingest/meeting` so the agent builds
///    a knowledge graph (participants, topics, decisions, etc.)
/// 2. **Summarize**: Send a message to the chat agent asking for a structured
///    Markdown summary. The response is saved as `summary.blocknote` in the
///    meeting folder.
///
/// State is persisted per-meeting via `ingested.json` in the meeting folder.
/// This ensures the ingest button becomes "Meeting Ingested" across app restarts.
///
/// All state transitions are published on `@MainActor` so the UI always has
/// immediate visual feedback — no phase should leave the user wondering.
@MainActor
public final class MeetingIngestService: ObservableObject {

    // MARK: - Published State

    /// The current phase of the ingest + summarize pipeline.
    @Published public var state: IngestState = .idle

    /// Human-readable status message for the current phase.
    @Published public var statusMessage: String = ""

    /// Error message (non-nil only in .failed state).
    @Published public var errorMessage: String?

    /// Whether a summary.blocknote file exists for the current meeting.
    @Published public var hasSummary: Bool = false

    /// Whether the meeting has already been ingested (persisted on disk).
    @Published public var isIngested: Bool = false

    // MARK: - State Machine

    public enum IngestState: Equatable {
        /// No operation in progress.
        case idle
        /// Sending transcript to /v1/ingest/meeting.
        case ingesting
        /// Ingest succeeded; now requesting summary from chat agent.
        case summarizing
        /// Summary received and saved. Pipeline complete.
        case complete
        /// An error occurred. `errorMessage` has details.
        case failed
    }

    // MARK: - Persisted Metadata

    /// On-disk record that this meeting has been ingested.
    /// Stored as `ingested.json` in the meeting folder.
    public struct IngestMetadata: Codable {
        let ingestedAt: Date
        let summaryGenerated: Bool
    }

    public init() {}

    // MARK: - Private

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MeetingIngest")
    private var currentMeeting: SavedMeeting?
    private var pipelineTask: Task<Void, Never>?

    // MARK: - Load State for a Meeting

    /// Call when navigating to a meeting to restore persisted ingest state.
    public func loadState(for meeting: SavedMeeting) {
        currentMeeting = meeting
        errorMessage = nil

        // Check for existing ingested.json
        let metadataURL = meeting.folderURL.appendingPathComponent("ingested.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaryExists = summaryFileExists(for: meeting)
        if let data = try? Data(contentsOf: metadataURL),
           let metadata = try? decoder.decode(IngestMetadata.self, from: data) {
            isIngested = true
            hasSummary = metadata.summaryGenerated || summaryExists
        } else {
            // If summary.json exists, the meeting was ingested even if
            // ingested.json is missing or corrupt.
            isIngested = summaryExists
            hasSummary = summaryExists
        }

        // Reset operational state
        if state != .ingesting && state != .summarizing {
            state = .idle
            statusMessage = ""
        }
    }

    // MARK: - Ingest + Summarize Pipeline

    /// Run the full pipeline: ingest the transcript, then request a summary.
    /// The UI observes `state` and `statusMessage` for real-time feedback.
    public func ingestAndSummarize(meeting: SavedMeeting, entries: [TranscriptEntry]) {
        guard state == .idle || state == .failed else {
            logger.warning("ingestAndSummarize called while already in state: \(String(describing: self.state))")
            return
        }
        guard KeychainManager.shared.hasAPIKey else {
            state = .failed
            errorMessage = "No API key configured. Open Settings to add one."
            return
        }

        currentMeeting = meeting
        errorMessage = nil

        // Use a stored task so we can cancel if needed.
        pipelineTask?.cancel()
        pipelineTask = Task {
            // Quick reachability check — fail fast instead of hanging.
            let service = StreamingChatService.shared
            guard let probeURL = URL(string: service.baseURL) else {
                state = .failed
                errorMessage = "Invalid API endpoint URL. Check Settings."
                return
            }
            do {
                statusMessage = "Connecting to server..."
                state = .ingesting
                var probeReq = URLRequest(url: probeURL)
                probeReq.httpMethod = "HEAD"
                probeReq.timeoutInterval = 8
                _ = try await URLSession.shared.data(for: probeReq)
            } catch {
                state = .failed
                errorMessage = "Cannot reach server: \(error.localizedDescription)"
                statusMessage = ""
                logger.error("Server reachability check failed: \(error)")
                return
            }

            guard !Task.isCancelled else { return }

            // Phase 1: Ingest
            statusMessage = "Sending transcript to Dialogue AI..."

            do {
                try await performIngest(meeting: meeting, entries: entries)
            } catch {
                state = .failed
                errorMessage = "Ingest failed: \(error.localizedDescription)"
                statusMessage = ""
                logger.error("Ingest failed: \(error.localizedDescription)")
                return
            }

            guard !Task.isCancelled else { return }

            // Mark as ingested on disk
            isIngested = true
            persistIngestMetadata(for: meeting, summaryGenerated: false)
            statusMessage = "Transcript ingested. Generating summary..."

            // Phase 2: Summarize
            state = .summarizing

            do {
                let markdown = try await requestSummary(meeting: meeting, entries: entries)

                guard !Task.isCancelled else { return }

                statusMessage = "Saving summary..."

                // Save as summary.blocknote
                try saveSummaryAsBlockNote(markdown: markdown, meeting: meeting)
                hasSummary = true
                persistIngestMetadata(for: meeting, summaryGenerated: true)

                state = .complete
                statusMessage = "Summary ready"
                logger.info("Meeting summary saved for \(meeting.displayName)")

                // Auto-reset status message after a few seconds
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if state == .complete {
                    statusMessage = ""
                }
            } catch {
                // Ingest succeeded but summary failed — don't lose the ingest state
                state = .failed
                errorMessage = "Summary failed: \(error.localizedDescription)"
                statusMessage = ""
                logger.error("Summary failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Phase 1: Ingest

    private func performIngest(meeting: SavedMeeting, entries: [TranscriptEntry]) async throws {
        let service = StreamingChatService.shared

        // Build the transcript as plain text with speaker labels and timestamps
        let sortedEntries = entries.sorted { $0.start < $1.start }
        let transcriptText = sortedEntries.map { entry in
            let minutes = Int(entry.start) / 60
            let seconds = Int(entry.start) % 60
            return String(format: "%d:%02d %@: %@", minutes, seconds, entry.speaker, entry.text)
        }.joined(separator: "\n\n")

        // Extract unique participants
        let uniqueSpeakers = Array(Set(entries.map(\.speaker))).sorted()
        let participants = uniqueSpeakers.map { speaker -> [String: Any] in
            ["name": speaker]
        }

        // Calculate duration
        let startTime = entries.map(\.start).min() ?? 0
        let endTime = entries.map(\.end).max() ?? 0
        let durationSeconds = endTime - startTime

        // Build the ingest payload
        let payload: [String: Any] = [
            "title": meeting.displayName,
            "transcript": transcriptText,
            "participants": participants,
            "durationSeconds": durationSeconds,
            "sourceApp": "Dialogue",
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw IngestError.payloadSerializationFailed
        }

        let baseURL = service.baseURL
        guard let url = URL(string: "\(baseURL)/ingest/meeting") else {
            throw IngestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body

        // Auth headers
        if let key = try? KeychainManager.shared.getAPIKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw IngestError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw IngestError.httpError(statusCode: http.statusCode, body: body)
        }

        logger.info("Meeting ingested successfully: \(meeting.displayName)")
    }

    // MARK: - Phase 2: Summarize

    private func requestSummary(meeting: SavedMeeting, entries: [TranscriptEntry]) async throws -> String {
        let service = StreamingChatService.shared
        let agentId = UserDefaults.standard.string(forKey: "chatAgentId") ?? "chieko"

        // Build the transcript for the prompt
        let sortedEntries = entries.sorted { $0.start < $1.start }
        let transcriptText = sortedEntries.map { entry in
            let minutes = Int(entry.start) / 60
            let seconds = Int(entry.start) % 60
            return String(format: "%d:%02d %@: %@", minutes, seconds, entry.speaker, entry.text)
        }.joined(separator: "\n\n")

        // Start a new session for the summary request
        let startResponse = try await service.startSession(agentId: agentId)
        let sessionId = startResponse.sessionId

        // Wait for session to become ready (poll up to 30s).
        // Individual poll failures are retried — only consecutive failures cause abort.
        var sessionReady = false
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 3
        for _ in 0..<30 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                let status = try await service.getSessionStatus(agentId: agentId, sessionId: sessionId)
                consecutiveErrors = 0
                if status.status == "running" || status.status == "ready" {
                    sessionReady = true
                    break
                }
                if status.status == "failed" {
                    throw IngestError.sessionFailed
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as IngestError {
                throw error // Re-throw our own errors (sessionFailed)
            } catch {
                consecutiveErrors += 1
                logger.warning("Status poll error (\(consecutiveErrors)/\(maxConsecutiveErrors)): \(error.localizedDescription)")
                if consecutiveErrors >= maxConsecutiveErrors {
                    throw IngestError.serverUnreachable
                }
            }
        }

        guard sessionReady else {
            throw IngestError.sessionTimeout
        }

        // Send the summary request.
        // The prompt instructs the agent to use GitHub Flavored Markdown that
        // BlockNote's tryParseMarkdownToBlocks() can parse into interactive blocks:
        // - Headings (#, ##, ###) → heading blocks
        // - Bullet lists (- item) → bullet list blocks
        // - Task lists (- [ ] / - [x]) → interactive checkbox blocks
        // - Bold (**text**) and italic (*text*) → inline styles
        // - Blockquotes (> text) → blockquote blocks
        // - Tables (| col | col |) → table blocks
        // - Numbered lists (1. item) → numbered list blocks
        let prompt = """
        Below is the complete transcript of a meeting titled "\(meeting.displayName)".

        Provide a comprehensive meeting summary in GitHub Flavored Markdown. The output will be rendered in an interactive block editor, so use the following formatting:

        ## Structure

        Use these sections with ## headings:

        ## Meeting Overview
        A brief 2-3 sentence summary of what the meeting was about.

        ## Participants
        Bullet list of who was in the meeting and their role/context if apparent.

        ## Key Discussion Points
        Use ### sub-headings for each major topic. Under each, write a concise summary of what was discussed.

        ## Decisions Made
        Bullet list of decisions that were reached. Use **bold** for the decision itself.

        ## Action Items
        Use task list checkboxes so the user can track completion:
        - [ ] Task description — @person (if identifiable)
        - [ ] Another task — @person

        IMPORTANT: Task list items MUST have a space between the brackets: "- [ ]" not "- []".

        ## Follow-ups
        Use task list checkboxes for items that need follow-up:
        - [ ] Follow-up item
        - [ ] Deferred item

        ## Formatting Rules
        - Return ONLY the Markdown content. No code fences wrapping the output. No preamble.
        - Use **bold** for emphasis on key terms, decisions, and names.
        - Use bullet lists (- item) for simple lists.
        - Use numbered lists (1. item) for ordered sequences.
        - Use task lists (- [ ] item) for anything actionable — these become interactive checkboxes.
        - Use ### sub-headings to break up long sections.
        - Keep it concise but comprehensive. Every substantive point from the meeting should be captured.

        ---
        FULL MEETING TRANSCRIPT:

        \(transcriptText)
        """

        let sendResponse = try await service.sendMessage(
            agentId: agentId,
            sessionId: sessionId,
            message: prompt
        )
        _ = sendResponse

        // Collect the full response via SSE
        let markdown = try await collectSSEResponse(sessionId: sessionId, service: service)

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestError.emptySummary
        }

        return markdown
    }

    /// Connect to the SSE stream and collect the full assistant response.
    /// Updates `statusMessage` with streaming progress so the user sees activity.
    ///
    /// Has a 5-minute overall timeout to prevent hanging if the server stalls.
    /// The SSEStreamDelegate now properly finishes the AsyncStream on connection
    /// close, but the timeout is a safety net.
    private func collectSSEResponse(sessionId: String, service: StreamingChatService) async throws -> String {
        // Wrap the SSE collection in a timeout task.
        let timeoutSeconds: UInt64 = 300 // 5 minutes
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor @Sendable [weak self] in
                var fullText = ""
                var receivedTurnEnd = false
                var wordCount = 0

                let stream = service.connectSSE(sessionId: sessionId)

                for await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let text):
                        fullText += text
                        let newWords = text.split(whereSeparator: \.isWhitespace).count
                        wordCount += newWords
                        if wordCount % 10 == 0 || newWords > 0 {
                            self?.statusMessage = "Generating summary... (\(wordCount) words)"
                        }

                    case .turnEnd:
                        receivedTurnEnd = true

                    case .sessionComplete:
                        receivedTurnEnd = true

                    case .error(let message):
                        throw IngestError.sseError(message)

                    case .responseAborted:
                        throw IngestError.responseAborted

                    default:
                        break
                    }

                    if receivedTurnEnd { break }
                }

                service.disconnectSSE()
                return fullText
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw IngestError.summaryTimeout
            }

            // Return whichever finishes first; cancel the other.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Save Summary as BlockNote

    /// Convert markdown to a BlockNote file structure and save to the meeting folder.
    ///
    /// Strategy: We build a simple BlockNote document with paragraphs from the markdown.
    /// The proper markdown-to-blocks conversion happens at display time via the
    /// `tryParseMarkdownToBlocks` JS bridge in the summary view.
    /// Here we store the raw markdown so it can be converted when displayed.
    private func saveSummaryAsBlockNote(markdown: String, meeting: SavedMeeting) throws {
        // Store the raw markdown in a simple wrapper format that our summary view
        // can detect and convert via the JS bridge at display time.
        let summaryData: [String: Any] = [
            "version": 1,
            "format": "markdown",
            "content": markdown,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: summaryData, options: [.prettyPrinted, .sortedKeys]) else {
            throw IngestError.payloadSerializationFailed
        }

        let summaryURL = meeting.folderURL.appendingPathComponent("summary.json")
        try data.write(to: summaryURL, options: .atomic)
    }

    // MARK: - Persistence Helpers

    private func persistIngestMetadata(for meeting: SavedMeeting, summaryGenerated: Bool) {
        let metadata = IngestMetadata(
            ingestedAt: Date(),
            summaryGenerated: summaryGenerated
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(metadata) else { return }

        let url = meeting.folderURL.appendingPathComponent("ingested.json")
        try? data.write(to: url, options: .atomic)
    }

    private func summaryFileExists(for meeting: SavedMeeting) -> Bool {
        FileManager.default.fileExists(
            atPath: meeting.folderURL.appendingPathComponent("summary.json").path
        )
    }

    /// Load the raw markdown from the summary.json file.
    public static func loadSummaryMarkdown(for meeting: SavedMeeting) -> String? {
        let url = meeting.folderURL.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return nil
        }
        return content
    }

    // MARK: - Errors

    public enum IngestError: Error, LocalizedError {
        case payloadSerializationFailed
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int, body: String)
        case serverUnreachable
        case sessionFailed
        case sessionTimeout
        case summaryTimeout
        case emptySummary
        case sseError(String)
        case responseAborted

        public var errorDescription: String? {
            switch self {
            case .payloadSerializationFailed:
                return "Failed to build the ingest payload"
            case .invalidURL:
                return "Invalid API endpoint URL. Check Settings."
            case .invalidResponse:
                return "Invalid response from the server"
            case .httpError(let code, let body):
                if code == 401 { return "Unauthorized (401) — check your API key" }
                if code == 404 { return "Endpoint not found (404) — check your server URL" }
                return "HTTP \(code): \(body.prefix(200))"
            case .serverUnreachable:
                return "Server is not responding. Check that the Djinn server is running."
            case .sessionFailed:
                return "Chat session failed to start"
            case .sessionTimeout:
                return "Chat session timed out waiting to become ready"
            case .summaryTimeout:
                return "Summary generation timed out after 5 minutes"
            case .emptySummary:
                return "The AI returned an empty summary"
            case .sseError(let msg):
                return "Stream error: \(msg)"
            case .responseAborted:
                return "The response was aborted"
            }
        }
    }
}
