# Ghost OS v2 Progress

## Current State: Phases 0-5 COMPLETE. Phase 6-7 next.

## What Works (tested end-to-end)
- **20/20 MCP tools** functional
- **gmail-send recipe**: 5/5 success via ghost_run
- **arxiv-download recipe**: 3/3 success (agent-created, 8 steps)
- **Screenshots**: stable on multi-monitor, inline display in Claude Code
- **Cmd+L navigation**: works consistently (no flicker)
- **Scroll**: works on second monitor via element-based scroll
- **All perception tools**: context, state, find, read, inspect, element_at
- **All action tools**: click, type (into field + at focus), press, hotkey, scroll
- **All wait conditions**: urlContains, elementExists, elementGone, titleContains
- **Recipe CRUD**: list, show, save (with decode error details), delete

## Key Numbers
- 15 Swift files, ~3,800 lines (vs v1's 6,200)
- ~20 commits on main
- GitHub: ghostwright/ghost-os

## What's Next

### Phase 6: Setup & Polish
- `ghost setup` wizard: permissions, MCP config, recipe install, self-test
- Polish GHOST-MCP.md with learnings (use "To recipients" not "To", etc.)
- Bundled recipes: install from repo recipes/ dir on first run

### Phase 7: Testing & Hardening
- Test against 10 apps (Slack, Finder, System Settings, Messages, etc.)
- Recipe reliability tests (run each 5x, track success rate)
- Stress test (MCP server up 24 hours)

## Known Items (not blocking)
- Field-finding takes ~11s for deep web apps (exhaustive tree walk)
- elementExists uses contains matching (document in GHOST-MCP.md)
- into:"To" works but into:"To recipients" is more reliable for recipes
