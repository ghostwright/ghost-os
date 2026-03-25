// RecipeEngine.swift - Step-by-step recipe execution
//
// Executes recipes with:
// - Smart precondition checking (app running, URL correct, with diagnostics)
// - Parameter substitution ({{param}} in step params)
// - Focus management at recipe level (save at start, restore at end)
// - Per-step: find target, execute action, wait for condition
// - Failure handling: screenshot + context on failure, stop or skip policy
// - Step-by-step results with timing

import AppKit
import AXorcist
import Foundation

/// Executes recipes step by step with verification.
public enum RecipeEngine {

    /// Run a recipe with parameter substitution.
    public static func run(recipe: Recipe, params: [String: String]) -> ToolResult {
        let startTime = Date()

        // 1. Validate parameters
        if let paramDefs = recipe.params {
            for (name, def) in paramDefs {
                if def.required == true && params[name] == nil {
                    return ToolResult(
                        success: false,
                        error: "Missing required parameter: '\(name)' (\(def.description))",
                        suggestion: "Provide all required parameters. Use ghost_recipe_show to see parameter details."
                    )
                }
            }
        }

        // 2. Check preconditions with smart diagnostics
        if let preconditions = recipe.preconditions {
            let precheck = checkPreconditions(preconditions, recipeName: recipe.name)
            if !precheck.success {
                return precheck
            }
        }

        // 3. Save focus state (restore when recipe completes or fails)
        let savedApp = FocusManager.saveFrontmostApp()
        defer { FocusManager.restoreFocus(to: savedApp) }

        // 4. Focus the recipe's app if specified
        if let app = recipe.app {
            let focusResult = FocusManager.focus(appName: app)
            if !focusResult.success {
                return ToolResult(
                    success: false,
                    error: "Failed to focus '\(app)' for recipe '\(recipe.name)'",
                    suggestion: "Ensure the app is running. Use ghost_state to check."
                )
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Execute steps
        var stepResults: [RecipeStepResult] = []
        let globalFailurePolicy = recipe.onFailure ?? "stop"

        for step in recipe.steps {
            let stepStart = Date()

            // Substitute parameters in step params
            let resolvedParams = substituteParams(step.params, with: params)

            // Execute the step
            let result = executeStep(
                step: step,
                resolvedParams: resolvedParams,
                appName: recipe.app
            )

            let durationMs = Int(Date().timeIntervalSince(stepStart) * 1000)
            let stepResult = RecipeStepResult(
                stepId: step.id,
                action: step.action,
                success: result.success,
                durationMs: durationMs,
                error: result.error,
                note: step.note
            )
            stepResults.append(stepResult)

            if !result.success {
                // AUTO-HEAL: Before giving up, try CDP-based element finding for
                // click/type actions in browser apps. This handles the common case
                // where a web app updated its DOM IDs but the element text is the same.
                if let _ = attemptAutoHeal(
                    step: step, resolvedParams: resolvedParams, appName: recipe.app
                ) {
                    // Auto-heal succeeded — update the step result
                    let healDuration = Int(Date().timeIntervalSince(stepStart) * 1000)
                    stepResults[stepResults.count - 1] = RecipeStepResult(
                        stepId: step.id,
                        action: step.action,
                        success: true,
                        durationMs: healDuration,
                        error: nil,
                        note: (step.note ?? step.action) + " [auto-healed via CDP]"
                    )
                    Log.info("Recipe '\(recipe.name)' step \(step.id) auto-healed via CDP")
                    // Continue to wait_after handling below (don't return)
                } else {
                    // Auto-heal failed — apply normal failure policy
                    let failurePolicy = step.onFailure ?? globalFailurePolicy

                    if failurePolicy == "skip" {
                        Log.info("Recipe '\(recipe.name)' step \(step.id) failed (skipping): \(result.error ?? "")")
                        continue
                    }

                    // Stop: return failure with diagnostics
                let totalDuration = Int(Date().timeIntervalSince(startTime) * 1000)

                // Capture failure context
                var failureData: [String: Any] = [
                    "recipe": recipe.name,
                    "failed_step": step.id,
                    "failed_action": step.action,
                    "error": result.error ?? "Unknown error",
                    "steps_completed": stepResults.count - 1,
                    "total_steps": recipe.steps.count,
                    "duration_ms": totalDuration,
                    "step_results": stepResults.map { stepResultDict($0) },
                ]

                // Get current context for debugging
                if let app = recipe.app {
                    let context = Perception.getContext(appName: app)
                    if let contextData = context.data {
                        failureData["current_context"] = contextData
                    }
                }

                if let note = step.note {
                    failureData["failed_note"] = note
                }

                return ToolResult(
                    success: false,
                    data: failureData,
                    error: "Recipe '\(recipe.name)' failed at step \(step.id) (\(step.note ?? step.action)): \(result.error ?? "")",
                    suggestion: "Check the current_context and failed_step details. Use ghost_screenshot for visual debugging."
                )
                } // end else (auto-heal failed)
            }

            // Handle wait_after condition (substitute {{params}} in value)
            if let waitAfter = step.waitAfter {
                let resolvedWaitAfter = substituteWaitAfter(waitAfter, with: params)
                let waitResult = handleWaitAfter(resolvedWaitAfter, appName: recipe.app)
                if !waitResult.success {
                    let totalDuration = Int(Date().timeIntervalSince(startTime) * 1000)

                    return ToolResult(
                        success: false,
                        data: [
                            "recipe": recipe.name,
                            "failed_step": step.id,
                            "error": "Action succeeded but expected state didn't materialize: \(waitResult.error ?? "")",
                            "steps_completed": stepResults.count,
                            "total_steps": recipe.steps.count,
                            "duration_ms": totalDuration,
                            "step_results": stepResults.map { stepResultDict($0) },
                        ],
                        error: "Recipe '\(recipe.name)' step \(step.id) wait_after failed: \(waitResult.error ?? "")",
                        suggestion: "The action succeeded but the expected result didn't appear. Use ghost_context and ghost_screenshot to diagnose."
                    )
                }
            }

            Log.info("Recipe '\(recipe.name)' step \(step.id) OK: \(step.note ?? step.action)")
        }

        // 6. All steps completed
        let totalDuration = Int(Date().timeIntervalSince(startTime) * 1000)

        return ToolResult(
            success: true,
            data: [
                "recipe": recipe.name,
                "steps_completed": stepResults.count,
                "total_steps": recipe.steps.count,
                "duration_ms": totalDuration,
                "step_results": stepResults.map { stepResultDict($0) },
            ]
        )
    }

    // MARK: - Precondition Checking

    /// Check preconditions with smart diagnostics.
    /// Instead of just "failed", tells the agent exactly what's wrong and how to fix it.
    private static func checkPreconditions(_ pre: RecipePreconditions, recipeName: String) -> ToolResult {
        // Check if app is running
        if let requiredApp = pre.appRunning {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let found = apps.first {
                $0.localizedName?.localizedCaseInsensitiveContains(requiredApp) == true
            }
            if found == nil {
                let runningNames = apps.compactMap { $0.localizedName }.joined(separator: ", ")
                return ToolResult(
                    success: false,
                    error: "Precondition failed: '\(requiredApp)' is not running",
                    suggestion: "Start \(requiredApp) first. Running apps: \(runningNames)"
                )
            }
        }

        // Check URL
        if let requiredURL = pre.urlContains {
            let appName = pre.appRunning ?? "Google Chrome"
            let context = Perception.getContext(appName: appName)
            let currentURL = context.context?.url ?? "(no URL)"

            if !currentURL.localizedCaseInsensitiveContains(requiredURL) {
                return ToolResult(
                    success: false,
                    error: "Precondition failed: URL should contain '\(requiredURL)' but current URL is '\(currentURL)'",
                    suggestion: "Navigate to the correct page first. Use ghost_hotkey keys:[\"cmd\",\"l\"] then ghost_type to go to the right URL."
                )
            }
        }

        return ToolResult(success: true)
    }

    // MARK: - Parameter Substitution

    /// Replace {{param}} placeholders in step params with actual values.
    private static func substituteParams(
        _ stepParams: [String: String]?,
        with values: [String: String]
    ) -> [String: String]? {
        guard let stepParams else { return nil }
        var resolved: [String: String] = [:]
        for (key, value) in stepParams {
            var result = value
            // Replace all {{paramName}} occurrences
            for (paramName, paramValue) in values {
                result = result.replacingOccurrences(of: "{{\(paramName)}}", with: paramValue)
            }
            resolved[key] = result
        }
        return resolved
    }

    /// Replace {{param}} placeholders in a wait_after condition's value.
    private static func substituteWaitAfter(
        _ waitAfter: RecipeWaitCondition,
        with values: [String: String]
    ) -> RecipeWaitCondition {
        guard var value = waitAfter.value else { return waitAfter }
        for (paramName, paramValue) in values {
            value = value.replacingOccurrences(of: "{{\(paramName)}}", with: paramValue)
        }
        return RecipeWaitCondition(
            condition: waitAfter.condition,
            target: waitAfter.target,
            value: value,
            timeout: waitAfter.timeout
        )
    }

    // MARK: - Auto-Heal

    /// Attempt to recover a failed recipe step using CDP element finding.
    ///
    /// When a click/type step fails (usually because a DOM ID changed after a
    /// web app update), this function tries to find the target element via CDP
    /// using the step's computedNameContains text. If found, it re-executes the
    /// action with the CDP-found coordinates.
    ///
    /// Only applies to click/type/hover actions in browser apps with CDP available.
    /// Returns nil if auto-heal is not applicable or fails.
    private static func attemptAutoHeal(
        step: RecipeStep,
        resolvedParams: [String: String]?,
        appName: String?
    ) -> ToolResult? {
        // Only auto-heal click/type/hover actions
        guard ["click", "type", "hover"].contains(step.action) else { return nil }

        // Only for browser apps with CDP
        guard CDPBridge.isBrowserApp(appName), CDPBridge.isAvailable() else { return nil }

        // Need a text query to search for
        let query = step.target?.computedNameContains
            ?? resolvedParams?["query"]
            ?? resolvedParams?["into"]
            ?? resolvedParams?["target"]
        guard let query, !query.isEmpty else { return nil }

        Log.info("Auto-heal: trying CDP for '\(query)' (step \(step.id), action: \(step.action))")

        // Try to find the element via CDP
        guard let cdpElements = CDPBridge.findElements(query: query),
              let first = cdpElements.first
        else {
            Log.info("Auto-heal: CDP found no matches for '\(query)'")
            return nil
        }

        // Get screen coordinates
        let viewportX = first["centerX"] as? Int ?? 0
        let viewportY = first["centerY"] as? Int ?? 0
        let windowOrigin = Perception.chromeWindowOriginPublic(appName: appName)
        let screen = CDPBridge.viewportToScreen(
            viewportX: Double(viewportX), viewportY: Double(viewportY),
            windowX: windowOrigin.x, windowY: windowOrigin.y
        )

        // Re-execute the action with CDP coordinates
        switch step.action {
        case "click":
            let result = Actions.click(
                query: nil, role: nil, domId: nil,
                appName: appName,
                x: screen.x, y: screen.y,
                button: resolvedParams?["button"],
                count: resolvedParams?["count"].flatMap(Int.init)
            )
            return result.success ? result : nil

        case "type":
            // Click the field first, then type
            let clickResult = Actions.click(
                query: nil, role: nil, domId: nil,
                appName: appName,
                x: screen.x, y: screen.y,
                button: nil, count: nil
            )
            guard clickResult.success else { return nil }

            if let text = resolvedParams?["text"] {
                let clear = resolvedParams?["clear"] == "true"
                return Actions.typeText(
                    text: text, into: nil, domId: nil,
                    appName: appName, clear: clear
                )
            }
            return clickResult

        case "hover":
            return Actions.hover(
                query: nil, role: nil, domId: nil,
                appName: appName,
                x: screen.x, y: screen.y
            )

        default:
            return nil
        }
    }

    // MARK: - Step Execution

    /// Execute a single recipe step by dispatching to the appropriate action.
    private static func executeStep(
        step: RecipeStep,
        resolvedParams: [String: String]?,
        appName: String?
    ) -> ToolResult {
        let params = resolvedParams ?? [:]
        let stepApp = params["app"] ?? appName

        switch step.action {
        case "click":
            // Target from Locator or params
            let query = step.target?.computedNameContains ?? params["query"] ?? params["target"]
            let role = step.target?.criteria.first(where: { $0.attribute == "AXRole" })?.value
            let domId = step.target?.criteria.first(where: { $0.attribute == "AXDOMIdentifier" })?.value

            return Actions.click(
                query: query, role: role, domId: domId,
                appName: stepApp,
                x: params["x"].flatMap(Double.init),
                y: params["y"].flatMap(Double.init),
                button: params["button"],
                count: params["count"].flatMap(Int.init)
            )

        case "type":
            guard let text = params["text"] else {
                return ToolResult(success: false, error: "Step \(step.id): 'type' action requires 'text' param")
            }
            let into = step.target?.computedNameContains ?? params["into"] ?? params["target"]
            let domId = step.target?.criteria.first(where: { $0.attribute == "AXDOMIdentifier" })?.value
            let clear = params["clear"] == "true"

            return Actions.typeText(
                text: text, into: into, domId: domId,
                appName: stepApp, clear: clear
            )

        case "press":
            guard let key = params["key"] else {
                return ToolResult(success: false, error: "Step \(step.id): 'press' action requires 'key' param")
            }
            let modifiers = params["modifiers"]?.split(separator: ",").map(String.init)
            return Actions.pressKey(key: key, modifiers: modifiers, appName: stepApp)

        case "hotkey":
            guard let keysStr = params["keys"] else {
                return ToolResult(success: false, error: "Step \(step.id): 'hotkey' action requires 'keys' param")
            }
            let keys = keysStr.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            return Actions.hotkey(keys: keys, appName: stepApp)

        case "focus":
            let app = params["app"] ?? stepApp ?? ""
            return FocusManager.focus(appName: app, windowTitle: params["window"])

        case "scroll":
            let direction = params["direction"] ?? "down"
            return Actions.scroll(
                direction: direction,
                amount: params["amount"].flatMap(Int.init),
                appName: stepApp,
                x: params["x"].flatMap(Double.init),
                y: params["y"].flatMap(Double.init)
            )

        case "hover":
            let query = step.target?.computedNameContains ?? params["query"] ?? params["target"]
            let role = step.target?.criteria.first(where: { $0.attribute == "AXRole" })?.value
            let domId = step.target?.criteria.first(where: { $0.attribute == "AXDOMIdentifier" })?.value
            return Actions.hover(
                query: query, role: role, domId: domId,
                appName: stepApp,
                x: params["x"].flatMap(Double.init),
                y: params["y"].flatMap(Double.init)
            )

        case "long_press":
            let query = step.target?.computedNameContains ?? params["query"] ?? params["target"]
            let role = step.target?.criteria.first(where: { $0.attribute == "AXRole" })?.value
            let domId = step.target?.criteria.first(where: { $0.attribute == "AXDOMIdentifier" })?.value
            return Actions.longPress(
                query: query, role: role, domId: domId,
                appName: stepApp,
                x: params["x"].flatMap(Double.init),
                y: params["y"].flatMap(Double.init),
                duration: params["duration"].flatMap(Double.init),
                button: params["button"]
            )

        case "drag":
            let query = step.target?.computedNameContains ?? params["query"] ?? params["target"]
            let role = step.target?.criteria.first(where: { $0.attribute == "AXRole" })?.value
            let domId = step.target?.criteria.first(where: { $0.attribute == "AXDOMIdentifier" })?.value
            guard let toX = params["to_x"].flatMap(Double.init),
                  let toY = params["to_y"].flatMap(Double.init)
            else {
                return ToolResult(success: false, error: "Step \(step.id): 'drag' action requires 'to_x' and 'to_y' params")
            }
            return Actions.drag(
                query: query, role: role, domId: domId,
                appName: stepApp,
                fromX: params["from_x"].flatMap(Double.init),
                fromY: params["from_y"].flatMap(Double.init),
                toX: toX, toY: toY,
                duration: params["duration"].flatMap(Double.init),
                holdDuration: params["hold_duration"].flatMap(Double.init)
            )

        case "wait":
            // Inline wait step (not wait_after)
            guard let condition = params["condition"] else {
                return ToolResult(success: false, error: "Step \(step.id): 'wait' action requires 'condition' param")
            }
            return WaitManager.waitFor(
                condition: condition,
                value: params["value"],
                appName: stepApp,
                timeout: params["timeout"].flatMap(Double.init) ?? 10,
                interval: 0.5
            )

        default:
            return ToolResult(
                success: false,
                error: "Unknown recipe action: '\(step.action)'",
                suggestion: "Valid actions: click, type, press, hotkey, focus, scroll, hover, long_press, drag, wait"
            )
        }
    }

    // MARK: - Wait After

    /// Handle a step's wait_after condition.
    private static func handleWaitAfter(_ waitAfter: RecipeWaitCondition, appName: String?) -> ToolResult {
        let condition = waitAfter.condition

        // "delay" is a simple sleep, not a polling condition
        if condition == "delay" {
            let seconds = waitAfter.timeout ?? 0.5
            Thread.sleep(forTimeInterval: seconds)
            return ToolResult(success: true)
        }

        // For element-based conditions, use the wait target's computedNameContains
        let value = waitAfter.value ?? waitAfter.target?.computedNameContains

        return WaitManager.waitFor(
            condition: condition,
            value: value,
            appName: appName,
            timeout: waitAfter.timeout ?? 10,
            interval: 0.5
        )
    }

    // MARK: - Result Formatting

    private static func stepResultDict(_ result: RecipeStepResult) -> [String: Any] {
        var dict: [String: Any] = [
            "step": result.stepId,
            "action": result.action,
            "success": result.success,
            "duration_ms": result.durationMs,
        ]
        if let error = result.error { dict["error"] = error }
        if let note = result.note { dict["note"] = note }
        return dict
    }
}
