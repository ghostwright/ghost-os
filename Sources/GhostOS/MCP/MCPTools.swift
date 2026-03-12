// MCPTools.swift - MCP tool definitions (names, descriptions, parameter schemas)
//
// All 29 tools defined here. Agent sees these descriptions and schemas.
// Make them excellent - they're the contract between Ghost OS and the agent.

import Foundation

/// Tool definitions for the MCP server.
public enum MCPTools {

    /// All tool definitions as MCP-compatible dictionaries.
    public static func definitions() -> [[String: Any]] {
        var all = perception + actions + wait
        all += recipes + vision + annotate + learning
        return all
    }

    // MARK: - Perception Tools (7)

    private static let perception: [[String: Any]] = [
        tool(
            name: "ghost_context",
            description: "Get orientation: focused app, window title, URL (browsers), focused element, and interactive elements. Call this before acting on any app.",
            properties: [
                "app": prop("string", "App name to get context for. If omitted, returns focused app."),
            ]
        ),
        tool(
            name: "ghost_state",
            description: "List all running apps and their windows with titles, positions, and sizes.",
            properties: [
                "app": prop("string", "Filter to a specific app."),
            ]
        ),
        tool(
            name: "ghost_find",
            description: "Find elements in any app. Returns matching elements with role, name, position, and available actions.",
            properties: [
                "query": prop("string", "Text to search for (matches title, value, identifier, description)."),
                "role": prop("string", "AX role filter (e.g. AXButton, AXTextField, AXLink)."),
                "dom_id": prop("string", "Find by DOM id (web apps, bypasses depth limits)."),
                "dom_class": prop("string", "Find by CSS class."),
                "identifier": prop("string", "Find by AX identifier."),
                "app": prop("string", "Which app to search in."),
                "depth": prop("integer", "Max search depth (default: 25, max: 100)."),
            ]
        ),
        tool(
            name: "ghost_read",
            description: "Read text content from screen. Returns concatenated text from the element subtree.",
            properties: [
                "app": prop("string", "Which app to read from."),
                "query": prop("string", "Narrow to specific element."),
                "depth": prop("integer", "How deep to read (default: 25)."),
            ]
        ),
        tool(
            name: "ghost_inspect",
            description: "Full metadata about one element. Call this before acting on something you're unsure about. Returns role, title, position, size, actionable status, supported actions, editable, DOM id, and more.",
            properties: [
                "query": prop("string", "Element to inspect."),
                "role": prop("string", "AX role filter."),
                "dom_id": prop("string", "Find by DOM id."),
                "app": prop("string", "Which app."),
            ],
            required: ["query"]
        ),
        tool(
            name: "ghost_element_at",
            description: "What element is at this screen position? Bridges screenshots and accessibility tree.",
            properties: [
                "x": prop("number", "X coordinate."),
                "y": prop("number", "Y coordinate."),
            ],
            required: ["x", "y"]
        ),
        tool(
            name: "ghost_screenshot",
            description: "Take a screenshot for visual debugging. Returns base64 PNG.",
            properties: [
                "app": prop("string", "Screenshot specific app window."),
                "full_resolution": prop("boolean", "Native resolution instead of 1280px resize (default: false)."),
            ]
        ),
    ]

    // MARK: - Action Tools (10)

