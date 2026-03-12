# Ghost OS v2 - MCP Agent Instructions

You have Ghost OS, a tool that lets you see and operate any macOS application
through the accessibility tree AND visual perception. Every button, text field,
link, and label is available -- either through the AX tree (native apps) or
vision-based grounding (web apps where Chrome exposes everything as AXGroup).

You have 29 tools: perceive the screen, click, type, hover, drag, long-press,
scroll, press keys, manage windows, wait for conditions, run saved recipes,
and learn new workflows by watching the user.

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

Note: `ghost_screenshot` captures windows even when they are behind other
windows or in another Space. It does NOT need the app to be focused. If all of
an app's windows are closed (not just minimized), screenshot will return an
error -- you cannot capture what does not exist.

**Click and type try AX-native first** (no focus), then synthetic fallback (auto-focuses):
- ghost_click, ghost_type

**Press, hotkey, scroll, hover, long_press, drag need focus** - always pass the `app` parameter:
- ghost_press, ghost_hotkey, ghost_scroll, ghost_hover, ghost_long_press, ghost_drag

Focus is automatically saved and restored after click and type. Other action tools leave the target app focused.

## Rule 5: Key Patterns

### Navigate Chrome to a URL
```
ghost_hotkey keys:["cmd","l"] app:"Chrome"  -> address bar focused
ghost_type text:"https://example.com"       -> URL entered
ghost_press key:"return" app:"Chrome"       -> navigate
ghost_wait condition:"urlContains" value:"example.com" app:"Chrome"
```

### Fill a form
```
ghost_click query:"Compose" app:"Chrome"    -> click button
ghost_type text:"hello@example.com" into:"To" app:"Chrome"
ghost_press key:"tab" app:"Chrome"          -> move to next field
ghost_type text:"Subject line" into:"Subject" app:"Chrome"
```

### Annotate for visual orientation
```
ghost_annotate app:"Chrome"
-> Returns labeled screenshot + text index
-> [1] Button "Send" — click: (620, 350)
-> Use ghost_click x:620 y:350 to click any labeled element
```

### Hover to reveal tooltips or menus
```
ghost_hover query:"Help" app:"Preview"
ghost_hover x:500 y:300 app:"Chrome"
```

### Drag files, sliders, or list items
```
ghost_drag query:"document.pdf" to_x:500 to_y:300 app:"Finder"
ghost_drag from_x:200 from_y:400 to_x:600 to_y:400 app:"Finder"
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
-> Returns: {x: 86, y: 223, confidence: 0.8, method: "full-screen"}
```

For overlapping UI panels (e.g., compose popup over inbox), use crop_box
to narrow the search area for dramatically better accuracy:
```
ghost_ground description:"Send button" app:"Chrome" crop_box:[510, 168, 840, 390]
-> Returns: {x: 620, y: 350, confidence: 0.95, method: "crop-based"}
```

Then click at the returned coordinates:
```
ghost_click x:86 y:223 app:"Chrome"
```

### ghost_parse_screen - Detect all interactive elements
```
ghost_parse_screen app:"Chrome"
-> Returns list of all detected UI elements with bounding boxes
```
Note: Full YOLO detection is not yet implemented. Use ghost_find for
AX-based element search, and ghost_ground for visual element finding.

## Rule 7: Handle Failures

If an action fails:
1. Call `ghost_context` to see current state
2. Call `ghost_annotate` for a labeled screenshot showing every interactive element with click coordinates
3. Call `ghost_screenshot` for raw visual confirmation
4. Try `ghost_ground` with a description of what you need to click
5. Try a different approach (different query, coordinates, etc.)

Don't retry the same thing 5 times. If ghost_click fails, it already tried
AX-native, synthetic, AND VLM vision grounding. The element might not exist,
might be hidden, or might be blocked by a modal.

If `ghost_screenshot` fails for a background app, the window may be minimized
or in another Space. Ghost OS will attempt to capture it off-screen first. If
that fails, it will briefly activate the app to bring it on-screen. If the app
has no open windows at all, screenshot will return a specific error telling you.

## Rule 8: Web App Interaction (Chrome/Electron)

Chrome exposes most web elements as AXGroup -- `ghost_find` may not locate
buttons or inputs by name. **Always prefer `dom_id` for web apps.**

Pattern:
```
ghost_find query:"Send" role:AXButton app:"Chrome"  -> get dom_id from result
ghost_click dom_id:":oq" app:"Chrome"               -> click by dom_id
```

`dom_id` clicks are the MOST reliable method for any web app button.

If `ghost_find` returns nothing, use `ghost_ground` with `crop_box` for
visual grounding.

For text input in web apps, click the field first (by dom_id or coordinates),
then use `ghost_type`.

## Rule 9: Gmail / Email Pattern

Gmail's popup compose window does not reliably accept keyboard input from
synthetic events. Use URL-based compose instead:

