// MCPTools.swift - MCP tool definitions (names, descriptions, parameter schemas)
//
// All 20 tools defined here. Agent sees these descriptions and schemas.
// Make them excellent - they're the contract between Ghost OS and the agent.

import Foundation

/// Tool definitions for the MCP server.
public enum MCPTools {

    /// All tool definitions as MCP-compatible dictionaries.
    public static func definitions() -> [[String: Any]] {
        perception + actions + wait + recipes + vision
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

    // MARK: - Action Tools (7)

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