    private static let actions: [[String: Any]] = [
        tool(
            name: "ghost_click",
            description: "Click an element. Tries AX-native first, falls back to synthetic click. Returns post-click context.",
            properties: [
                "query": prop("string", "What to click (element text/name)."),
                "role": prop("string", "AX role filter."),
                "dom_id": prop("string", "Click by DOM id."),
                "app": prop("string", "Which app (auto-focuses if needed)."),
                "x": prop("number", "Click at X coordinate instead of element."),
                "y": prop("number", "Click at Y coordinate."),
                "button": prop("string", "left (default), right, or middle."),
                "count": prop("integer", "Click count: 1=single, 2=double, 3=triple."),
            ]
        ),
        tool(
            name: "ghost_type",
            description: "Type text into a field. If 'into' is specified, finds the field first. Returns readback verification.",
            properties: [
                "text": prop("string", "Text to type."),
                "into": prop("string", "Target field name (finds via accessibility). If omitted, types at focus."),
                "dom_id": prop("string", "Target field by DOM id."),
                "app": prop("string", "Which app."),
                "clear": prop("boolean", "Clear field before typing (default: false)."),
            ],
            required: ["text"]
        ),
        tool(
            name: "ghost_press",
            description: "Press a single key. Always include app parameter to ensure correct target.",
            properties: [
                "key": prop("string", "Key name: return, tab, escape, space, delete, up, down, left, right, f1-f12."),
                "modifiers": propArray("string", "Modifier keys: cmd, shift, option, control."),
                "app": prop("string", "Auto-focus this app first (IMPORTANT for synthetic input)."),
            ],
            required: ["key"]
        ),
        tool(
            name: "ghost_hotkey",
            description: "Press a key combination. Modifier keys are auto-cleared afterward. Always include app parameter.",
            properties: [
                "keys": propArray("string", "Key combo, e.g. [\"cmd\", \"return\"] or [\"cmd\", \"shift\", \"p\"]."),
                "app": prop("string", "Auto-focus this app first (IMPORTANT for synthetic input)."),
            ],
            required: ["keys"]
        ),
        tool(
            name: "ghost_scroll",
            description: "Scroll content in a direction.",
            properties: [
                "direction": prop("string", "up, down, left, or right."),
                "amount": prop("integer", "Scroll amount in lines (default: 3)."),
                "app": prop("string", "Auto-focus this app first."),
                "x": prop("number", "Scroll at specific X position."),
                "y": prop("number", "Scroll at specific Y position."),
            ],
            required: ["direction"]
        ),
        tool(
            name: "ghost_hover",
            description: "Move cursor to an element or position WITHOUT clicking. Triggers tooltips, CSS :hover, menu navigation. Use ghost_read after to see what appeared.",
            properties: [
                "query": prop("string", "Element to hover over (centers cursor on element)."),
                "role": prop("string", "AX role filter."),
                "dom_id": prop("string", "Hover by DOM id."),
                "app": prop("string", "Which app (auto-focuses — hover effects need focus)."),
                "x": prop("number", "Hover at X coordinate instead of element."),
                "y": prop("number", "Hover at Y coordinate."),
            ]
        ),
        tool(
            name: "ghost_long_press",
            description: "Press and hold at a position for a duration. Triggers long-press menus, Force Touch previews, and drag-initiation behaviors.",
            properties: [
                "query": prop("string", "Element to long-press (centers on element)."),
                "role": prop("string", "AX role filter."),
                "dom_id": prop("string", "Long-press by DOM id."),
                "app": prop("string", "Which app (auto-focuses)."),
                "x": prop("number", "Long-press at X coordinate."),
                "y": prop("number", "Long-press at Y coordinate."),
                "duration": prop("number", "Hold duration in seconds (default: 1.0)."),
                "button": prop("string", "left (default) or right."),
            ]
        ),
        tool(
            name: "ghost_drag",
            description: "Drag from one point to another (left-button only). Find source element by query or specify coordinates. Use for: moving files, adjusting sliders, reordering lists, selecting text, resizing panes.",
            properties: [
                "from_x": prop("number", "Start X coordinate (logical screen points)."),
                "from_y": prop("number", "Start Y coordinate."),
                "to_x": prop("number", "End X coordinate (logical screen points)."),
                "to_y": prop("number", "End Y coordinate."),
                "query": prop("string", "Element to drag (finds center as start point). Alternative to from_x/from_y."),
                "role": prop("string", "AX role filter when using query."),
                "dom_id": prop("string", "Find drag source by DOM id."),
                "app": prop("string", "Which app (auto-focuses for synthetic input)."),
                "duration": prop("number", "Drag duration in seconds (default: 0.5). Longer = smoother/more reliable."),
                "hold_duration": prop("number", "Seconds to hold at start before moving (default: 0.1). Increase for Finder file drags."),
            ],
            required: ["to_x", "to_y"]
        ),
        tool(
            name: "ghost_focus",
            description: "Bring an app or window to the front.",
            properties: [
                "app": prop("string", "App name to focus."),
                "window": prop("string", "Window title substring to focus specific window."),
            ],
            required: ["app"]
        ),
        tool(
            name: "ghost_window",
            description: "Window management: minimize, maximize, close, restore, move, resize, or list windows.",
            properties: [
                "action": prop("string", "minimize, maximize, close, restore, move, resize, or list."),
                "app": prop("string", "Target app."),
                "window": prop("string", "Window title (if omitted, acts on frontmost window of app)."),
                "x": prop("number", "X position for move."),
                "y": prop("number", "Y position for move."),
                "width": prop("number", "Width for resize."),
                "height": prop("number", "Height for resize."),
            ],
            required: ["action", "app"]
        ),
    ]

    // MARK: - Wait Tool (1)

    private static let wait: [[String: Any]] = [
        tool(
            name: "ghost_wait",
            description: "Wait for a condition instead of using fixed delays. Polls until condition is met or timeout.",
            properties: [
                "condition": prop("string", "urlContains, titleContains, elementExists, elementGone, urlChanged, titleChanged."),
                "value": prop("string", "Match value (required for urlContains, titleContains, elementExists, elementGone)."),
                "timeout": prop("number", "Max seconds to wait (default: 10)."),
                "interval": prop("number", "Poll interval in seconds (default: 0.5)."),
                "app": prop("string", "App to check against."),
            ],
            required: ["condition"]
        ),
    ]

