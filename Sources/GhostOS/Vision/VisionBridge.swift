// VisionBridge.swift - HTTP client to the Python vision sidecar
//
// Ghost OS v2 calls the vision sidecar when the AX tree can't find
// what the agent needs (web apps with generic AXGroup roles, dynamic
// content, etc.).
//
// Architecture:
//   Ghost OS (Swift) --HTTP--> Vision Sidecar (Python) --MLX--> ShowUI-2B
//
// The sidecar runs on localhost:9876. VisionBridge auto-starts it when
// needed via the `ghost-vision` launcher script.
//
// VisionBridge handles:
//   1. Health check (is the sidecar running?)
//   2. VLM grounding (find element coordinates from screenshot + description)
//   3. Sidecar lifecycle management (auto-start, track PID)

import Foundation

/// Bridge between Ghost OS v2 and the Python vision sidecar.
/// All methods are synchronous (blocking) because the MCP server is synchronous.
public enum VisionBridge {

    /// Default sidecar URL. Can be overridden via GHOST_VISION_URL env var.
    private static let baseURL: String = {
        if let url = ProcessInfo.processInfo.environment["GHOST_VISION_URL"] {
            return url
        }
        let port = ProcessInfo.processInfo.environment["GHOST_VISION_PORT"] ?? "9876"
        return "http://127.0.0.1:\(port)"
    }()

    /// Timeout for health checks (short — just checking if process is alive).
    private static let healthTimeout: TimeInterval = 2.0

    /// Timeout for VLM grounding (model inference can take 3-5s on first call,
    /// then 0.5-3s on subsequent calls with warm model).
    private static let groundTimeout: TimeInterval = 30.0

    /// Timeout for the first grounding call which also loads the model (~10-15s).
    private static let firstGroundTimeout: TimeInterval = 60.0

    /// PID of the sidecar process we started (if any).
    nonisolated(unsafe) private static var sidecarPID: Int32?

    // MARK: - Health Check

    /// Check if the vision sidecar is running and responsive.
    public static func isAvailable() -> Bool {
        guard let result = httpGet(path: "/health", timeout: healthTimeout) else {
            return false
        }
        return result["status"] != nil
    }

    /// Get detailed health status from the sidecar.
    public static func healthCheck() -> [String: Any]? {
        httpGet(path: "/health", timeout: healthTimeout)
    }

    // MARK: - VLM Grounding

    /// Result from a VLM grounding call.
    public struct GroundResult {
        /// X coordinate in logical screen points.
        public let x: Double
        /// Y coordinate in logical screen points.
        public let y: Double
        /// Confidence (0-1). 0 means coordinates couldn't be parsed.
        public let confidence: Double
        /// Raw model output text.
        public let raw: String
        /// Method used: "full-screen" or "crop-based".
        public let method: String
        /// Inference time in milliseconds.
        public let inferenceMs: Int
    }

    /// Find precise coordinates for a UI element using VLM grounding.
    ///
    /// Auto-starts the vision sidecar if it's not already running.
    ///
    /// - Parameters:
    ///   - imageBase64: Base64-encoded PNG screenshot
    ///   - description: What to find (e.g., "Compose button", "Send button")
    ///   - screenWidth: Logical screen width in points (default 1728)
    ///   - screenHeight: Logical screen height in points (default 1117)
    ///   - cropBox: Optional crop region [x1, y1, x2, y2] in logical points.
    ///              When provided, the sidecar crops the image first, runs VLM
    ///              on the crop, then maps coordinates back to full screen.
    ///              This dramatically improves accuracy for overlapping panels.
    /// - Returns: GroundResult with coordinates, or nil if grounding failed.
    public static func ground(
        imageBase64: String,
        description: String,
        screenWidth: Double = 1728,
        screenHeight: Double = 1117,
        cropBox: [Double]? = nil
    ) -> GroundResult? {
        // Auto-start sidecar if not running
        if !isAvailable() {
            Log.info("Vision sidecar not running, attempting auto-start...")
            if !startSidecar() {
                Log.warn("Vision sidecar auto-start failed")
                return nil
            }
        }

        var payload: [String: Any] = [
            "image": imageBase64,
            "description": description,
            "screen_w": screenWidth,
            "screen_h": screenHeight,
        ]
        if let cropBox, cropBox.count == 4 {
            payload["crop_box"] = cropBox
        }

        // Use longer timeout for first call (model loading)
        let health = healthCheck()
        let modelsLoaded = (health?["models_loaded"] as? [String])?.isEmpty == false
        let timeout = modelsLoaded ? groundTimeout : firstGroundTimeout

        guard let result = httpPost(path: "/ground", body: payload, timeout: timeout) else {
            Log.warn("Vision sidecar /ground request failed")
            return nil
        }

        guard let x = result["x"] as? Double,
              let y = result["y"] as? Double,
              let confidence = result["confidence"] as? Double
        else {
            Log.warn("Vision sidecar /ground returned invalid response: \(result)")
            return nil
        }

        return GroundResult(
            x: x,
            y: y,
            confidence: confidence,
            raw: result["raw"] as? String ?? "",
            method: result["method"] as? String ?? "unknown",
            inferenceMs: result["inference_ms"] as? Int ?? 0
        )
    }

    // MARK: - Sidecar Lifecycle

