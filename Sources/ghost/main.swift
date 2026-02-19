// main.swift - Ghost OS v2 CLI entry point
//
// Thin CLI:
//   ghost mcp       Start the MCP server (used by Claude Code)
//   ghost setup     Interactive setup wizard
//   ghost doctor    Diagnose issues and suggest fixes
//   ghost status    Quick health check
//   ghost version   Print version

import AppKit
import ApplicationServices
import Foundation
import GhostOS

// Force CoreGraphics server connection initialization.
// ScreenCaptureKit requires a CG connection to the window server.
_ = CGMainDisplayID()

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"

switch command {
case "mcp":
    let server = MCPServer()
    server.run()

case "setup":
    let wizard = SetupWizard()
    wizard.run()

case "doctor":
    var doctor = Doctor()
    doctor.run()

case "status":
    printStatus()

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

    let hasAX = AXIsProcessTrusted()
    print("Accessibility: \(hasAX ? "granted" : "NOT GRANTED")")
    if !hasAX {
        print("  Run: ghost setup")
    }

    let hasScreenRecording = ScreenCapture.hasPermission()
    print("Screen Recording: \(hasScreenRecording ? "granted" : "not granted")")

    let recipes = RecipeStore.listRecipes()
    print("Recipes: \(recipes.count) installed")

    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    print("Running apps: \(apps.count)")

    print("")
    print(hasAX ? "Status: Ready" : "Status: Run `ghost setup` first")
}

// MARK: - Usage

func printUsage() {
    print("""
    Ghost OS v\(GhostOS.version) - Accessibility-tree MCP server for AI agents

    Usage: ghost <command>

    Commands:
      mcp       Start the MCP server (used by Claude Code)
      setup     Interactive setup wizard (first-time configuration)
      doctor    Diagnose issues and suggest fixes
      status    Quick health check
      version   Print version

    Get started:
      ghost setup     Configure permissions and MCP
      ghost doctor    Check if everything is working

    Ghost OS gives AI agents eyes and hands on macOS.
    """)
}
