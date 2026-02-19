// main.swift - Ghost OS v2 CLI entry point
//
// Thin CLI with four commands:
//   ghost mcp     - Start the MCP server (the main thing)
//   ghost setup   - Interactive setup wizard
//   ghost status  - Health check
//   ghost test    - Quick self-test
//
// Everything else goes through MCP tools.

import AppKit
import ApplicationServices
import Foundation
import GhostOS

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"

switch command {
case "mcp":
    let server = MCPServer()
    server.run()

case "status":
    printStatus()

case "setup":
    // Phase 6 implementation
    print("Ghost OS v\(GhostOS.version)")
    print("Setup wizard coming in Phase 6.")
    print("For now, ensure Accessibility permission is granted in")
    print("System Settings > Privacy & Security > Accessibility")

case "test":
    // Phase 7 implementation
    print("Ghost OS v\(GhostOS.version)")
    print("Self-test coming in Phase 7.")

case "version", "--version", "-v":
    print("Ghost OS v\(GhostOS.version)")

case "help", "--help", "-h":
    printUsage()

default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}

// MARK: - Status

func printStatus() {
    print("Ghost OS v\(GhostOS.version)")
    print("")

    // Accessibility permission
    let hasAX = AXIsProcessTrusted()
    print("Accessibility: \(hasAX ? "granted" : "NOT GRANTED")")
    if !hasAX {
        print("  Grant in: System Settings > Privacy & Security > Accessibility")
    }

    // Screen recording permission
    let hasScreenRecording = ScreenCapture.hasPermission()
    print("Screen Recording: \(hasScreenRecording ? "granted" : "NOT GRANTED")")
    if !hasScreenRecording {
        print("  Grant in: System Settings > Privacy & Security > Screen Recording")
    }

    // Recipes
    let recipes = RecipeStore.listRecipes()
    print("Recipes: \(recipes.count) installed")

    // Running apps
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    print("Running apps: \(apps.count)")

    print("")
    if hasAX {
        print("Status: Ready")
    } else {
        print("Status: Accessibility permission required")
    }
}

// MARK: - Usage

func printUsage() {
    print("""
    Ghost OS v\(GhostOS.version) - Accessibility-tree MCP server for AI agents

    Usage: ghost <command>

    Commands:
      mcp       Start the MCP server (used by Claude Code)
      status    Check permissions, recipes, health
      setup     Interactive setup wizard
      test      Run quick self-test
      version   Print version

    Ghost OS gives AI agents eyes and hands on macOS through the accessibility tree.
    Run 'ghost setup' to configure, then add ghost-os to your Claude Code MCP config.
    """)
}