    /// Attempt to start the vision sidecar process.
    /// Looks for `ghost-vision` launcher script, then falls back to running server.py directly.
    @discardableResult
    public static func startSidecar() -> Bool {
        // Check if already running
        if isAvailable() {
            Log.info("Vision sidecar already running")
            return true
        }

        // Strategy 1: Use ghost-vision launcher script (handles venv/Python resolution)
        if let launcher = findGhostVisionBinary() {
            Log.info("Starting vision sidecar via \(launcher)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launcher)
            process.arguments = ["--idle-timeout", "600"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError

            do {
                try process.run()
                sidecarPID = process.processIdentifier
            } catch {
                Log.error("Failed to start vision sidecar via launcher: \(error)")
                // Fall through to strategy 2
            }

            if waitForSidecar() {
                Log.info("Vision sidecar started (PID \(process.processIdentifier))")
                return true
            }
        }

        // Strategy 2: Run server.py directly with system Python
        if let script = findServerScript() {
            Log.info("Starting vision sidecar from \(script)")

            // Find Python with mlx_vlm
            let python = findPython()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, "--idle-timeout", "600"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError

            do {
                try process.run()
                sidecarPID = process.processIdentifier
            } catch {
                Log.error("Failed to start vision sidecar: \(error)")
                return false
            }

            if waitForSidecar() {
                Log.info("Vision sidecar started (PID \(process.processIdentifier))")
                return true
            }
        }

        Log.warn("Could not find or start vision sidecar")
        return false
    }

    /// Wait for the sidecar to become responsive (up to 10 seconds).
    private static func waitForSidecar() -> Bool {
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.1)
            if isAvailable() {
                return true
            }
        }
        Log.warn("Vision sidecar started but not responding after 10s")
        return false
    }

    /// Find the ghost-vision launcher script/binary.
    private static func findGhostVisionBinary() -> String? {
        let candidates = [
            // Homebrew install
            "/opt/homebrew/bin/ghost-vision",
            "/usr/local/bin/ghost-vision",
            // Same directory as the ghost binary
            (ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent + "/ghost-vision",
            // Development location
            (ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent + "/../vision-sidecar/ghost-vision",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Find the server.py script in expected locations.
    private static func findServerScript() -> String? {
        let candidates = [
            // Homebrew install
            "/opt/homebrew/share/ghost-os/vision-sidecar/server.py",
            "/usr/local/share/ghost-os/vision-sidecar/server.py",
            // Next to the ghost binary (installed)
            (ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent + "/vision-sidecar/server.py",
            // Development: .build/debug/ghost -> project root/vision-sidecar/
            ((ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent as NSString)
                .deletingLastPathComponent + "/vision-sidecar/server.py",
            (((ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent as NSString)
                .deletingLastPathComponent as NSString)
                .deletingLastPathComponent + "/vision-sidecar/server.py",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Find the best Python executable with mlx_vlm available.
    private static func findPython() -> String {
        // Check venv first
        let venvPython = NSHomeDirectory() + "/.ghost-os/venv/bin/python3"
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return venvPython
        }

        // Homebrew Python
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // System Python
        return "/usr/bin/python3"
    }

    // MARK: - Model Path Resolution

    /// Check if the ShowUI-2B model exists at any known location.
    /// Returns the path if found, nil otherwise.
    public static func findModelPath() -> String? {
        let candidates = [
            "/opt/homebrew/share/ghost-os/models/ShowUI-2B",
            NSHomeDirectory() + "/.ghost-os/models/ShowUI-2B",
            NSHomeDirectory() + "/.shadow/models/llm/ShowUI-2B-bf16-8bit",
        ]

        for path in candidates {
            let safetensors = (path as NSString).appendingPathComponent("model.safetensors")
            let config = (path as NSString).appendingPathComponent("config.json")
            if FileManager.default.fileExists(atPath: safetensors)
                || FileManager.default.fileExists(atPath: config)
            {
                return path
            }
        }
        return nil
    }

    // MARK: - HTTP Helpers

    /// Synchronous HTTP GET. Returns parsed JSON or nil.
    private static func httpGet(path: String, timeout: TimeInterval) -> [String: Any]? {
        guard let url = URL(string: baseURL + path) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        return performRequest(request)
    }

    /// Synchronous HTTP POST with JSON body. Returns parsed JSON or nil.
    private static func httpPost(
        path: String,
        body: [String: Any],
        timeout: TimeInterval
    ) -> [String: Any]? {
        guard let url = URL(string: baseURL + path) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            Log.error("Vision: Failed to serialize request body")
            return nil
        }
        request.httpBody = jsonData

        return performRequest(request)
    }

    /// Perform a synchronous URLSession request. Blocks the calling thread
    /// using a semaphore (acceptable since MCP server is single-threaded).
    private static func performRequest(_ request: URLRequest) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)

        // Use nonisolated Sendable box to shuttle data across the closure boundary.
        // The class must be nonisolated to escape @MainActor default isolation,
        // since the URLSession completion handler runs on a background thread.
        nonisolated final class ResponseBox: @unchecked Sendable {
            var data: Data?
            var error: (any Error)?
        }
        let box = ResponseBox()

        // Use a detached session to avoid MainActor issues
        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: request) { data, _, error in
            box.data = data
            box.error = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = box.error {
            // Don't log connection refused as error — sidecar might not be running
            let nsError = error as NSError
            if nsError.code == NSURLErrorCannotConnectToHost ||
               nsError.code == NSURLErrorTimedOut ||
               nsError.code == NSURLErrorNetworkConnectionLost
            {
                Log.debug("Vision sidecar not reachable: \(error.localizedDescription)")
            } else {
                Log.warn("Vision HTTP error: \(error.localizedDescription)")
            }
            return nil
        }

        guard let data = box.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return json
    }
}