```
Navigate to: https://mail.google.com/mail/?view=cm&fs=1&to=EMAIL&su=SUBJECT&body=BODY
```

Wait for the page to load, then find and click the Send button using dom_id.
The Send button's dom_id changes between sessions -- always `ghost_find` it
first rather than hardcoding.

## Rule 10: Coordinate Mapping

Screenshots are downsampled to 1280px max width. Pixel coordinates in the
screenshot image are NOT the same as screen coordinates.

- Use `ghost_ground` for visual-to-screen coordinate translation
- Use `ghost_find` to get element positions (always in screen coordinates)
- The screenshot response includes `window_frame` with the actual screen
  position and size of the captured window

## Rule 11: Vision Grounding Best Practices

**ALWAYS use `crop_box` with `ghost_ground`** when you know the approximate
area. It is 10x faster (250ms vs 3s) and much more accurate.

- `crop_box` format: `[x1, y1, x2, y2]` in logical screen points
- For overlapping UI (popups, dropdowns, compose windows), `crop_box` is
  ESSENTIAL to prevent the VLM from grounding to the wrong layer
- Get crop coordinates from `ghost_find` element positions or `ghost_state`
  window positions

## Rule 12: Wait Between Actions

Web apps need time to react to clicks. Always use `ghost_wait` after clicking
buttons before proceeding:

```
ghost_click query:"Submit" app:"Chrome"
ghost_wait condition:"elementExists" value:"Success" app:"Chrome"
```

Common wait conditions:
- `urlContains` -- wait for navigation
- `titleContains` -- wait for page title change
- `elementExists` -- wait for an element to appear
- `elementGone` -- wait for a loading indicator to disappear

## Rule 13: Self-Learning Mode

Ghost OS can learn workflows by watching the user perform them.

### How to use learning mode
1. User says they want to teach a workflow
2. Call `ghost_learn_start` with a task_description
3. Tell the user to perform the task
4. User says they are done
5. Call `ghost_learn_stop` to get the recorded actions
6. Analyze the actions: identify parameters (email addresses, names, URLs that should be substitutable)
7. Synthesize a recipe JSON from the actions (see Recipe JSON Schema below)
8. Verify the recipe works (see "Verifying recipes before saving" below)

### Synthesizing recipes from recordings
When you receive the action array from ghost_learn_stop:
- Each `click` with an `element` context becomes a recipe step with a target Locator
- Use `dom_id` as the primary criterion if available (most stable for web apps)
- Use `role` + `computedNameContains` as secondary criteria
- Each `typeText` where the text looks like user-specific data (email, name, URL) becomes a `{{parameter}}`
- Each `keyPress` for Tab/Return becomes a `press` step
- Each `hotkey` becomes a `hotkey` step
- Each `appSwitch` becomes a `focus` step
- Infer `wait_after` conditions from timing gaps (>2s between actions suggests a page load)
- The recipe must use schema_version 2 and be compatible with ghost_run

### Recipe JSON Schema

Every recipe saved via `ghost_recipe_save` must follow this exact structure.
Missing or misnamed fields will cause a decode error.

```json
{
  "schema_version": 2,
  "name": "my-recipe-name",
  "description": "What this recipe does",
  "app": "Google Chrome",
  "params": {
    "recipient": {
      "type": "string",
      "description": "Email address of recipient",
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
        "criteria": [{"attribute": "AXDOMIdentifier", "value": ":oq"}],
        "computedNameContains": "Compose"
      },
      "wait_after": {
        "condition": "elementExists",
        "value": "To recipients",
        "timeout": 5
      },
      "note": "Click the compose button"
    },
    {
      "id": 2,
      "action": "type",
      "target": {
        "criteria": [{"attribute": "AXRole", "value": "AXComboBox"}],
        "computedNameContains": "To recipients"
      },
      "params": {"text": "{{recipient}}"},
      "note": "Type recipient email"
    },
    {
      "id": 3,
      "action": "press",
      "params": {"key": "tab"},
      "note": "Confirm autocomplete and move to next field"
    },
    {
      "id": 4,
      "action": "wait",
      "params": {"condition": "elementExists", "value": "Subject", "timeout": "5"},
      "note": "Wait for subject field to be ready"
    },
    {
      "id": 5,
      "action": "hotkey",
      "params": {"keys": "cmd,return"},
      "note": "Send with Cmd+Return"
    },
    {
      "id": 6,
      "action": "wait",
      "params": {"condition": "elementGone", "value": "Send", "timeout": "10"},
      "on_failure": "skip",
      "note": "Verify send completed (optional)"
    }
  ],
  "on_failure": "stop"
}
```

**Required fields:**
- `schema_version` -- must be `2`
- `name` -- string, used as filename and recipe identifier
- `description` -- string, shown in `ghost_recipes` listing
- `steps` -- array, at least one step

