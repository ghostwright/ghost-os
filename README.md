# Ghost OS

**AI agents that learn to use your computer, and remember how.**

Ghost OS is a macOS daemon that lets any AI agent see, understand, and operate every application on your Mac. It reads the accessibility tree (the same structured data screen readers use) instead of taking screenshots. That means it's instant, free, and accurate.

When your agent figures out how to do something (send an email, download a paper, fill out a form), Ghost OS saves it as a recipe. Now any model can replay that workflow perfectly. A frontier model learns it once. A tiny model runs it forever.

<!-- TODO: Add demo GIF here
Record: Split screen with Chrome (left) and Terminal (right).
Run: ghost_run gmail-send with params.
Show: the compose window opening, fields filling, email sending.
Convert to GIF: ffmpeg -i demo.mov -vf "fps=10,scale=1280:-1" demo.gif
Or use: https://gifcap.dev for screen recording directly to GIF
-->

[Demo GIF coming soon]

## Quick Start

```bash
brew install ghostwright/tap/ghost-os
ghost setup
# Restart Claude Code. Done.
```

`ghost setup` walks you through permissions, configures MCP, and installs bundled recipes. Three minutes, start to finish.

## What Can It Do?

Your AI agent can now:

- **Send emails** through Gmail without touching Playwright
- **Download papers** from arXiv, PDF and all
- **Fill out forms** on any website, any app
- **Test your site** by actually clicking through it like a real user
- **Navigate System Settings** to change configurations
- **Manage files** in Finder, create folders, rename things
- **Post messages** in Slack, reply to threads
- **Chain workflows** together. Search, then click, then fill, then submit.

And once it figures out a workflow, it saves a recipe. Next time, one command.

## Recipes: Learn Once, Run Forever

This is the idea that makes Ghost OS different.

Your agent explores Gmail manually. Clicks Compose, finds the To field, types the address, fills Subject and Body, hits Cmd+Return. It works. Great.

Now save that as a recipe:

```
ghost_recipe_save '{ "name": "gmail-send", "steps": [...] }'
```

From now on, any agent, any model, any time:

```
ghost_run recipe:"gmail-send" params:{"recipient":"hello@example.com", "subject":"Hello", "body":"World"}
```

One command. Seven steps execute automatically. Compose opens, fields fill, email sends. Takes about 30 seconds.

**Why this matters:**
- A frontier model (Claude, GPT-4) figures out the workflow once. That's the expensive part.
- A small model (Haiku, GPT-4o-mini) runs the recipe forever. That's the cheap part.
- Recipes are just JSON files. You can read every step. No black box.
- Share recipes with your team. One person figures out the workflow, everyone benefits.

## How It Works

Every app on your Mac exposes an accessibility tree. It's the same structured data that screen readers like VoiceOver use. Every button, text field, link, menu item, and window is in there, with its name, position, role, and available actions.

Ghost OS reads this tree and gives your AI agent 20 tools to work with:

### Perception (see what's on screen)
| Tool | What it does |
|------|-------------|
| `ghost_context` | Where am I? Current app, URL, focused element |
| `ghost_state` | All running apps and their windows |
| `ghost_find` | Find elements by name, role, DOM id |
| `ghost_read` | Read text content from any app |
| `ghost_inspect` | Full metadata about one element |
| `ghost_element_at` | What's at this screen coordinate? |
| `ghost_screenshot` | Visual capture for debugging |

### Action (operate apps)
| Tool | What it does |
|------|-------------|
| `ghost_click` | Click an element or coordinate |
| `ghost_type` | Type into a field by name |
| `ghost_press` | Press a key (Return, Tab, Escape) |
| `ghost_hotkey` | Key combos (Cmd+L, Cmd+Return) |
| `ghost_scroll` | Scroll in any direction |
| `ghost_focus` | Bring an app to the front |
| `ghost_window` | Minimize, maximize, move, resize |

### Wait (timing without guessing)
| Tool | What it does |
|------|-------------|
| `ghost_wait` | Wait for URL change, element to appear/disappear |

### Recipes (learn and replay)
| Tool | What it does |
|------|-------------|
| `ghost_recipes` | List available recipes |
| `ghost_run` | Execute a recipe with parameters |
| `ghost_recipe_show` | View recipe steps |
| `ghost_recipe_save` | Save a new recipe |
| `ghost_recipe_delete` | Remove a recipe |

The agent calls these tools through the [Model Context Protocol](https://modelcontextprotocol.io) (MCP). Ghost OS runs as an MCP server that any compatible AI agent can connect to. Claude Code, Cursor, VS Code with Claude, or anything else that speaks MCP.

## No Playwright. No Screenshots. Native.

Other approaches to computer-use AI take a screenshot, send it to a vision model, get back coordinates, click, take another screenshot, repeat. That's slow, expensive, and fails more often than it works.

Ghost OS reads structured data. It knows "this is a button called Compose at position (200, 140) that supports the press action." No guessing. No vision model needed for navigation. Screenshots are there when you want visual context, but they're not the primary interface.

And it works for every app on your Mac, not just browsers. Mail, Finder, Messages, System Settings, Slack, VS Code, anything with a window.

## Diagnostics

Something not working? Ghost OS tells you exactly what's wrong.

```bash
$ ghost doctor

  Ghost OS Doctor
  ══════════════════════════════════

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

Requires Swift 6.2+ and macOS 14+. Ghost OS depends on [AXorcist](https://github.com/steipete/AXorcist) for accessibility tree access.

## Architecture

```
AI Agent (Claude Code, Cursor, any MCP client)
    |
    | MCP Protocol (stdio)
    |
Ghost OS MCP Server (20 tools)
    |
    ├── Perception: read the screen via accessibility tree
    ├── Actions: click, type, scroll via AX-native + synthetic fallback
    ├── Recipes: parameterized, replayable workflows
    └── AXorcist: Swift accessibility library
        |
        macOS Accessibility Framework
```

~4,500 lines of Swift. 17 source files. No dependencies besides AXorcist.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved.

Ghost OS is at the beginning. The tools work, recipes work, Gmail and arXiv are proven. But there are hundreds of apps to test, dozens of recipes to write, and a whole ecosystem of agent workflows to build. If you're interested in making AI agents that actually do things, this is the project.

## License

MIT. See [LICENSE](LICENSE).
