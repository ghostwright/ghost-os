// Doctor.swift - Diagnostic tool for Ghost OS v2
//
// Non-interactive. Checks everything, reports issues, suggests fixes.
// Can auto-fix safe things (kill stale processes, recreate recipes dir).
//
// Usage: ghost doctor

import AppKit
import ApplicationServices
import AXorcist
import Foundation
import GhostOS

struct Doctor {

    private var issueCount = 0
    private var warningCount = 0

    mutating func run() {
        print("")
        print("  Ghost OS Doctor")
        print("  ══════════════════════════════════")
        print("")

        checkBinary()
        checkAccessibility()
        checkScreenRecording()
        checkProcesses()
        checkMCPConfig()
        checkRecipes()
        checkAXTree()
        checkVisionSidecar()

        printSummary()
    }

    // MARK: - Binary

    private func checkBinary() {
        let path = ProcessInfo.processInfo.arguments[0]
        print("  Binary: \(path)")
        print("  Version: \(GhostOS.version)")
        print("")
    }

    // MARK: - Accessibility

    private mutating func checkAccessibility() {
        if AXIsProcessTrusted() {
            print("  ✓ Accessibility: granted")
        } else {
            print("  ✗ Accessibility: NOT GRANTED")
            print("    Fix: System Settings > Privacy & Security > Accessibility")
            print("    Add your terminal app (\(detectHostApp()))")
            issueCount += 1
        }
    }

    // MARK: - Screen Recording

    private mutating func checkScreenRecording() {
        if ScreenCapture.hasPermission() {
            print("  ✓ Screen Recording: granted")
        } else {
            print("  ! Screen Recording: not granted (screenshots won't work)")
            print("    Fix: System Settings > Privacy & Security > Screen Recording")
            print("    Add your terminal app (\(detectHostApp()))")
            warningCount += 1
        }
    }

    // MARK: - Ghost Processes

    private mutating func checkProcesses() {
        let result = runShell("ps aux | grep '[g]host mcp' | awk '{print $2, $11, $12}'")
        let lines = result.output.split(separator: "\n").map(String.init)

        if lines.isEmpty {
            print("  ✓ Processes: no ghost MCP processes running")
        } else if lines.count == 1 {
            print("  ✓ Processes: 1 ghost MCP process (PID: \(lines[0].split(separator: " ").first ?? "?"))")
        } else {
            print("  ✗ Processes: \(lines.count) ghost MCP processes found (expect 0 or 1)")
            for line in lines {
                let parts = line.split(separator: " ")
                let pid = parts.first ?? "?"
                let path = parts.dropFirst().joined(separator: " ")
                print("    PID \(pid): \(path)")
            }
            print("    Fix: kill stale processes with:")
            for line in lines.dropFirst() {
                let pid = line.split(separator: " ").first ?? "?"
                print("      kill \(pid)")
            }
            issueCount += 1
        }
    }

    // MARK: - MCP Config

    private mutating func checkMCPConfig() {
        let result = runShell("which claude 2>/dev/null")
        if result.exitCode != 0 {
            print("  ! Claude Code CLI: not found")
            print("    Install from: https://claude.ai/download")
            warningCount += 1
            return
        }

        // Read config file directly instead of running `claude mcp list`
        // which health-checks every server and takes 30+ seconds.
        let configPath = NSHomeDirectory() + "/.claude.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcpServers = config["mcpServers"] as? [String: Any],
           let ghostConfig = mcpServers["ghost-os"] as? [String: Any]
        {
            let command = ghostConfig["command"] as? String ?? "(unknown)"
            print("  ✓ MCP Config: ghost-os configured")
            print("    Binary: \(command)")
        } else {
            print("  ✗ MCP Config: ghost-os not configured")
            let binaryPath = resolveBinaryPath()
            print("    Fix: claude mcp add ghost-os \(binaryPath) -- mcp")
            issueCount += 1
        }
    }

    // MARK: - Recipes

