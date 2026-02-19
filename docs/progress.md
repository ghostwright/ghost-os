# Ghost OS v2 Progress

## Current Phase: 5 (Recipes) NEXT / Phases 0-4 COMPLETE

## Phase 0: Project Setup - COMPLETE
- Package.swift, directory structure, Logger, Types, LocatorBuilder
- MCPServer with Content-Length/NDJSON auto-detection, stdout capture
- 14 Swift files, compiles cleanly

## Phase 1: MCP Server Shell - COMPLETE
- MCPServer reads/writes JSON-RPC, handles initialize/tools/list/tools/call
- All 20 tool definitions in MCPTools.swift
- MCPDispatch routes to module functions
- Tested: initialize returns instructions, tools/list returns 20 tools

## Phase 2: Perception - COMPLETE
- ghost_context: app, window, URL, focused element, interactive elements list
- ghost_state: running apps with windows
- ghost_find: AXorcist search + semantic depth tunneling fallback, DOM ID search
- ghost_read: text extraction with semantic depth tunneling (zero-cost container traversal)
- ghost_inspect: full element metadata (role, position, actions, DOM id, editable, etc.)
- ghost_element_at: screen coordinate to element bridge
- ghost_screenshot: ScreenCaptureKit with RunLoop-based sync bridge

## Phase 3: Core Actions - COMPLETE
- ghost_click: AX-native press first, synthetic click fallback, coordinate mode
- ghost_type: AX setValue first, synthetic typeText fallback, readback verification
- ghost_press: single key with optional modifiers, SpecialKey mapping
- ghost_hotkey: key combos with clearModifierFlags after every call
- ghost_scroll: directional scroll with coordinate support
- ghost_focus: app/window focus with verification
- All action tools wrapped in FocusManager.withFocusRestore

## Phase 4: Window/Wait - COMPLETE
- ghost_window: minimize, maximize, close, restore, move, resize, list
- ghost_wait: polling for urlContains, titleContains, elementExists, elementGone, urlChanged, titleChanged

## Phase 6 (partial): Agent Instructions
- GHOST-MCP.md written with rules, patterns, and tool reference
- Served via MCP initialize response

## Key Numbers
- 14 Swift source files
- ~3,000 lines total
- 20 MCP tools all implemented
- 2 commits on main

## What's Next: Phase 5 - Recipe System
- RecipeEngine: step-by-step execution with Locator targets
- ghost_run: execute recipes with parameter substitution
- Convert gmail-send recipe to v2 format
- Create bundled recipes: open-url, slack-message, finder-new-folder

## Known Issues
- ghost_type `into` parameter: the nil-coalescing logic for optional `into` vs `domId` is unnecessarily complex
- Screenshot sync bridge uses RunLoop spinning (works but could be cleaner)
- No timeout wrapper on individual AX calls yet
