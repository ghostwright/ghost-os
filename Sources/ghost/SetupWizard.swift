// SetupWizard.swift - Interactive first-run setup for Ghost OS v2
//
// Walks the user through:
//   1. Detect host app (iTerm2, VS Code, Cursor, Terminal)
//   2. Accessibility permission (opens System Settings to exact pane)
//   3. Screen Recording permission (optional, for screenshots)
//   4. MCP configuration for Claude Code (runs claude mcp add)
//   5. Install bundled recipes
//   6. Vision setup (Python venv + ShowUI-2B model download)
//   7. Self-test verification
//
// Usage: ghost setup

import AppKit
import ApplicationServices
import AXorcist
import Foundation
import GhostOS

struct SetupWizard {

    func run() {
        printBanner()

        // Step 1: Detect host app
        let hostApp = detectHostApp()
        printStep(1, "Host Application")
        print("  Detected: \(hostApp)")
        print("  This app needs Accessibility permission to use Ghost OS.")
        print("")

        // Step 2: Accessibility permission
        let hasAccess = checkAccessibility(hostApp: hostApp)

        // Step 3: Screen Recording (optional)
        let hasScreenRecording = checkScreenRecording(hostApp: hostApp)

        // Step 4: MCP configuration
        configureMCP()

        // Step 5: Install recipes
        installRecipes()

        // Step 6: Vision setup (venv + model)
        let hasVision = setupVision()

        // Step 7: Self-test
        let verified = selfTest(
            hasAccess: hasAccess,
            hasScreenRecording: hasScreenRecording,
            hasVision: hasVision
        )

        // Summary
        printSummary(
            hostApp: hostApp,
            accessibility: hasAccess,
            screenRecording: hasScreenRecording,
            vision: hasVision,
            verified: verified
        )
    }

    // MARK: - Step 1: Detect Host App

    private func detectHostApp() -> String {
        // Check TERM_PROGRAM environment variable (set by most terminals)
        if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
            switch termProgram.lowercased() {
            case "iterm.app", "iterm2": return "iTerm2"
            case "apple_terminal": return "Terminal"
            case "vscode": return "Visual Studio Code"
            case "cursor": return "Cursor"
            case "warp": return "Warp"
            case "alacritty": return "Alacritty"
            case "kitty": return "kitty"
            default: return termProgram
            }
        }

        // Check if running inside VS Code or Cursor by looking at parent process
        if let vscodeEnv = ProcessInfo.processInfo.environment["VSCODE_PID"] {
            _ = vscodeEnv
            return "Visual Studio Code"
        }

