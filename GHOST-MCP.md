# Ghost OS v2 - MCP Agent Instructions

You have Ghost OS, a tool that lets you see and operate any macOS application
through the accessibility tree AND visual perception. Every button, text field,
link, and label is available -- either through the AX tree (native apps) or
vision-based grounding (web apps where Chrome exposes everything as AXGroup).

## Rule 1: Always Check Recipes First

Before doing ANY multi-step task manually, call `ghost_recipes`.

If a recipe exists for what you need, use `ghost_run` with the recipe name
and parameters. Recipes are tested, reliable, and faster than manual steps.

## Rule 2: Orient Before Acting

Before interacting with any app, call `ghost_context` with the app name.

This tells you: which app/window is active, the current URL (for browsers),
what element is focused, and what interactive elements are visible.

**If you skip this, you will click the wrong thing.**

## Rule 3: How to Find Elements

Use `ghost_find` with the most specific identifier available:
- `dom_id` for web apps (most reliable, bypasses depth limits)
- `identifier` for native apps with developer IDs
- `query` + `role` for general searches (e.g., query:"Compose", role:"AXButton")
- `query` alone as a fallback

Use `ghost_inspect` to examine an element before acting on it.
Use `ghost_element_at` to identify elements from screenshots.

## Rule 4: How Focus Works

**Perception tools work from background** (no focus needed):
- ghost_context, ghost_state, ghost_find, ghost_read, ghost_inspect,
  ghost_element_at, ghost_screenshot

**Click and type try AX-native first** (no focus), then synthetic fallback (auto-focuses):
- ghost_click, ghost_type

**Press, hotkey, scroll need focus** - always pass the `app` parameter:
- ghost_press, ghost_hotkey, ghost_scroll

Focus is automatically saved and restored after action tools.

## Rule 5: Key Patterns

### Navigate Chrome to a URL
```
ghost_hotkey keys:["cmd","l"] app:"Chrome"  → address bar focused
ghost_type text:"https://example.com"       → URL entered
ghost_press key:"return" app:"Chrome"       → navigate
ghost_wait condition:"urlContains" value:"example.com" app:"Chrome"
```

### Fill a form
```
ghost_click query:"Compose" app:"Chrome"    → click button
ghost_type text:"hello@example.com" into:"To" app:"Chrome"
ghost_press key:"tab" app:"Chrome"          → move to next field
ghost_type text:"Subject line" into:"Subject" app:"Chrome"
```

### Wait instead of guessing
```
ghost_wait condition:"elementExists" value:"Send" app:"Chrome"
ghost_wait condition:"urlContains" value:"inbox" timeout:15 app:"Chrome"
ghost_wait condition:"elementGone" value:"Loading" app:"Chrome"
```

## Rule 6: Vision Fallback for Web Apps

When `ghost_find` or `ghost_click` can't locate an element (common in web apps
like Gmail, Slack, etc. where Chrome exposes everything as AXGroup), Ghost OS
automatically falls back to VLM-based vision grounding if the vision sidecar
is running.

You can also use vision tools directly:

### ghost_ground - Find element by visual description
```
ghost_ground description:"Compose button" app:"Chrome"
→ Returns: {x: 86, y: 223, confidence: 0.8, method: "full-screen"}
```

For overlapping UI panels (e.g., compose popup over inbox), use crop_box
to narrow the search area for dramatically better accuracy:
```
ghost_ground description:"Send button" app:"Chrome" crop_box:[510, 168, 840, 390]
→ Returns: {x: 620, y: 350, confidence: 0.95, method: "crop-based"}
```

Then click at the returned coordinates:
```
ghost_click x:86 y:223 app:"Chrome"
```

### ghost_parse_screen - Detect all interactive elements
```
ghost_parse_screen app:"Chrome"
→ Returns list of all detected UI elements with bounding boxes
```
Note: Full YOLO detection is not yet implemented. Use ghost_find for
AX-based element search, and ghost_ground for visual element finding.

## Rule 7: Handle Failures

If an action fails:
1. Call `ghost_context` to see current state
2. Call `ghost_screenshot` for visual confirmation
3. Try `ghost_ground` with a description of what you need to click
4. Try a different approach (different query, coordinates, etc.)

Don't retry the same thing 5 times. If ghost_click fails, it already tried
AX-native, synthetic, AND VLM vision grounding. The element might not exist,
might be hidden, or might be blocked by a modal.

## Tool Reference

| Tool | Purpose | Needs Focus? |
|------|---------|-------------|
| ghost_context | Where am I? URL, focused element, actions | No |
| ghost_state | All running apps and windows | No |
| ghost_find | Find elements by text, role, DOM id | No |
| ghost_read | Read text content from screen | No |
| ghost_inspect | Full element metadata | No |
| ghost_element_at | What's at these coordinates? | No |
| ghost_screenshot | Visual capture for debugging | No |
| ghost_click | Click element or coordinates | Auto |
| ghost_type | Type text, optionally into a field | Auto |
| ghost_press | Press single key | Yes - use `app` |
| ghost_hotkey | Key combo (cmd+s, etc.) | Yes - use `app` |
| ghost_scroll | Scroll content | Yes - use `app` |
| ghost_focus | Bring app to front | N/A |
| ghost_window | Window management | No |
| ghost_wait | Wait for condition | No |
| ghost_recipes | List recipes | No |
| ghost_run | Execute recipe | Auto |
| ghost_recipe_show | View recipe details | No |
| ghost_recipe_save | Save new recipe | No |
| ghost_recipe_delete | Delete recipe | No |
| ghost_parse_screen | Detect ALL UI elements via vision | No |
| ghost_ground | Find element coordinates via VLM | No |
