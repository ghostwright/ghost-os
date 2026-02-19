// MCPDispatch.swift - Route MCP tool calls to module functions
//
// Maps tool names to handler functions. Wraps each call in a timeout.
// Formats responses as MCP content arrays.

import Foundation

/// Routes MCP tool calls to the appropriate module function.
public enum MCPDispatch {

    /// Handle a tools/call request. Returns MCP-formatted result.
    public static func handle(_ params: [String: Any]) -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            return errorContent("Missing tool name")
        }

        let args = params["arguments"] as? [String: Any] ?? [:]
        Log.info("Tool call: \(toolName)")

        // Screenshot returns MCP image content directly (not text-wrapped JSON)
        if toolName == "ghost_screenshot" {
            return handleScreenshot(args)
        }

        let result = dispatch(tool: toolName, args: args)
        return formatResult(result, toolName: toolName)
    }

    /// Screenshot handler returns MCP image content type for inline display.
    private static func handleScreenshot(_ args: [String: Any]) -> [String: Any] {
        let result = Perception.screenshot(
            appName: str(args, "app"),
            fullResolution: bool(args, "full_resolution") ?? false
        )

        guard result.success,
              let data = result.data,
              let base64 = data["image"] as? String
        else {
            return formatResult(result, toolName: "ghost_screenshot")
        }

        // Return as MCP image content for inline display in Claude Code
        let mimeType = data["mime_type"] as? String ?? "image/png"
        return [
            "content": [
                [
                    "type": "image",
                    "data": base64,
                    "mimeType": mimeType,
                ] as [String: Any],
            ],
            "isError": false,
        ]
    }

    // MARK: - Dispatch

    private static func dispatch(tool: String, args: [String: Any]) -> ToolResult {
        switch tool {

        // Perception
        case "ghost_context":
            return Perception.getContext(appName: str(args, "app"))

        case "ghost_state":
            return Perception.getState(appName: str(args, "app"))

        case "ghost_find":
            return Perception.findElements(
                query: str(args, "query"),
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                domClass: str(args, "dom_class"),
                identifier: str(args, "identifier"),
                appName: str(args, "app"),
                depth: int(args, "depth")
            )

        case "ghost_read":
            return Perception.readContent(
                appName: str(args, "app"),
                query: str(args, "query"),
                depth: int(args, "depth")
            )

        case "ghost_inspect":
            guard let query = str(args, "query") else {
                return ToolResult(success: false, error: "Missing required parameter: query")
            }
            return Perception.inspect(
                query: query,
                role: str(args, "role"),
                domId: str(args, "dom_id"),
                appName: str(args, "app")
            )

        case "ghost_element_at":
            guard let x = double(args, "x"), let y = double(args, "y") else {
                return ToolResult(success: false, error: "Missing required parameters: x, y")
            }
            return Perception.elementAt(x: x, y: y)

        case "ghost_screenshot":
            return Perception.screenshot(
                appName: str(args, "app"),
                fullResolution: bool(args, "full_resolution") ?? false
            )

        // Actions
        case "ghost_click":
            return FocusManager.withFocusRestore {
                Actions.click(
                    query: str(args, "query"),
                    role: str(args, "role"),
                    domId: str(args, "dom_id"),
                    appName: str(args, "app"),
                    x: double(args, "x"),
                    y: double(args, "y"),
                    button: str(args, "button"),
                    count: int(args, "count")
                )
            }

        case "ghost_type":
            guard let text = str(args, "text") else {
                return ToolResult(success: false, error: "Missing required parameter: text")
            }
            return FocusManager.withFocusRestore {
                Actions.typeText(
                    text: text,
                    into: str(args, "into"),
                    domId: str(args, "dom_id"),
                    appName: str(args, "app"),
                    clear: bool(args, "clear") ?? false
                )
            }

        case "ghost_press":
            guard let key = str(args, "key") else {
                return ToolResult(success: false, error: "Missing required parameter: key")
            }
            let modifiers = (args["modifiers"] as? [String])
            return FocusManager.withFocusRestore {
                Actions.pressKey(key: key, modifiers: modifiers, appName: str(args, "app"))
            }

        case "ghost_hotkey":
            guard let keys = args["keys"] as? [String] else {
                return ToolResult(success: false, error: "Missing required parameter: keys (array of strings)")
            }
            return FocusManager.withFocusRestore {
                Actions.hotkey(keys: keys, appName: str(args, "app"))
            }

        case "ghost_scroll":
            guard let direction = str(args, "direction") else {
                return ToolResult(success: false, error: "Missing required parameter: direction")
            }
            return FocusManager.withFocusRestore {
                Actions.scroll(
                    direction: direction,
                    amount: int(args, "amount"),
                    appName: str(args, "app"),
                    x: double(args, "x"),
                    y: double(args, "y")
                )
            }

        case "ghost_focus":
            guard let app = str(args, "app") else {
                return ToolResult(success: false, error: "Missing required parameter: app")
            }
            return FocusManager.focus(appName: app, windowTitle: str(args, "window"))

        case "ghost_window":
            guard let action = str(args, "action"),
                  let app = str(args, "app")
            else {
                return ToolResult(success: false, error: "Missing required parameters: action, app")
            }
            return Actions.manageWindow(
                action: action,
                appName: app,
                windowTitle: str(args, "window"),
                x: double(args, "x"),
                y: double(args, "y"),
                width: double(args, "width"),
                height: double(args, "height")
            )

        // Wait
        case "ghost_wait":
            guard let condition = str(args, "condition") else {
                return ToolResult(success: false, error: "Missing required parameter: condition")
            }
            return WaitManager.waitFor(
                condition: condition,
                value: str(args, "value"),
                appName: str(args, "app"),
                timeout: double(args, "timeout") ?? 10,
                interval: double(args, "interval") ?? 0.5
            )

        // Recipes
        case "ghost_recipes":
            let recipes = RecipeStore.listRecipes()
            let summaries: [[String: Any]] = recipes.map { recipe in
                var summary: [String: Any] = [
                    "name": recipe.name,
                    "description": recipe.description,
                ]
                if let app = recipe.app { summary["app"] = app }
                if let params = recipe.params {
                    summary["params"] = params.map { key, param in
                        ["name": key, "type": param.type, "description": param.description,
                         "required": param.required ?? false] as [String: Any]
                    }
                }
                return summary
            }
            return ToolResult(success: true, data: ["recipes": summaries, "count": summaries.count])

        case "ghost_run":
            return ToolResult(success: true, data: ["note": "ghost_run: Phase 5 implementation"])

        case "ghost_recipe_show":
            guard let name = str(args, "name") else {
                return ToolResult(success: false, error: "Missing required parameter: name")
            }
            guard let recipe = RecipeStore.loadRecipe(named: name) else {
                return ToolResult(
                    success: false,
                    error: "Recipe '\(name)' not found",
                    suggestion: "Use ghost_recipes to list available recipes"
                )
            }
            if let data = try? JSONEncoder().encode(recipe),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return ToolResult(success: true, data: dict)
            }
            return ToolResult(success: false, error: "Failed to serialize recipe")

        case "ghost_recipe_save":
            guard let jsonStr = str(args, "recipe_json") else {
                return ToolResult(success: false, error: "Missing required parameter: recipe_json")
            }
            do {
                let name = try RecipeStore.saveRecipeJSON(jsonStr)
                return ToolResult(success: true, data: ["saved": name])
            } catch {
                return ToolResult(success: false, error: "Failed to save recipe: \(error)")
            }

        case "ghost_recipe_delete":
            guard let name = str(args, "name") else {
                return ToolResult(success: false, error: "Missing required parameter: name")
            }
            let deleted = RecipeStore.deleteRecipe(named: name)
            return ToolResult(
                success: deleted,
                data: deleted ? ["deleted": name] : nil,
                error: deleted ? nil : "Recipe '\(name)' not found"
            )

        default:
            return ToolResult(success: false, error: "Unknown tool: \(tool)")
        }
    }

    // MARK: - Response Formatting

    /// Format a ToolResult as MCP content array.
    private static func formatResult(_ result: ToolResult, toolName: String) -> [String: Any] {
        let dict = result.toDict()

        // Serialize to JSON string for MCP text content
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let jsonStr = String(data: data, encoding: .utf8)
        {
            return [
                "content": [
                    ["type": "text", "text": jsonStr],
                ],
                "isError": !result.success,
            ]
        }

        return errorContent("Failed to serialize response for \(toolName)")
    }

    static func errorContent(_ message: String) -> [String: Any] {
        [
            "content": [
                ["type": "text", "text": "{\"success\":false,\"error\":\"\(message)\"}"],
            ],
            "isError": true,
        ]
    }

    // MARK: - Parameter Helpers

    private static func str(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        return nil
    }

    private static func double(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        return nil
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }
}
