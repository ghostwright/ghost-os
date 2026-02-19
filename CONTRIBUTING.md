# Contributing to Ghost OS

Ghost OS is open source and we welcome contributions.

## What We Need Help With

### Recipes
The most impactful contribution is a new recipe. Pick an app, figure out the workflow, save it as a recipe JSON, test it 3+ times, and submit a PR.

Good recipe candidates:
- Slack: send a message, reply to a thread
- Google Calendar: create an event
- Finder: organize files, create folders
- System Settings: toggle settings
- Any web app: login, fill forms, extract data

### Testing on Different Apps
Ghost OS should work with every app. Test it with apps you use daily and report what works and what doesn't. File issues with:
- Which app and version
- What tool you called
- What happened vs what you expected
- The output from `ghost doctor`

### Bug Fixes
Check the [issues](https://github.com/ghostwright/ghost-os/issues) page. Issues labeled `good first issue` are a great starting point.

## Development Setup

```bash
git clone https://github.com/ghostwright/ghost-os.git
cd ghost-os
swift build
```

Requirements:
- macOS 14+
- Swift 6.2+ (install via [swiftly](https://github.com/swiftlang/swiftly))
- Accessibility permission for your terminal app
- Screen Recording permission (optional, for screenshots)

The project depends on [AXorcist](https://github.com/steipete/AXorcist) which is referenced as a local package at `../AXorcist`. Clone it alongside ghost-os:

```
your-workspace/
├── AXorcist/      # git clone https://github.com/steipete/AXorcist
└── ghost-os/      # this repo
```

## Project Structure

```
Sources/
├── GhostOS/                    # Library (the MCP server logic)
│   ├── MCP/                    # MCPServer, MCPTools, MCPDispatch
│   ├── Perception/             # ghost_context, ghost_find, ghost_read, etc.
│   ├── Actions/                # ghost_click, ghost_type, ghost_hotkey, etc.
│   ├── Recipes/                # RecipeEngine, RecipeStore, RecipeTypes
│   ├── Screenshot/             # ScreenCaptureKit wrapper
│   └── Common/                 # Logger, Types, LocatorBuilder
└── ghost/                      # CLI (thin entry point)
    ├── main.swift              # ghost mcp, setup, doctor, status
    ├── SetupWizard.swift       # Interactive first-run setup
    └── Doctor.swift            # Diagnostic tool
```

## Writing a Recipe

Recipes are JSON files stored in `~/.ghost-os/recipes/`. Here's the structure:

```json
{
    "schema_version": 2,
    "name": "my-recipe",
    "description": "What this recipe does",
    "app": "Google Chrome",
    "params": {
        "query": {
            "type": "string",
            "description": "What to search for",
            "required": true
        }
    },
    "preconditions": {
        "app_running": "Google Chrome",
        "url_contains": "example.com"
    },
    "steps": [
        {
            "id": 1,
            "action": "click",
            "target": {
                "criteria": [{"attribute": "AXRole", "value": "AXButton"}],
                "computedNameContains": "Search"
            },
            "wait_after": {
                "condition": "elementExists",
                "value": "Results",
                "timeout": 5
            },
            "note": "Click the search button"
        }
    ],
    "on_failure": "stop"
}
```

**Actions:** click, type, press, hotkey, focus, scroll, wait

**Wait conditions:** elementExists, elementGone, urlContains, titleContains, urlChanged, titleChanged, delay

**Tips:**
- Use `computedNameContains` for fuzzy matching ("Compose" matches "Compose" button)
- Add `criteria` with `AXRole` to narrow matches (e.g., only buttons)
- Always include `"criteria": []` even if empty (required by the Locator decoder)
- Use `wait_after` instead of fixed delays
- Test your recipe at least 3 times before submitting

## Code Style

- Swift 6.2 with strict concurrency
- All logging to stderr (stdout is the MCP protocol channel)
- No force unwraps except in tests
- Functions over 80 lines get split
- Errors tell the agent what to do next, not just what went wrong

## Commit Messages

- Concise but informative
- Anyone reading the git log should understand what changed
- No AI attribution lines
