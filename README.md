<p align="center">
  <h1 align="center">👻 Ghost OS</h1>
  <p align="center">Full computer-use for AI agents. Self-learning. Native. No screenshots required.</p>
</p>

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

<!-- TODO: Replace with demo GIF
Split screen: Chrome (left) + Terminal (right)
Run ghost_run gmail-send, watch compose open and send
Record: Cmd+Shift+5 or https://gifcap.dev
Convert: ffmpeg -i demo.mov -vf "fps=10,scale=1280:-1" demo.gif
-->

## Install

```bash
brew install ghostwright/tap/ghost-os
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

**Perception**

| Tool | Purpose |
|------|---------|
| `ghost_context` | Current app, URL, focused element, interactive elements |
| `ghost_state` | All running apps and their windows |
| `ghost_find` | Find elements by name, role, or DOM id |
| `ghost_read` | Read text content from any app |
| `ghost_inspect` | Full metadata about one element |
| `ghost_element_at` | Identify element at screen coordinates |
| `ghost_screenshot` | Visual capture when you need it |

**Action**

| Tool | Purpose |
|------|---------|
| `ghost_click` | Click elements or coordinates |
| `ghost_type` | Type into fields by name |
| `ghost_press` | Press keys (Return, Tab, Escape) |
| `ghost_hotkey` | Key combos (Cmd+L, Cmd+Return) |
| `ghost_scroll` | Scroll in any direction |
| `ghost_focus` | Bring an app to the front |
| `ghost_window` | Minimize, maximize, move, resize |
| `ghost_wait` | Wait for conditions (URL change, element appear) |

**Recipes**

| Tool | Purpose |
|------|---------|
| `ghost_recipes` | List available recipes |
| `ghost_run` | Execute a recipe with parameters |
| `ghost_recipe_show` | View recipe steps |
| `ghost_recipe_save` | Save a new recipe |
| `ghost_recipe_delete` | Remove a recipe |

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
