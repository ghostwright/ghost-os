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
            }

            // Handle wait_after condition
            if let waitAfter = step.waitAfter {
                let waitResult = handleWaitAfter(waitAfter, appName: recipe.app)
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
                suggestion: "Valid actions: click, type, press, hotkey, focus, scroll, wait"
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