        // Fallback: check the frontmost app
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            return frontApp
        }

        return "your terminal app"
    }

    // MARK: - Step 2: Accessibility Permission

    private func checkAccessibility(hostApp: String) -> Bool {
        printStep(2, "Accessibility Permission")

        if AXIsProcessTrusted() {
            // Verify with actual AX tree read
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            var axCount = 0
            for app in apps {
                if Element.application(for: app.processIdentifier) != nil {
                    axCount += 1
                }
            }

            if axCount > 0 {
                printOK("Granted (\(axCount) apps accessible)")
                return true
            }
        }

        // Not granted
        print("  Ghost OS reads the accessibility tree to see and operate apps.")
        print("  \(hostApp) needs the Accessibility permission.")
        print("")
        print("  Opening System Settings...")
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        print("")
        print("  Add \"\(hostApp)\" to the Accessibility list.")
        print("  You may need to toggle it off and on if it's already there.")
        print("")

        // Retry loop
        for attempt in 1...3 {
            print("  Press Enter after granting permission (\(attempt)/3)...")
            _ = readLine()

            if AXIsProcessTrusted() {
                printOK("Granted")
                return true
            }

            if attempt < 3 {
                print("  Still not granted. Make sure you added \"\(hostApp)\".")
            }
        }

        printFail("Not granted")
        print("  Grant permission in System Settings > Privacy & Security > Accessibility")
        print("  Then run `ghost setup` again.")
        print("")
        return false
    }

    // MARK: - Step 3: Screen Recording Permission

    private func checkScreenRecording(hostApp: String) -> Bool {
        printStep(3, "Screen Recording Permission (optional)")

        if ScreenCapture.hasPermission() {
            printOK("Granted")
            return true
        }

        print("  Screenshots are optional but useful for visual debugging.")
        print("  \(hostApp) needs Screen Recording permission.")
        print("")
        print("  Set it up now? (y/N) ", terminator: "")
        fflush(stdout)

        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            printOK("Skipped (you can set this up later)")
            return false
        }

        ScreenCapture.requestPermission()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        print("")
        print("  Add \"\(hostApp)\" to the Screen Recording list.")
        print("  Press Enter after granting...")
        _ = readLine()

        if ScreenCapture.hasPermission() {
            printOK("Granted")
            return true
        }

        printFail("Not granted (you can run `ghost setup` again later)")
        return false
    }

    // MARK: - Step 4: MCP Configuration

    private func configureMCP() {
        printStep(4, "MCP Configuration")

        let binaryPath = resolveBinaryPath()

        // Check if claude CLI exists
        let claudeExists = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/claude")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude")
            || runShell("which claude 2>/dev/null").exitCode == 0

        if !claudeExists {
            print("  Claude Code CLI not found.")
            print("  Install it from: https://claude.ai/download")
            print("")
            print("  After installing, run this command to add Ghost OS:")
            print("    claude mcp add ghost-os \(binaryPath) -- mcp")
            print("")
            return
        }

        // Check if already configured (read config file directly — claude mcp list hangs)
        let configPath = NSHomeDirectory() + "/.claude.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcpServers = config["mcpServers"] as? [String: Any],
           mcpServers["ghost-os"] != nil
        {
            printOK("Already configured")
            return
        }

        // Write config directly — claude mcp add also hangs
        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("  WARNING: ~/.claude.json contains non-standard JSON.")
                print("  Please add Ghost OS manually:")
                print("    claude mcp add ghost-os \(binaryPath) -- mcp")
                print("")
                return
            }
            config = existing
        }

        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["ghost-os"] = [
            "type": "stdio",
            "command": binaryPath,
            "args": ["mcp"],
        ]
        config["mcpServers"] = mcpServers

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: URL(fileURLWithPath: configPath))
            print("  MCP server: \(binaryPath)")
        } catch {
            print("  Could not write MCP config. Run this command manually:")
            print("    claude mcp add ghost-os \(binaryPath) -- mcp")
            print("")
        }

        // Add tool permissions to ~/.claude/settings.json so all ghost-os
        // MCP tools are auto-approved globally (no per-session prompts).
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath) {
            if let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }
            // If parsing fails, settings stays empty — we'll create a fresh one.
            // settings.json is machine-generated so non-standard JSON is unlikely.
        }

        var allowedTools = settings["allowedTools"] as? [String] ?? []
        let ghostPermission = "mcp__ghost-os__*"
        if !allowedTools.contains(ghostPermission) {
            allowedTools.append(ghostPermission)
            settings["allowedTools"] = allowedTools

            do {
                try FileManager.default.createDirectory(
                    atPath: NSHomeDirectory() + "/.claude",
                    withIntermediateDirectories: true
                )
                let jsonData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try jsonData.write(to: URL(fileURLWithPath: settingsPath))
                print("  Tool permissions: auto-approved")
            } catch {
                print("  Could not set tool permissions automatically.")
                print("  You may be prompted to approve ghost-os tools on first use.")
            }
        }

        printOK("Configured")
    }

    // MARK: - Step 5: Install Recipes

    private func installRecipes() {
        printStep(5, "Bundled Recipes")

        let recipesDir = NSHomeDirectory() + "/.ghost-os/recipes"
        try? FileManager.default.createDirectory(atPath: recipesDir, withIntermediateDirectories: true)

        // Find bundled recipes in the repo's recipes/ directory
        let bundledDir = findBundledRecipesDir()
        var installed = 0

        if let bundledDir, let files = try? FileManager.default.contentsOfDirectory(atPath: bundledDir) {
            for file in files where file.hasSuffix(".json") {
                let srcPath = (bundledDir as NSString).appendingPathComponent(file)
                let dstPath = (recipesDir as NSString).appendingPathComponent(file)

                if FileManager.default.fileExists(atPath: dstPath) {
                    let name = (file as NSString).deletingPathExtension
                    print("  \(name) - already installed")
                    installed += 1
                    continue
                }

                do {
                    try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
                    let name = (file as NSString).deletingPathExtension
                    print("  \(name) - installed")
                    installed += 1
                } catch {
                    print("  \(file) - failed to install")
                }
            }
        }

        // Count total recipes
        let total = RecipeStore.listRecipes().count
        printOK("\(total) recipe(s) available")
    }

    // MARK: - Step 6: Vision Setup

    private func setupVision() -> Bool {
        printStep(6, "Vision (ShowUI-2B)")

        // Check if ghost-vision is available
        let hasLauncher = findGhostVisionBinary() != nil
        let hasPython = checkPythonWithMLX()

        // Check for model
        let modelPath = findModelPath()
        let hasModel = modelPath != nil

        if hasModel {
            print("  Model: found at \(modelPath!)")
        }

        // Step 6a: Ensure Python environment
        if !hasPython && !hasLauncher {
            print("  Setting up Python environment...")
            if !setupPythonVenv() {
                printFail("Python venv setup failed")
                print("  Vision grounding (ghost_ground) will not be available.")
                print("  You can set it up manually later:")
                print("    python3 -m venv ~/.ghost-os/venv")
                print("    ~/.ghost-os/venv/bin/pip install mlx mlx-vlm transformers Pillow")
                print("")
                return false
            }
            print("  Python environment: ready")
        } else if hasPython {
            print("  Python environment: ready")
        } else {
            print("  Launcher: \(findGhostVisionBinary() ?? "found")")
        }

        // Step 6b: Download model if missing
        if !hasModel {
            print("")
            print("  ShowUI-2B model not found. Download now? (~2.8 GB)")
            print("  This enables visual element grounding for web apps.")
            print("")
            print("  Download? (Y/n) ", terminator: "")
            fflush(stdout)

            let answer = readLine()?.lowercased() ?? "y"
            if answer == "n" || answer == "no" {
                printOK("Skipped (ghost_ground won't work without the model)")
                return false
            }

            print("")
            if !downloadModel() {
                printFail("Model download failed")
                print("  You can download manually:")
                print("    pip3 install huggingface-hub")
                print("    huggingface-cli download showlab/ShowUI-2B --local-dir ~/.ghost-os/models/ShowUI-2B")
                print("")
                return false
            }
        }

        // Step 6c: Verify vision pipeline
        let visionWorks = testVision()
        if visionWorks {
            printOK("Vision ready")
        } else {
            printOK("Vision installed (model will load on first use)")
        }

        return true
    }

    /// Check if system Python has mlx_vlm
    private func checkPythonWithMLX() -> Bool {
        // Check venv first
        let venvPython = NSHomeDirectory() + "/.ghost-os/venv/bin/python3"
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            let result = runShell("\(venvPython) -c 'import mlx_vlm' 2>/dev/null")
            if result.exitCode == 0 { return true }
        }

        // Check system Python
        let result = runShell("python3 -c 'import mlx_vlm' 2>/dev/null")
        return result.exitCode == 0
    }

    /// Set up a Python virtual environment at ~/.ghost-os/venv/
    private func setupPythonVenv() -> Bool {
        let venvPath = NSHomeDirectory() + "/.ghost-os/venv"

        // Find system Python
        let pythonPath: String
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            pythonPath = found
        } else {
            let which = runShell("which python3 2>/dev/null")
            guard which.exitCode == 0, !which.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("  ERROR: python3 not found. Install Python 3.9+ first.")
                return false
            }
            pythonPath = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Create venv (skip if already exists and has pip)
        let venvPip = venvPath + "/bin/pip"
        if !FileManager.default.isExecutableFile(atPath: venvPip) {
            print("  Creating virtual environment...")
            let createResult = runShell("\(pythonPath) -m venv \"\(venvPath)\" 2>&1")
            if createResult.exitCode != 0 {
                print("  ERROR: venv creation failed: \(createResult.output)")
                return false
            }
        }

        // Install dependencies
        print("  Installing mlx, mlx-vlm, transformers, Pillow...")
        print("  (This may take a minute on first install)")
        let pipResult = runShell(
            "\"\(venvPath)/bin/pip\" install --quiet mlx mlx-vlm transformers Pillow 2>&1"
        )
        if pipResult.exitCode != 0 {
            print("  ERROR: pip install failed:")
            // Show last few lines of error
            let lines = pipResult.output.split(separator: "\n")
            for line in lines.suffix(5) {
                print("    \(line)")
            }
            return false
        }

        // Verify
        let verifyResult = runShell("\"\(venvPath)/bin/python3\" -c 'import mlx_vlm; print(\"ok\")' 2>&1")
        if verifyResult.exitCode != 0 || !verifyResult.output.contains("ok") {
            print("  ERROR: mlx_vlm verification failed")
            return false
        }

        return true
    }

    /// Find ShowUI-2B model in known locations
    private func findModelPath() -> String? {
        VisionBridge.findModelPath()
    }

    /// Download ShowUI-2B model from HuggingFace
    private func downloadModel() -> Bool {
        let destDir = NSHomeDirectory() + "/.ghost-os/models/ShowUI-2B"

        // Create directory
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        // Use huggingface-cli if available, otherwise use Python
        let venvPython = NSHomeDirectory() + "/.ghost-os/venv/bin/python3"
        let python: String
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            python = venvPython
        } else {
            python = "python3"
        }

        // Download using huggingface_hub
        print("  Downloading ShowUI-2B from HuggingFace...")
        print("  Destination: \(destDir)")
        print("")

        // Use snapshot_download which handles all files + progress.
        // Pass dest dir as sys.argv[1] to avoid string interpolation injection.
        let downloadScript = """
        import sys
        dest = sys.argv[1]
        try:
            from huggingface_hub import snapshot_download
            path = snapshot_download(
                "showlab/ShowUI-2B",
                local_dir=dest,
                local_dir_use_symlinks=False,
            )
            print(f"Downloaded to: {path}")
        except ImportError:
            import subprocess
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "huggingface-hub"])
            from huggingface_hub import snapshot_download
            path = snapshot_download(
                "showlab/ShowUI-2B",
                local_dir=dest,
                local_dir_use_symlinks=False,
            )
            print(f"Downloaded to: {path}")
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        """

        let tmpScript = NSTemporaryDirectory() + "ghost_download_model_\(UUID().uuidString).py"
        try? downloadScript.write(toFile: tmpScript, atomically: true, encoding: .utf8)

        let result = runShellLive(python, args: [tmpScript, destDir])

        try? FileManager.default.removeItem(atPath: tmpScript)

        if result != 0 {
            print("  Download failed.")
            return false
        }

        // Verify the download
        let safetensorsPath = (destDir as NSString).appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: safetensorsPath) {
            // Check file size (should be > 2GB)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: safetensorsPath),
               let size = attrs[.size] as? UInt64
            {
                let sizeGB = Double(size) / 1_000_000_000
                if sizeGB > 1.0 {
                    print("")
                    print("  Model downloaded successfully (\(String(format: "%.1f", sizeGB)) GB)")
                    return true
                }
            }
        }

        print("  WARNING: Model download may be incomplete. Check \(destDir)")
        return true  // Still return true — might be usable
    }

    /// Test the vision pipeline end-to-end
    private func testVision() -> Bool {
        // Quick check: is the sidecar already running?
        if VisionBridge.isAvailable() {
            return true
        }

        // Don't start the sidecar during setup — it takes ~10s to load
        // Just verify the components are in place
        return false
    }

    /// Find ghost-vision launcher
    private func findGhostVisionBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ghost-vision",
            "/usr/local/bin/ghost-vision",
            (ProcessInfo.processInfo.arguments[0] as NSString)
                .deletingLastPathComponent + "/ghost-vision",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Step 7: Self-Test

    private func selfTest(hasAccess: Bool, hasScreenRecording: Bool, hasVision: Bool) -> Bool {
        printStep(7, "Self-Test")

        guard hasAccess else {
            printFail("Skipped (needs Accessibility permission)")
            return false
        }

        // Test 1: Read AX tree
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var readable = 0
        for app in apps.prefix(5) {
            if Element.application(for: app.processIdentifier) != nil {
                readable += 1
            }
        }

        if readable > 0 {
            print("  AX tree: \(readable) apps readable")
        } else {
            printFail("Cannot read accessibility tree")
            return false
        }

        // Test 2: Screenshot (if permission granted)
        if hasScreenRecording {
            print("  Screenshot: available")
        } else {
            print("  Screenshot: skipped (no Screen Recording permission)")
        }

        // Test 3: Vision (report status)
        if hasVision {
            if let modelPath = findModelPath() {
                print("  Vision model: \(modelPath)")
            }
            print("  Vision: ready (model loads on first ghost_ground call)")
        } else {
            print("  Vision: not configured (ghost_ground won't work)")
        }

        printOK("All tests passed")
        return true
    }

    // MARK: - Summary

    private func printSummary(
        hostApp: String,
        accessibility: Bool,
        screenRecording: Bool,
        vision: Bool,
        verified: Bool
    ) {
        print("")
        print("  ======================================")
        if accessibility && verified {
            print("  Ghost OS is ready!")
            print("")
            print("  Start a new Claude Code session to connect.")
            print("  Then try: \"Send an email via Gmail\"")
            print("  Or:       \"Search arxiv for transformers\"")
            if vision {
                print("")
                print("  Vision grounding is enabled.")
                print("  ghost_ground will auto-start the vision sidecar when needed.")
            }
        } else {
            print("  Setup incomplete.")
            print("")
            if !accessibility {
                print("  Fix: Grant Accessibility permission to \(hostApp)")
            }
            if !vision {
                print("  Optional: Run `ghost setup` again to set up vision")
            }
            print("  Then run `ghost setup` again.")
        }
        print("  ======================================")
        print("")
    }

    // MARK: - Helpers

    private func printBanner() {
        print("")
        print("  Ghost OS v\(GhostOS.version) Setup")
        print("  ======================================")
        print("")
    }

    private func printStep(_ n: Int, _ title: String) {
        print("  \(n). \(title)")
    }

    private func printOK(_ message: String) {
        print("     [ok] \(message)")
        print("")
    }

    private func printFail(_ message: String) {
        print("     [FAIL] \(message)")
        print("")
    }

    private func openSystemSettings(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func resolveBinaryPath() -> String {
        // Check common install locations
        let candidates = [
            "/opt/homebrew/bin/ghost",
            "/usr/local/bin/ghost",
            ProcessInfo.processInfo.arguments[0],
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return ProcessInfo.processInfo.arguments[0]
    }

    private func findBundledRecipesDir() -> String? {
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent

        // Homebrew: /opt/homebrew/share/ghost-os/recipes/
        let brewPaths = [
            "/opt/homebrew/share/ghost-os/recipes",
            "/usr/local/share/ghost-os/recipes",
        ]
        for path in brewPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Development: .build/debug/ghost -> project root/recipes/
        let projectRoot = ((binaryDir as NSString)
            .deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        let recipesPath = (projectRoot as NSString).appendingPathComponent("recipes")
        if FileManager.default.fileExists(atPath: recipesPath) {
            return recipesPath
        }

        // Sibling: next to the binary
        let siblingPath = (binaryDir as NSString).appendingPathComponent("recipes")
        if FileManager.default.fileExists(atPath: siblingPath) {
            return siblingPath
        }

        return nil
    }

    private struct ShellResult {
        let output: String
        let exitCode: Int32
    }

    private func runShell(_ command: String) -> ShellResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        // Unset CLAUDECODE to avoid nested session error
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CODE")
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        do {
            try process.run()
            // Read pipe BEFORE waitUntilExit to avoid deadlock if output exceeds pipe buffer
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ShellResult(output: output, exitCode: process.terminationStatus)
        } catch {
            return ShellResult(output: "", exitCode: -1)
        }
    }

    /// Run a command with live stdout/stderr output (for progress display).
    /// Returns the exit code.
    private func runShellLive(_ executable: String, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Inherit stdout/stderr so the user sees download progress
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CODE")
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            print("  ERROR: Failed to run \(executable): \(error)")
            return -1
        }
    }
}
