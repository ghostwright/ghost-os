// SetupWizard.swift - Interactive first-run setup for Ghost OS v2
//
// Walks the user through:
//   1. Detect host app (iTerm2, VS Code, Cursor, Terminal)
//   2. Accessibility permission (opens System Settings to exact pane)
//   3. Screen Recording permission (optional, for screenshots)
//   4. MCP configuration for Claude Code (runs claude mcp add)
//   5. Install bundled recipes
//   6. Self-test verification
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

        // Step 6: Self-test
        let verified = selfTest(hasAccess: hasAccess, hasScreenRecording: hasScreenRecording)

        // Summary
        printSummary(
            hostApp: hostApp,
            accessibility: hasAccess,
            screenRecording: hasScreenRecording,
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

        // Add Ghost OS to MCP
        print("  Adding Ghost OS to Claude Code MCP servers...")
        let addResult = runShell("claude mcp add ghost-os \(binaryPath) -- mcp 2>&1")

        if addResult.exitCode == 0 {
            printOK("Added ghost-os MCP server")
        } else {
            print("  Auto-configure failed. Run this command manually:")
            print("    claude mcp add ghost-os \(binaryPath) -- mcp")
            print("")
        }
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

    // MARK: - Step 6: Self-Test

    private func selfTest(hasAccess: Bool, hasScreenRecording: Bool) -> Bool {
        printStep(6, "Self-Test")

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

        printOK("All tests passed")
        return true
    }

    // MARK: - Summary

    private func printSummary(hostApp: String, accessibility: Bool, screenRecording: Bool, verified: Bool) {
        print("")
        print("  ══════════════════════════════════")
        if accessibility && verified {
            print("  Ghost OS is ready!")
            print("")
            print("  Start a new Claude Code session to connect.")
            print("  Then try: \"Send an email via Gmail\"")
            print("  Or:       \"Search arxiv for transformers\"")
        } else {
            print("  Setup incomplete.")
            print("")
            if !accessibility {
                print("  Fix: Grant Accessibility permission to \(hostApp)")
            }
            print("  Then run `ghost setup` again.")
        }
        print("  ══════════════════════════════════")
        print("")
    }

    // MARK: - Helpers

    private func printBanner() {
        print("")
        print("  Ghost OS v\(GhostOS.version) Setup")
        print("  ══════════════════════════════════")
        print("")
    }

    private func printStep(_ n: Int, _ title: String) {
        print("  \(n). \(title)")
    }

    private func printOK(_ message: String) {
        print("     ✓ \(message)")
        print("")
    }

    private func printFail(_ message: String) {
        print("     ✗ \(message)")
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
        // Check relative to the binary (for development builds)
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent

        // Development: binary is at .build/debug/ghost, recipes at ../../recipes/
        let devPath = (binaryDir as NSString)
            .deletingLastPathComponent  // .build
            .appending("/recipes") as String
        // Actually: .build/debug/ghost -> go up to project root
        let projectRoot = ((binaryDir as NSString)
            .deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        let recipesPath = (projectRoot as NSString).appendingPathComponent("recipes")

        if FileManager.default.fileExists(atPath: recipesPath) {
            return recipesPath
        }

        // Check next to the binary
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
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ShellResult(output: output, exitCode: process.terminationStatus)
        } catch {
            return ShellResult(output: "", exitCode: -1)
        }
    }
}