    // MARK: - Recipe Tools (5)

    private static let recipes: [[String: Any]] = [
        tool(
            name: "ghost_recipes",
            description: "List all installed recipes with descriptions and parameters. ALWAYS check this first before doing multi-step tasks manually.",
            properties: [:]
        ),
        tool(
            name: "ghost_run",
            description: "Execute a recipe with parameter substitution. Returns step-by-step results.",
            properties: [
                "recipe": prop("string", "Recipe name."),
                "params": prop("object", "Parameter values for substitution."),
            ],
            required: ["recipe"]
        ),
        tool(
            name: "ghost_recipe_show",
            description: "View full recipe details: steps, parameters, preconditions.",
            properties: [
                "name": prop("string", "Recipe name."),
            ],
            required: ["name"]
        ),
        tool(
            name: "ghost_recipe_save",
            description: "Install a new recipe from JSON.",
            properties: [
                "recipe_json": prop("string", "Complete recipe JSON string."),
            ],
            required: ["recipe_json"]
        ),
        tool(
            name: "ghost_recipe_delete",
            description: "Delete a recipe.",
            properties: [
                "name": prop("string", "Recipe name to delete."),
            ],
            required: ["name"]
        ),
    ]

    // MARK: - Vision Tools (2)

    private static let vision: [[String: Any]] = [
        tool(
            name: "ghost_parse_screen",
            description: "Detect ALL interactive UI elements on screen using vision (YOLO + VLM). Returns bounding boxes, types, and labels. Use when AX tree returns generic elements (web apps in Chrome). Requires the vision sidecar to be running.",
            properties: [
                "app": prop("string", "Screenshot specific app window."),
                "full_resolution": prop("boolean", "Native resolution instead of 1280px resize (default: false)."),
            ]
        ),
        tool(
            name: "ghost_ground",
            description: "Find precise screen coordinates for a described UI element using vision (VLM). Use when ghost_find can't locate the element or returns AXGroup elements. Pass a text description of what to click. Requires the vision sidecar to be running.",
            properties: [
                "description": prop("string", "What to find (e.g. 'Compose button', 'Send button', 'search field')."),
                "app": prop("string", "Screenshot specific app window."),
                "crop_box": propArray("number", "Optional crop region [x1, y1, x2, y2] in logical points. Dramatically improves accuracy for overlapping panels (e.g. compose popup over inbox)."),
            ],
            required: ["description"]
        ),
    ]

    // MARK: - Annotate Tool (1)

    private static let annotate: [[String: Any]] = [
        tool(
            name: "ghost_annotate",
            description: "Screenshot with numbered labels [1], [2], [3]... on interactive UI elements. Returns an annotated image and a text index mapping each label to its element's role, name, and click coordinates. Call this for visual orientation, then use ghost_click with the x/y from the index. Zero ML — instant, uses the accessibility tree.",
            properties: [
                "app": prop("string", "App to annotate. If omitted, uses frontmost app."),
                "roles": propArray("string", "AX roles to include (default: buttons, links, fields, checkboxes, combos, tabs, sliders). Example: [\"AXButton\", \"AXLink\"]."),
                "max_labels": prop("integer", "Maximum number of labels (default: 50, max: 100). Lower values reduce clutter."),
            ]
        ),
    ]

    // MARK: - Learning Tools (3)

    private static let learning: [[String: Any]] = [
        tool(
            name: "ghost_learn_start",
            description: "Start observing the user's actions for workflow learning. Ghost OS records clicks, keystrokes, and app switches while the user performs a task manually. Call ghost_learn_stop when the user says they are done. Requires Input Monitoring permission (System Settings > Privacy & Security > Input Monitoring).",
            properties: [
                "task_description": prop("string", "Brief description of what the user is about to do (e.g., 'send an email in Gmail'). Helps the synthesis step."),
            ]
        ),
        tool(
            name: "ghost_learn_stop",
            description: "Stop observing and return the recorded action sequence. Returns an array of observed actions with AX context (element role, title, DOM id, computed name) for each click and typed text. Use this data to synthesize a recipe via ghost_recipe_save.",
            properties: [:]
        ),
        tool(
            name: "ghost_learn_status",
            description: "Check if learning mode is active, how many actions have been recorded, and how long the session has been running.",
            properties: [:]
        ),
    ]

    // MARK: - Schema Helpers

    private static func tool(
        name: String,
        description: String,
        properties: [String: [String: Any]],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
        ]
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static func propArray(_ itemType: String, _ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": itemType], "description": description]
    }
}
