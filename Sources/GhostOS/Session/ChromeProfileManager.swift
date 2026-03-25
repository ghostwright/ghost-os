// ChromeProfileManager.swift - Persistent Chrome session management for Ghost OS
//
// Manages Chrome user profiles so that login state persists across Ghost OS
// sessions. Users log in once (manually or via recipe), and subsequent
// recipe runs reuse the authenticated session.
//
// Architecture:
//   ~/.ghost-os/profiles/<name>/   → Chrome user-data-dir
//   ~/.ghost-os/profiles/index.json → profile metadata (name, url, lastUsed)
//
// Security: profile directories contain cookies equivalent to credentials.
// File permissions are set to 700 (owner-only). Profiles are excluded from
// git via .gitignore. Never sync profiles across machines.

import Foundation

/// Manages persistent Chrome browser profiles for authenticated workflows.
public enum ChromeProfileManager {

    /// Base directory for all profiles.
    private static let profilesDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ghost-os/profiles")
    }()

    /// Profile metadata stored in index.json.
    public struct ProfileInfo: Codable, Sendable {
        public let name: String
        public let createdAt: Date
        public var lastUsed: Date
        public var url: String?      // Last known URL
        public var description: String?
    }

    // MARK: - Profile CRUD

    /// List all available profiles.
    public static func listProfiles() -> [ProfileInfo] {
        let indexURL = profilesDir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let profiles = try? JSONDecoder.withISO8601.decode([ProfileInfo].self, from: data)
        else {
            return []
        }
        return profiles.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Create a new profile directory.
    /// Returns the profile directory path for Chrome's --user-data-dir flag.
    public static func createProfile(name: String, description: String? = nil) -> URL? {
        let dir = profilesDir.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Set owner-only permissions (700) for security
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )
        } catch {
            Log.error("Failed to create profile directory: \(error)")
            return nil
        }

        // Update index
        var profiles = listProfiles()
        if !profiles.contains(where: { $0.name == name }) {
            profiles.append(ProfileInfo(
                name: name,
                createdAt: Date(),
                lastUsed: Date(),
                url: nil,
                description: description
            ))
            saveIndex(profiles)
        }

        Log.info("Created Chrome profile '\(name)' at \(dir.path)")
        return dir
    }

    /// Get the directory for an existing profile.
    /// Returns nil if the profile doesn't exist.
    public static func profileDir(for name: String) -> URL? {
        let dir = profilesDir.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return nil
        }
        return dir
    }

    /// Delete a profile and its data.
    public static func deleteProfile(name: String) -> Bool {
        let dir = profilesDir.appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(at: dir)
            var profiles = listProfiles()
            profiles.removeAll { $0.name == name }
            saveIndex(profiles)
            Log.info("Deleted Chrome profile '\(name)'")
            return true
        } catch {
            Log.error("Failed to delete profile '\(name)': \(error)")
            return false
        }
    }

    /// Update the lastUsed timestamp for a profile.
    public static func touchProfile(name: String, url: String? = nil) {
        var profiles = listProfiles()
        if let idx = profiles.firstIndex(where: { $0.name == name }) {
            profiles[idx].lastUsed = Date()
            if let url { profiles[idx].url = url }
            saveIndex(profiles)
        }
    }

    // MARK: - Chrome Launch

    /// Build Chrome launch arguments for a given profile.
    /// Returns an array of command-line arguments.
    ///
    /// Usage:
    ///   let args = ChromeProfileManager.chromeLaunchArgs(profile: "github-work", url: "https://github.com")
    ///   // ["--remote-debugging-port=9222", "--user-data-dir=/path/to/profile", "https://github.com"]
    public static func chromeLaunchArgs(
        profile: String,
        url: String? = nil,
        debugPort: Int = 9222
    ) -> [String]? {
        // Get or create profile directory
        let dir = profileDir(for: profile) ?? createProfile(name: profile)
        guard let profilePath = dir?.path else { return nil }

        var args = [
            "--remote-debugging-port=\(debugPort)",
            "--user-data-dir=\(profilePath)",
        ]
        if let url { args.append(url) }

        touchProfile(name: profile, url: url)
        return args
    }

    /// Chrome application path (macOS).
    public static let chromeAppPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    // MARK: - Cookie Export/Import via CDP

    /// Export cookies from the current Chrome session via CDP.
    /// Requires Chrome to be running with --remote-debugging-port.
    public static func exportCookies() -> [[String: Any]]? {
        guard CDPBridge.isAvailable(),
              let targets = CDPBridge.getDebugTargets(),
              let page = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsURL = page["webSocketDebuggerUrl"] as? String
        else {
            return nil
        }

        return cdpCommand(wsURL: wsURL, method: "Network.getAllCookies", params: [:])
    }

    /// Get the current page URL via CDP.
    public static func currentURL() -> String? {
        let js = "location.href"
        guard let targets = CDPBridge.getDebugTargets(),
              let page = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsURL = page["webSocketDebuggerUrl"] as? String,
              let url = URL(string: wsURL)
        else {
            return nil
        }

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": ["expression": js, "returnByValue": true],
        ]
        guard let cmdData = try? JSONSerialization.data(withJSONObject: command),
              let cmdStr = String(data: cmdData, encoding: .utf8)
        else {
            wsTask.cancel(with: .goingAway, reason: nil)
            return nil
        }

        nonisolated final class Box: @unchecked Sendable { var result: String? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)

        wsTask.send(.string(cmdStr)) { error in
            if error != nil { sem.signal(); return }
            wsTask.receive { msg in
                if case .success(let message) = msg, case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let r = json["result"] as? [String: Any],
                   let rv = r["result"] as? [String: Any],
                   let value = rv["value"] as? String
                {
                    box.result = value
                }
                sem.signal()
            }
        }
        sem.wait()
        wsTask.cancel(with: .goingAway, reason: nil)
        return box.result
    }

    // MARK: - Private Helpers

    private static func saveIndex(_ profiles: [ProfileInfo]) {
        let indexURL = profilesDir.appendingPathComponent("index.json")
        do {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
            let data = try JSONEncoder.withISO8601.encode(profiles)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.error("Failed to save profile index: \(error)")
        }
    }

    /// Execute a CDP domain command and return the result.
    private static func cdpCommand(
        wsURL: String,
        method: String,
        params: [String: Any]
    ) -> [[String: Any]]? {
        guard let url = URL(string: wsURL) else { return nil }
        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        let command: [String: Any] = ["id": 1, "method": method, "params": params]
        guard let cmdData = try? JSONSerialization.data(withJSONObject: command),
              let cmdStr = String(data: cmdData, encoding: .utf8)
        else {
            wsTask.cancel(with: .goingAway, reason: nil)
            return nil
        }

        nonisolated final class Box: @unchecked Sendable { var result: [[String: Any]]? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)

        wsTask.send(.string(cmdStr)) { error in
            if error != nil { sem.signal(); return }
            wsTask.receive { msg in
                if case .success(let message) = msg, case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let r = json["result"] as? [String: Any],
                   let cookies = r["cookies"] as? [[String: Any]]
                {
                    box.result = cookies
                }
                sem.signal()
            }
        }

        let _ = sem.wait(timeout: .now() + 3.0)
        wsTask.cancel(with: .goingAway, reason: nil)
        return box.result
    }
}

// MARK: - JSON Coding Helpers

private extension JSONEncoder {
    static let withISO8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let withISO8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
