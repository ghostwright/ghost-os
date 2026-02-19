<p align="center">
  <img src="logo-animated.gif" width="140" alt="Ghost OS">
</p>

<h1 align="center">Ghost OS</h1>
<p align="center"><em>Full computer-use for AI agents.</em></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6.2-orange.svg" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/MCP-compatible-green.svg" alt="MCP Compatible">
</p>

---

Your AI agent can write code, run tests, search files. But it can't click a button, send an email, or fill out a form. It lives inside a chat box.

Ghost OS changes that. One install, and any AI agent can see and operate every app on your Mac.

```
You:     "Send an email to sarah@company.com about the Q4 report"
Agent:   ghost_run recipe:"gmail-send" params:{recipient, subject, body}
         → Compose opens, fields fill, email sends. Done.
```

### Setup
![Ghost OS Setup Demo](demo.gif)

### Recipes in Action
Send emails and download papers. Any app. Any workflow.

![Ghost OS Recipes Demo](demo-recipes.gif)

### Beyond the Browser
Slack messages, Finder folders — Ghost OS operates native macOS apps, not just browsers.

![Ghost OS Slack + Finder Demo](demo-slack-finder.gif)

## Install

```bash
brew install ghostwright/ghost-os/ghost-os
ghost setup
```

That's it. `ghost setup` handles permissions, MCP configuration, and recipe installation.

## How It Works

Ghost OS connects to your AI agent through [MCP](https://modelcontextprotocol.io) and gives it 20 tools to see and operate your Mac. It reads the macOS accessibility tree for structured data about every app, and takes screenshots when visual context is needed. Click, type, scroll, press keys, manage windows. Any app, not just browsers.

```
You:     "Download the latest paper on chain-of-thought prompting from arXiv"
Agent:   ghost_run recipe:"arxiv-download" params:{query:"chain of thought prompting"}
         → Navigates to arXiv, searches, opens PDF, downloads to Desktop. Done.
```

Works with Claude Code, Cursor, VS Code, or anything that speaks MCP.

## Recipes

When your agent figures out a workflow, it saves it as a recipe. A recipe is a JSON file with steps, parameters, and wait conditions. Transparent and auditable.

**A frontier model figures out the workflow once. A small model runs it forever.**

```bash
# One command sends an email
ghost_run recipe:"gmail-send" params:{"recipient":"hello@example.com","subject":"Hello","body":"World"}

# 7 steps, 30 seconds, 100% reliable
```

- Recipes are just JSON. Read every step before running.
- Share with your team. One person learns the workflow, everyone benefits.
- Chain recipes together. The agent knows when to call what.
- Write once with Claude or GPT-4. Run forever with Haiku.

## 20 Tools

| | Tool | What it does |
|:---:|------|-------------|
| 🔍 | `ghost_context` | Get the current app, window title, URL, focused element, and all interactive elements on screen |
| 🔍 | `ghost_state` | List every running app with its windows, positions, and sizes |
| 🔍 | `ghost_find` | Search for elements by name, role, DOM id, or CSS class across the entire UI |
| 🔍 | `ghost_read` | Extract text content from any app, with depth control for nested content |
| 🔍 | `ghost_inspect` | Get complete metadata for one element: role, position, actions, DOM id, editable state |
| 🔍 | `ghost_element_at` | Identify what element is at a specific screen coordinate |
| 📸 | `ghost_screenshot` | Capture a window screenshot for visual debugging |
| 🎯 | `ghost_click` | Click an element by name, DOM id, or screen coordinates |
| ⌨️ | `ghost_type` | Type text into a specific field by name, or at the current cursor |
| ⌨️ | `ghost_press` | Press a single key like Return, Tab, Escape, or arrow keys |
| ⌨️ | `ghost_hotkey` | Press key combinations like Cmd+L, Cmd+Return, Cmd+Shift+P |
| 🎯 | `ghost_scroll` | Scroll up, down, left, or right in any app window |
| 🪟 | `ghost_focus` | Bring any app or specific window to the front |
| 🪟 | `ghost_window` | Minimize, maximize, close, move, or resize any window |
| ⏳ | `ghost_wait` | Wait for a URL change, element to appear or disappear, or title change |
| 📦 | `ghost_recipes` | List all installed recipes with descriptions and parameters |
| ▶️ | `ghost_run` | Execute a recipe with parameter substitution |
| 📦 | `ghost_recipe_show` | View the full steps and configuration of a recipe |
| 📦 | `ghost_recipe_save` | Install a new recipe from JSON |
| 📦 | `ghost_recipe_delete` | Remove an installed recipe |

## Diagnostics

```bash
$ ghost doctor

  ✓ Accessibility: granted
  ✓ Screen Recording: granted
  ✓ Processes: 1 ghost MCP process
  ✓ MCP Config: ghost-os connected
  ✓ Recipes: 4 installed
  ✓ AX Tree: 12/12 apps readable

  All checks passed. Ghost OS is healthy.
```

## Build From Source

```bash
git clone https://github.com/ghostwright/ghost-os.git
cd ghost-os
swift build
.build/debug/ghost setup
```

Requires Swift 6.2+ and macOS 14+.

## Architecture

```
AI Agent (Claude Code, Cursor, any MCP client)
    │
    │ MCP Protocol (stdio)
    │
Ghost OS MCP Server
    │
    ├── Perception ── see what's on screen
    ├── Actions ───── click, type, scroll, keys
    ├── Recipes ───── self-learning workflows
    └── AXorcist ──── macOS accessibility engine
```

~4,500 lines of Swift. Built on [AXorcist](https://github.com/steipete/AXorcist) by [@steipete](https://github.com/steipete).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We need recipes for more apps, testing on different setups, and bug reports. If you're building AI agents that do real things, this is the project.

## License

MIT