**Optional top-level fields:**
- `app` -- default app for all steps
- `params` -- parameter definitions (see below)
- `preconditions` -- conditions to check before running
- `on_failure` -- `"stop"` (default) or `"skip"`. No other values are valid.

**Step fields:**
- `id` (required) -- integer, sequential starting from 1
- `action` (required) -- one of: `click`, `type`, `press`, `hotkey`, `focus`, `scroll`, `wait`, `hover`, `long_press`, `drag`
- `target` (optional) -- Locator object for finding the element to act on
- `params` (optional) -- action-specific parameters (see below). All values are **strings**.
- `wait_after` (optional) -- condition to wait for after this step completes
- `note` (optional) -- human-readable description of what this step does
- `on_failure` (optional) -- `"stop"` or `"skip"` (overrides recipe-level setting)

**Action params by type:**

| Action | Required params | Optional params |
|--------|----------------|-----------------|
| `click` | (none -- use `target`) | `x`, `y`, `button` (left/right/middle), `count` (2=double, 3=triple), `query` |
| `type` | `text` | `into`, `clear` ("true"), `app` |
| `press` | `key` | `modifiers` (comma-separated: cmd,shift,option,control), `app` |
| `hotkey` | `keys` (comma-separated: cmd,return) | `app` |
| `focus` | `app` | `window` |
| `scroll` | `direction` (up/down/left/right) | `amount`, `x`, `y`, `app` |
| `wait` | `condition` | `value`, `timeout` (seconds as string, default "10") |
| `hover` | (none -- use `target`) | `x`, `y`, `query`, `app` |
| `long_press` | (none -- use `target`) | `x`, `y`, `duration`, `button`, `query`, `app` |
| `drag` | `to_x`, `to_y` | `from_x`, `from_y`, `duration`, `hold_duration`, `query`, `app` |

Key names for `press`: return, tab, escape, space, delete, up, down, left, right, f1-f12.

**Important:** The `wait` action is different from `wait_after`. A `wait` step is
a standalone polling action with params like `{"condition": "elementExists", "value": "...", "timeout": "5"}`.
Note that `timeout` is a **string** (all step params are strings). `wait_after` is a
structured object on any step with `timeout` as a **number**. See the bundled
`slack-send` recipe for an example using both.

**Target (Locator) fields:**
- `criteria` -- array of `{"attribute": "...", "value": "..."}` objects. Common attributes:
  - `AXRole` -- element type (AXButton, AXTextField, AXTextArea, AXComboBox, AXLink, AXStaticText)
  - `AXDOMIdentifier` -- DOM id for web apps (most reliable for Chrome/Electron)
- `computedNameContains` -- string, matches element name/title/description (most useful field)
- `matchAll` -- boolean, whether all criteria must match (default: true)

**wait_after fields:**
- `condition` -- one of: `elementExists`, `elementGone`, `urlContains`, `titleContains`, `delay`
- `value` -- string to match against (not needed for `delay`)
- `timeout` -- number (seconds, default: 10). For `delay`, this is the sleep duration.

**Param definitions** (top-level `params` object):
- Each key is the parameter name
- `type` (required) -- `"string"`
- `description` (required) -- what this parameter is for
- `required` (optional) -- boolean

Use `{{param_name}}` in step params to substitute recipe parameters at runtime.

### Verifying recipes before saving

**Always test a recipe before considering it done.** This applies whether the recipe
came from self-learning mode or was authored from scratch.

1. Save the recipe with `ghost_recipe_save`
2. Ask the user for safe test parameters (especially for recipes that send messages,
   emails, or modify files -- you don't want to send a real email during testing)
3. Run with `ghost_run` using the test parameters
4. If the run fails: `ghost_recipe_delete`, fix the JSON, go back to step 1
5. Repeat until the recipe runs successfully end-to-end
6. Tell the user the recipe is verified and ready

**Do not skip verification.** A recipe that fails on first use is worse than no
recipe at all.

### Requirements
- Input Monitoring permission required (separate from Accessibility)
- Only records between ghost_learn_start and ghost_learn_stop (no background monitoring)
- Password fields are automatically redacted
- Recordings are ephemeral (in memory only, never written to disk)
- Do not call ghost_run while ghost_learn is active (synthetic events would be re-recorded)

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
| ghost_annotate | Labeled screenshot with click coordinates | No |
| ghost_click | Click element or coordinates | Auto |
| ghost_type | Type text, optionally into a field | Auto |
| ghost_hover | Move cursor to trigger tooltips/hover effects | Yes - use `app` |
| ghost_long_press | Press and hold for context menus | Yes - use `app` |
| ghost_drag | Drag between points or elements | Yes - use `app` |
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
| ghost_learn_start | Start observing user actions for learning | No |
| ghost_learn_stop | Stop observing and return recorded actions | No |
| ghost_learn_status | Check learning mode status | No |
