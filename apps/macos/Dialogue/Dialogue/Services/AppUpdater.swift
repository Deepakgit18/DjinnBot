import Foundation
import os.log
import SwiftUI

// MARK: - AppUpdater

/// Checks GitHub releases for new versions of the Dialogue app and handles
/// downloading + installing DMG updates. The user must explicitly opt-in
/// by clicking "Update Now" — no silent or automatic updates.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    // MARK: - Public State

    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String, notes: String, downloadURL: URL)
        case downloading(progress: Double)
        case readyToInstall(dmgPath: URL)
        case installing
        case failed(String)
        case upToDate
    }

    @Published private(set) var state: UpdateState = .idle

    /// The latest available version string (e.g. "0.5.1") when an update exists.
    var availableVersion: String? {
        if case .available(let v, _, _) = state { return v }
        if case .downloading = state { return _pendingVersion }
        if case .readyToInstall = state { return _pendingVersion }
        if case .installing = state { return _pendingVersion }
        return nil
    }

    /// Whether there's an actionable update the user hasn't dismissed.
    var hasUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    /// Whether the update banner should be visible (any active update state).
    var showsBanner: Bool {
        switch state {
        case .available, .downloading, .readyToInstall, .installing:
            return true
        default:
            return false
        }
    }

    // MARK: - Configuration

    private let owner = "BaseDatum"
    private let repo = "DjinnBot"
    private let tagPrefix = "app-v"

    /// How often to automatically check (6 hours).
    private let checkInterval: TimeInterval = 6 * 60 * 60

    /// UserDefaults key for last check timestamp.
    private let lastCheckKey = "appUpdater_lastCheckDate"
    /// UserDefaults key for dismissed version (user chose to skip).
    private let dismissedVersionKey = "appUpdater_dismissedVersion"

    // MARK: - Private

    private let log = Logger(subsystem: "bot.djinn.app.dialog", category: "AppUpdater")

    private var _pendingVersion: String?
    private var _pendingDownloadURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var periodicTimer: Timer?
    private var progressObservation: NSKeyValueObservation?

    /// True for local dev builds where MARKETING_VERSION is 0.0.0 (not set by CI).
    var isDevBuild: Bool {
        currentAppVersion() == "0.0.0"
    }

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app launch. Starts periodic checking.
    /// Skips automatic checks in dev builds (version 0.0.0) — manual check still works.
    func startPeriodicChecks() {
        guard !isDevBuild else { return }

        // Check now if enough time has elapsed since last check.
        let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        if elapsed >= checkInterval || lastCheck == 0 {
            Task { await checkForUpdates(silent: true) }
        }

        // Schedule periodic checks.
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Check for Updates

    /// Queries GitHub releases API for the latest `app-v*` release.
    /// - Parameter silent: If true, doesn't change state to `.checking` and
    ///   won't show `.upToDate` — used for background periodic checks.
    func checkForUpdates(silent: Bool = false) async {
        if !silent {
            state = .checking
        }

        do {
            let release = try await fetchLatestAppRelease()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            guard let remoteVersion = parseVersion(from: release.tagName) else {
                if !silent { state = .failed("Could not parse version from tag: \(release.tagName)") }
                return
            }

            let currentVersion = currentAppVersion()

            if compareVersions(remoteVersion, isNewerThan: currentVersion) {
                // Check if user previously dismissed this version.
                let dismissed = UserDefaults.standard.string(forKey: dismissedVersionKey)
                if silent && dismissed == remoteVersion {
                    return // User dismissed this version; don't nag.
                }

                let downloadURL = release.assets.first?.browserDownloadURL
                    ?? release.assets.first?.url

                guard let url = downloadURL else {
                    if !silent { state = .failed("No DMG asset found in release \(release.tagName)") }
                    return
                }

                state = .available(
                    version: remoteVersion,
                    notes: release.body ?? "No release notes.",
                    downloadURL: url
                )
            } else {
                if !silent {
                    state = .upToDate
                    // Reset to idle after a few seconds.
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if case .upToDate = self.state { self.state = .idle }
                    }
                }
            }
        } catch {
            if !silent {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Dismiss the current update notification (user chose "Later").
    func dismissUpdate() {
        if let v = availableVersion {
            UserDefaults.standard.set(v, forKey: dismissedVersionKey)
        }
        state = .idle
    }

    // MARK: - Download

    /// Downloads the DMG from the release asset URL.
    func downloadUpdate() async {
        guard case .available(let version, _, let url) = state else { return }

        _pendingVersion = version
        _pendingDownloadURL = url
        state = .downloading(progress: 0)

        do {
            let dmgPath = try await downloadDMG(from: url, version: version)
            state = .readyToInstall(dmgPath: dmgPath)
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
        }
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation?.invalidate()
        progressObservation = nil
        state = .idle
    }

    // MARK: - Install

    /// Mounts the downloaded DMG, copies the .app over the current bundle,
    /// and relaunches the app.
    func installUpdate() async {
        guard case .readyToInstall(let dmgPath) = state else {
            log.error("installUpdate called but state is not readyToInstall")
            return
        }
        state = .installing
        log.info("Starting install from \(dmgPath.path)")

        do {
            try await performInstall(dmgPath: dmgPath)
            // If performInstall succeeds, the app is about to exit(0).
            // We should never reach here because exit(0) is called in
            // launchInstallerScript. If we somehow do, don't reset state —
            // the app is in the process of terminating.
        } catch {
            log.error("Install failed: \(error)")
            state = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GitHubAsset]
        let prerelease: Bool
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, assets, prerelease, draft
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL?
        let url: URL?
        let size: Int
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case url, size
            case contentType = "content_type"
        }
    }

    /// Fetches all releases and finds the latest `app-v*` release.
    private func fetchLatestAppRelease() async throws -> GitHubRelease {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dialogue-macOS-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.httpError(code)
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        // Filter to app-v* tags, non-draft, non-prerelease, with DMG assets.
        let appReleases = releases.filter { release in
            release.tagName.hasPrefix(tagPrefix)
                && !release.draft
                && !release.prerelease
                && release.assets.contains(where: { $0.name.hasSuffix(".dmg") })
        }

        // Sort by version descending and take the newest.
        guard let latest = appReleases
            .compactMap({ release -> (GitHubRelease, String)? in
                guard let v = parseVersion(from: release.tagName) else { return nil }
                return (release, v)
            })
            .sorted(by: { compareVersions($0.1, isNewerThan: $1.1) })
            .first?.0
        else {
            throw UpdateError.noReleasesFound
        }

        // Prefer the DMG asset.
        var filtered = latest
        filtered = GitHubRelease(
            tagName: latest.tagName,
            body: latest.body,
            assets: latest.assets.filter { $0.name.hasSuffix(".dmg") },
            prerelease: latest.prerelease,
            draft: latest.draft
        )

        return filtered
    }

    // MARK: - Download Helpers

    private func downloadDMG(from url: URL, version: String) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DialogueUpdate", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destPath = tempDir.appendingPathComponent("Dialogue-\(version).dmg")

        // Remove any existing partial download.
        try? FileManager.default.removeItem(at: destPath)

        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Dialogue-macOS-App", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                // Validate HTTP status — a non-2xx response (e.g. 404, 401,
                // or a redirect to an HTML page) would save garbage that
                // hdiutil can't mount.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: UpdateError.downloadFailed)
                    return
                }

                guard let tempURL = tempURL else {
                    continuation.resume(throwing: UpdateError.downloadFailed)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destPath)

                    // Sanity-check: a valid DMG should be at least ~100 KB.
                    let attrs = try FileManager.default.attributesOfItem(atPath: destPath.path)
                    let size = attrs[.size] as? UInt64 ?? 0
                    if size < 100_000 {
                        try? FileManager.default.removeItem(at: destPath)
                        continuation.resume(throwing: UpdateError.downloadFailed)
                        return
                    }

                    continuation.resume(returning: destPath)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            self.downloadTask = task

            // Observe progress.
            self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: progress.fractionCompleted)
                }
            }

            task.resume()
        }
    }

    // MARK: - Install Helpers

    /// Mounts the DMG, stages the new .app to a temp directory, then launches
    /// a detached shell script that waits for this process to exit before
    /// swapping the app bundle and relaunching. This avoids macOS's refusal
    /// to replace a running .app.
    private func performInstall(dmgPath: URL) async throws {
        let fm = FileManager.default

        // 1. Strip the quarantine xattr that macOS adds to files downloaded
        //    via URLSession. Without this, hdiutil may silently refuse to
        //    mount the DMG due to Gatekeeper (especially with -quiet).
        stripQuarantine(at: dmgPath)

        // 2. Mount the DMG.
        log.info("Mounting DMG at \(dmgPath.path)")
        let mountPoint = try await mountDMG(at: dmgPath)
        log.info("DMG mounted at \(mountPoint)")

        // 2. Find the .app inside the mounted volume.
        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try fm.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
        log.info("DMG contents: \(contents.map(\.lastPathComponent))")
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            await unmountDMG(at: mountPoint)
            throw UpdateError.noAppInDMG
        }

        // 3. Stage: copy the new .app from the DMG to a temp directory.
        //    We can't leave it on the mounted DMG because we need to unmount
        //    before the shell script runs (after we exit).
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("DialogueUpdate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let stagedApp = stagingDir.appendingPathComponent(appBundle.lastPathComponent)
        log.info("Copying \(appBundle.lastPathComponent) to staging: \(stagingDir.path)")
        try fm.copyItem(at: appBundle, to: stagedApp)

        // 4. Unmount the DMG synchronously — we need it done before proceeding.
        await unmountDMG(at: mountPoint)
        try? fm.removeItem(at: dmgPath)

        // 5. Clear dismissed version before we quit.
        UserDefaults.standard.removeObject(forKey: dismissedVersionKey)

        // 6. Launch a detached shell script that:
        //    a) Waits for our PID to exit
        //    b) Removes the old .app
        //    c) Moves the staged .app into place
        //    d) Opens the new app
        //    e) Cleans up the staging directory
        let currentAppPath = Bundle.main.bundlePath
        log.info("Launching installer script: staged=\(stagedApp.path) target=\(currentAppPath)")
        try launchInstallerScript(
            stagedAppPath: stagedApp.path,
            targetAppPath: currentAppPath,
            stagingDirPath: stagingDir.path
        )
    }

    /// Launches a fully detached shell script that performs the actual file
    /// swap after this process exits.
    ///
    /// The script is written to a temp file and launched via `nohup ... &`
    /// in a subshell so it survives the parent process exiting. A plain
    /// `Process()` child gets killed when the parent terminates because
    /// they share a process group.
    private func launchInstallerScript(
        stagedAppPath: String,
        targetAppPath: String,
        stagingDirPath: String
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier

        // Log file lets us diagnose issues even after the app has quit.
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-update.log").path

        let script = """
            #!/bin/sh
            exec > "\(logFile)" 2>&1
            echo "Update script started at $(date)"
            echo "Waiting for PID \(pid) to exit..."

            # Wait for the app to fully exit (timeout after 30s)
            TRIES=0
            while kill -0 \(pid) 2>/dev/null; do
                sleep 0.2
                TRIES=$((TRIES + 1))
                if [ $TRIES -gt 150 ]; then
                    echo "ERROR: App did not exit after 30s, aborting"
                    exit 1
                fi
            done
            echo "App exited after $TRIES checks"
            sleep 0.5

            # Remove the old app bundle
            echo "Removing old app at \(targetAppPath)"
            rm -rf "\(targetAppPath)"

            # Move the staged app into place
            echo "Moving staged app to \(targetAppPath)"
            mv "\(stagedAppPath)" "\(targetAppPath)"
            if [ $? -ne 0 ]; then
                echo "ERROR: mv failed with exit code $?"
                exit 1
            fi

            # Clean up staging directory
            rm -rf "\(stagingDirPath)"

            # Relaunch
            echo "Relaunching \(targetAppPath)"
            open "\(targetAppPath)"

            echo "Update script completed at $(date)"

            # Self-cleanup
            rm -f "$0"
            """

        // Write script to a temp file so it can outlive our process.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-update-\(UUID().uuidString.prefix(8)).sh")

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        log.info("Wrote update script to \(scriptURL.path)")

        // Launch via a subshell with nohup + & so the script fully detaches
        // from our process group and survives app termination.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup '\(scriptURL.path)' >/dev/null 2>&1 &"]
        launcher.qualityOfService = .userInitiated
        try launcher.run()

        log.info("Installer script launched, terminating app in 0.5s")

        // Hard-exit the app. NSApplication.shared.terminate(nil) goes through
        // SwiftUI's shutdown sequence which can silently cancel termination.
        // For an update-and-relaunch flow we need a guaranteed exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }

    /// Mounts a DMG and returns the mount point path.
    ///
    /// Runs `hdiutil attach` off the main thread to avoid blocking the UI.
    private func mountDMG(at path: URL) async throws -> String {
        let dmgPath = path.path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [log] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["attach", dmgPath, "-nobrowse", "-plist"]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    log.error("hdiutil failed to launch: \(error)")
                    continuation.resume(throwing: UpdateError.dmgMountFailed("hdiutil failed to launch: \(error.localizedDescription)"))
                    return
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    log.error("hdiutil attach exited with \(process.terminationStatus): \(stderr)")
                    continuation.resume(throwing: UpdateError.dmgMountFailed("hdiutil exited with status \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                    return
                }

                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let entities = plist["system-entities"] as? [[String: Any]]
                else {
                    log.error("hdiutil attach: failed to parse plist output")
                    continuation.resume(throwing: UpdateError.dmgMountFailed("could not parse hdiutil plist output"))
                    return
                }

                for entity in entities {
                    if let mountPoint = entity["mount-point"] as? String {
                        continuation.resume(returning: mountPoint)
                        return
                    }
                }

                log.error("hdiutil attach: no mount-point found in plist entities")
                continuation.resume(throwing: UpdateError.dmgMountFailed("no mount-point found in hdiutil output"))
            }
        }
    }

    /// Removes the com.apple.quarantine extended attribute that macOS sets
    /// on files downloaded via URLSession. This prevents Gatekeeper from
    /// adding latency or failing on offline machines during `hdiutil attach`.
    private nonisolated func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Unmounts a DMG volume. Waits for completion so callers can safely
    /// delete the DMG file afterward.
    private func unmountDMG(at mountPoint: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [log] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["detach", mountPoint, "-quiet"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        log.warning("hdiutil detach exited with \(process.terminationStatus)")
                    }
                } catch {
                    log.warning("hdiutil detach failed to launch: \(error)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Version Helpers

    /// Returns the app's current version from the bundle (CFBundleShortVersionString).
    func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Extracts "X.Y.Z" from a tag like "app-vX.Y.Z".
    private func parseVersion(from tag: String) -> String? {
        guard tag.hasPrefix(tagPrefix) else { return nil }
        let version = String(tag.dropFirst(tagPrefix.count))
        // Validate it looks like a version.
        let parts = version.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return version
    }

    /// Returns true if `a` is a newer version than `b` (semantic versioning).
    private func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(aParts.count, bParts.count) {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false // equal
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case noReleasesFound
        case downloadFailed
        case dmgMountFailed(String)
        case noAppInDMG
        case installCopyFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid GitHub API URL."
            case .httpError(let code): return "GitHub API returned HTTP \(code)."
            case .noReleasesFound: return "No app releases found on GitHub."
            case .downloadFailed: return "DMG download failed."
            case .dmgMountFailed(let detail): return "Failed to mount the DMG: \(detail)"
            case .noAppInDMG: return "No .app found inside the DMG."
            case .installCopyFailed(let msg): return "Failed to copy new app: \(msg)"
            }
        }
    }
}