    private mutating func checkRecipes() {
        let recipesDir = NSHomeDirectory() + "/.ghost-os/recipes"
        if !FileManager.default.fileExists(atPath: recipesDir) {
            print("  ✗ Recipes: directory missing (~/.ghost-os/recipes/)")
            print("    Fix: ghost setup (installs bundled recipes)")
            issueCount += 1
            return
        }

        let recipes = RecipeStore.listRecipes()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: recipesDir))?
            .filter { $0.hasSuffix(".json") } ?? []

        if files.count > recipes.count {
            let broken = files.count - recipes.count
            print("  ! Recipes: \(recipes.count) loaded, \(broken) failed to decode")
            // Find the broken ones
            let decoder = JSONDecoder()
            for file in files where file.hasSuffix(".json") {
                let path = (recipesDir as NSString).appendingPathComponent(file)
                if let data = FileManager.default.contents(atPath: path) {
                    do {
                        _ = try decoder.decode(Recipe.self, from: data)
                    } catch {
                        let name = (file as NSString).deletingPathExtension
                        print("    Broken: \(name) - \(error)")
                    }
                }
            }
            warningCount += 1
        } else {
            print("  ✓ Recipes: \(recipes.count) installed")
            for recipe in recipes.prefix(10) {
                print("    - \(recipe.name): \(recipe.steps.count) steps")
            }
        }
    }

    // MARK: - AX Tree

    private mutating func checkAXTree() {
        guard AXIsProcessTrusted() else {
            print("  - AX Tree: skipped (no permission)")
            return
        }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var readable = 0
        var unreadable: [String] = []

        for app in apps {
            if Element.application(for: app.processIdentifier) != nil {
                readable += 1
            } else {
                if let name = app.localizedName {
                    unreadable.append(name)
                }
            }
        }

        if readable > 0 {
            print("  ✓ AX Tree: \(readable)/\(apps.count) apps readable")
            if !unreadable.isEmpty && unreadable.count <= 3 {
                print("    Unreadable: \(unreadable.joined(separator: ", ")) (may need focus)")
            }
        } else {
            print("  ✗ AX Tree: no apps readable")
            print("    This usually means Accessibility permission isn't working correctly.")
            print("    Fix: toggle the permission off and on in System Settings")
            issueCount += 1
        }
    }

    // MARK: - Vision Sidecar

    private mutating func checkVisionSidecar() {
        if VisionBridge.isAvailable() {
            if let health = VisionBridge.healthCheck() {
                let models = health["models_loaded"] as? [String] ?? []
                let status = health["status"] as? String ?? "unknown"
                print("  \u{2713} Vision Sidecar: \(status)")
                if !models.isEmpty {
                    print("    Models: \(models.joined(separator: ", "))")
                }
            } else {
                print("  \u{2713} Vision Sidecar: running (health details unavailable)")
            }
        } else {
            print("  ! Vision Sidecar: not running (ghost_ground and ghost_parse_screen won't work)")
            print("    Start: cd ghost-os-v2/vision-sidecar && python3 server.py &")
            print("    The sidecar provides VLM-based element grounding for web apps.")
            warningCount += 1
        }

        // Check if ShowUI-2B model exists
        let modelPath = NSHomeDirectory() + "/.shadow/models/llm/ShowUI-2B-bf16-8bit"
        if FileManager.default.fileExists(atPath: modelPath) {
            print("  \u{2713} ShowUI-2B model: installed")
        } else {
            print("  ! ShowUI-2B model: not installed at \(modelPath)")
            print("    The VLM model is required for vision grounding.")
            warningCount += 1
        }
    }

    // MARK: - Summary

    private func printSummary() {
        print("")
        print("  ──────────────────────────────────")
        if issueCount == 0 && warningCount == 0 {
            print("  All checks passed. Ghost OS is healthy.")
        } else if issueCount == 0 {
            print("  \(warningCount) warning(s), no critical issues.")
        } else {
            print("  \(issueCount) issue(s), \(warningCount) warning(s).")
            print("  Fix the issues above, then run `ghost doctor` again.")
        }
        print("  ──────────────────────────────────")
        print("")
    }

    // MARK: - Helpers

    private func detectHostApp() -> String {
        if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
            switch termProgram.lowercased() {
            case "iterm.app", "iterm2": return "iTerm2"
            case "apple_terminal": return "Terminal"
            case "vscode": return "Visual Studio Code"
            case "cursor": return "Cursor"
            default: return termProgram
            }
        }
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? "your terminal app"
    }

    private func resolveBinaryPath() -> String {
        for path in ["/opt/homebrew/bin/ghost", "/usr/local/bin/ghost"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return ProcessInfo.processInfo.arguments[0]
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
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CODE")
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(output: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
        } catch {
            return ShellResult(output: "", exitCode: -1)
        }
    }
}
