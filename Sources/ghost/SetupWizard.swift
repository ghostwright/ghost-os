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

        // Detect and remove broken PyTorch-format model (incompatible with MLX)
        let ghostModelDir = NSHomeDirectory() + "/.ghost-os/models/ShowUI-2B"
        let pytorchBin = (ghostModelDir as NSString).appendingPathComponent("pytorch_model.bin")
        let safetensorsFile = (ghostModelDir as NSString).appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: pytorchBin)
            && !FileManager.default.fileExists(atPath: safetensorsFile) {
            print("  Found ShowUI-2B in PyTorch format (not compatible with MLX).")
            print("  Removing to re-download in correct format...")
            try? FileManager.default.removeItem(atPath: ghostModelDir)
        }

        // Check for model after potential cleanup
        let modelPath = findModelPath()
        let hasModel = modelPath != nil

        if hasModel {
            print("  Model: found at \(modelPath!)")
        }

        // Step 6a: Ensure Python environment
        // Set up the venv whenever mlx_vlm isn't already available — the launcher
        // existing doesn't mean Python is ready for model download or sidecar use.
        if !hasPython {
            print("  Setting up Python environment...")
            if !setupPythonVenv() {
                printFail("Python venv setup failed")
                print("  Vision grounding (ghost_ground) will not be available.")
                print("  You can set it up manually later:")
                print("    python3 -m venv ~/.ghost-os/venv")
                print("    ~/.ghost-os/venv/bin/pip install --no-deps \"mlx-vlm==0.1.15\"")
                print("    ~/.ghost-os/venv/bin/pip install \"transformers==4.48.3\" \"mlx-lm>=0.21.5,<0.30.0\" mlx Pillow \"numpy>=1.23.4\"")
                print("")
                return false
            }
            print("  Python environment: ready")
        } else {
            print("  Python environment: ready")
        }

        if hasLauncher {
            print("  Launcher: \(findGhostVisionBinary() ?? "found")")
        }

        // Step 6b: Download model if missing
        if !hasModel {
            print("")
            print("  ShowUI-2B model not found. Download now? (~3 GB)")
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
                print("    huggingface-cli download mlx-community/ShowUI-2B-bf16-8bit --local-dir ~/.ghost-os/models/ShowUI-2B")
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

        // Find system Python (prefer versioned paths to avoid Xcode's Python 3.9)
        let pythonPath: String
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            pythonPath = found
        } else {
            let which = runShell("which python3 2>/dev/null")
            guard which.exitCode == 0, !which.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("  ERROR: python3 not found. Install Python 3.10+ first.")
                return false
            }
            pythonPath = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MLX requires Python 3.10+
        let versionResult = runShell("\(pythonPath) -c \"import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')\" 2>&1")
        let versionStr = versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let vParts = versionStr.split(separator: ".")
        if vParts.count >= 2,
           let major = Int(vParts[0]),
           let minor = Int(vParts[1]) {
            if major < 3 || (major == 3 && minor < 10) {
                print("  ERROR: Python \(versionStr) detected. MLX requires Python 3.10+.")
                print("  Install a newer Python: brew install python@3.12")
                print("  Then run `ghost setup` again.")
                return false
            }
        }

        // Recreate venv if it was created by an older Ghost OS version.
        // Stale venvs may have incompatible package versions (e.g. transformers>=4.49
        // which requires PyTorch for Qwen2VL video processor).
        let venvStampPath = venvPath + "/.ghost-os-version"
        let venvPip = venvPath + "/bin/pip"
        let currentVersion = GhostOS.version

        if FileManager.default.isExecutableFile(atPath: venvPip) {
            let stampVersion = (try? String(contentsOfFile: venvStampPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stampVersion != currentVersion {
                print("  Recreating Python environment for v\(currentVersion)...")
                try? FileManager.default.removeItem(atPath: venvPath)
            }
        }

        // Create venv if needed
        if !FileManager.default.isExecutableFile(atPath: venvPip) {
            print("  Creating virtual environment...")
            let createResult = runShell("\(pythonPath) -m venv \"\(venvPath)\" 2>&1")
            if createResult.exitCode != 0 {
                print("  ERROR: venv creation failed: \(createResult.output)")
                return false
            }
        }

        // Install mlx-vlm with --no-deps, then install its runtime deps separately.
        // mlx-vlm 0.1.15 metadata declares transformers>=4.49.0 but works fine with
        // 4.48.3 at runtime. Without --no-deps, pip refuses to resolve the conflict.
        print("  Installing mlx-vlm, transformers, mlx, Pillow...")
        print("  (This may take a minute on first install)")
        let pipStep1 = runShell(
            "\"\(venvPath)/bin/pip\" install --quiet --no-deps \"mlx-vlm==0.1.15\" 2>&1"
        )
        if pipStep1.exitCode != 0 {
            print("  ERROR: pip install mlx-vlm failed:")
            let lines = pipStep1.output.split(separator: "\n")
            for line in lines.suffix(5) {
                print("    \(line)")
            }
            return false
        }

        // mlx-lm is a runtime import of mlx-vlm (models/base.py imports mlx_lm.models.cache)
        let pipStep2 = runShell(
            "\"\(venvPath)/bin/pip\" install --quiet"
            + " \"transformers==4.48.3\" \"mlx-lm>=0.21.5,<0.30.0\" mlx Pillow \"numpy>=1.23.4\" 2>&1"
        )
        if pipStep2.exitCode != 0 {
            print("  ERROR: pip install dependencies failed:")
            let lines = pipStep2.output.split(separator: "\n")
            for line in lines.suffix(5) {
                print("    \(line)")
            }
            return false
        }

        // Verify mlx_vlm imports and transformers version is in safe range
        let verifyScript = """
        import mlx_vlm
        import transformers
        v = transformers.__version__.split(".")
        major, minor = int(v[0]), int(v[1])
        if major > 4 or (major == 4 and minor >= 49):
            print("BAD_TRANSFORMERS:" + transformers.__version__)
        else:
            print("ok")
        """
        let verifyResult = runShell("\"\(venvPath)/bin/python3\" -c '\(verifyScript)' 2>&1")
        if verifyResult.exitCode != 0 || !verifyResult.output.contains("ok") {
            if verifyResult.output.contains("BAD_TRANSFORMERS") {
                let badVer = verifyResult.output.split(separator: ":").last ?? "unknown"
                print("  ERROR: transformers \(badVer) installed (>=4.49 requires PyTorch).")
                print("  Fix: rm -rf ~/.ghost-os/venv && ghost setup")
            } else {
                print("  ERROR: mlx_vlm verification failed")
            }
            return false
        }

        // Stamp the venv with the current Ghost OS version
        try? currentVersion.write(toFile: venvStampPath, atomically: true, encoding: .utf8)

        return true
    }

    /// Find ShowUI-2B model in known locations
    private func findModelPath() -> String? {
        VisionBridge.findModelPath()
    }

    /// Resolve python3 to an absolute path by checking common locations then PATH.
    /// Returns nil if python3 cannot be found.
    private func resolveAbsolutePythonPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let which = runShell("which python3 2>/dev/null")
        if which.exitCode == 0 {
            let path = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// Download ShowUI-2B model from HuggingFace
    private func downloadModel() -> Bool {
        let destDir = NSHomeDirectory() + "/.ghost-os/models/ShowUI-2B"

        // Create directory
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        // Find Python — must be an absolute path since Process/URL(fileURLWithPath:)
        // resolves bare names like "python3" relative to CWD, not via PATH.
        let venvPython = NSHomeDirectory() + "/.ghost-os/venv/bin/python3"
        let python: String
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            python = venvPython
        } else if let resolved = resolveAbsolutePythonPath() {
            python = resolved
        } else {
            print("  ERROR: python3 not found. Install Python 3.10+ first.")
            return false
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
        ALLOW = ["*.safetensors", "*.json", "merges.txt", "vocab.txt", "vocab.json", "tokenizer.model"]
        def download(dest):
            from huggingface_hub import snapshot_download
            return snapshot_download(
                "mlx-community/ShowUI-2B-bf16-8bit",
                local_dir=dest,
                local_dir_use_symlinks=False,
                allow_patterns=ALLOW,
            )
        try:
            from huggingface_hub import snapshot_download
        except ImportError:
            import subprocess
            subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "huggingface-hub"])
        try:
            path = download(dest)
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
        let configPath = (destDir as NSString).appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: safetensorsPath),
              FileManager.default.fileExists(atPath: configPath) else {
            let pytorchPath = (destDir as NSString).appendingPathComponent("pytorch_model.bin")
            if FileManager.default.fileExists(atPath: pytorchPath) {
                print("  ERROR: Model downloaded in PyTorch format (pytorch_model.bin).")
                print("  Ghost OS requires MLX safetensors format.")
                print("  Fix: rm -rf \(destDir) && ghost setup")
            } else {
                print("  ERROR: Download incomplete - model.safetensors not found.")
            }
            return false
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: safetensorsPath),
           let size = attrs[.size] as? UInt64 {
            let sizeGB = Double(size) / 1_000_000_000
            if sizeGB > 1.0 {
                print("")
                print("  Model downloaded successfully (\(String(format: "%.1f", sizeGB)) GB)")
                return true
            } else {
                print("  ERROR: model.safetensors too small (\(String(format: "%.2f", sizeGB)) GB). Download may be corrupt.")
                print("  Fix: rm -rf \(destDir) && ghost setup")
                return false
            }
        }

        print("  ERROR: Could not verify model.safetensors file size.")
        return false
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
