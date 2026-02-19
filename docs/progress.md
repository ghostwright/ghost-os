# Ghost OS v2 Progress

## Current Phase: 0 (COMPLETE) / Phase 1 (NEXT)

## Phase 0: Project Setup - COMPLETE

**What was built:**
- Package.swift with local AXorcist dependency at `../AXorcist`, Swift 6.2, macOS 14+
- Two targets: GhostOS (library) and ghost (executable)
- Structured logger (Logger.swift) that writes to stderr only
- Shared types (Types.swift): ToolResult, ContextInfo, ScreenshotResult, GhostError, GhostConstants
- LocatorBuilder.swift: bridge from MCP tool parameters to AXorcist Locators
- Perception.swift: ghost_context and ghost_state implemented with AXorcist Element API
- FocusManager.swift: focus app/window, save/restore focus, modifier key clearing
- MCPServer.swift: stdin/stdout JSON-RPC loop, Content-Length + NDJSON auto-detection, stdout capture
- MCPTools.swift: all 20 tool definitions with descriptions and parameter schemas
- MCPDispatch.swift: routes tool calls, formats responses, implements ghost_context/ghost_state/ghost_focus/recipe tools
- RecipeTypes.swift: v2 recipe format with Locator-based targets
- RecipeStore.swift: file-based recipe storage at ~/.ghost-os/recipes/
- ScreenCapture.swift: ScreenCaptureKit wrapper (carried from v1)
- main.swift: thin CLI with mcp, status, setup, test, version, help
- LocatorBuilderTests.swift: unit tests for LocatorBuilder
- Stub files for Actions, RecipeEngine, WaitManager (Phase 3-5)

**Test results:**
- `swift build`: compiles cleanly (1 warning: unused result of focusWindow)
- `ghost status`: shows AX permission, screen recording, recipes, running apps
- `ghost version`: prints "Ghost OS v2.0.0"

**Decisions:**
- Package references AXorcist via `.package(path: "../AXorcist")`, product name "AXorcist" from package "AXorcist"
- AXorcist's `url()` returns `URL` not `String` - use `.absoluteString`
- MainActor default isolation inherited from AXorcist's settings
- MCP output uses Content-Length framing always (input auto-detects)

**File count:** 14 Swift files
**Line count:** ~1,300 lines total (estimated)

## What's Next: Phase 1 - MCP Server Shell

- Connect to Claude Code MCP config
- Test ghost_context as first working tool through MCP
- Verify tools/list returns all 20 tools
- Test ghost_state through MCP
- Test ghost_focus through MCP
