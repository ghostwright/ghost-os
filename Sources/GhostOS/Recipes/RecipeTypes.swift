// RecipeTypes.swift - v2 recipe data structures
//
// Recipes use Locator-based targets, wait conditions, and preconditions.
// Schema version 2 format.

import AXorcist
import Foundation

/// A Ghost OS recipe: a parameterized, replayable workflow.
public struct Recipe: Codable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let description: String
    public let app: String?
    public let params: [String: RecipeParam]?
    public let preconditions: RecipePreconditions?
    public let steps: [RecipeStep]
    public let onFailure: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, description, app, params, preconditions, steps
        case onFailure = "on_failure"
    }
}

/// A recipe parameter definition.
public struct RecipeParam: Codable, Sendable {
    public let type: String
    public let description: String
    public let required: Bool?
}

/// Preconditions that must be true before a recipe runs.
public struct RecipePreconditions: Codable, Sendable {
    public let appRunning: String?
    public let urlContains: String?

    enum CodingKeys: String, CodingKey {
        case appRunning = "app_running"
        case urlContains = "url_contains"
    }
}

/// A single step in a recipe.
public struct RecipeStep: Codable, Sendable {
    public let id: Int
    public let action: String
    public let target: Locator?
    public let params: [String: String]?
    public let waitAfter: RecipeWaitCondition?
    public let note: String?
    public let onFailure: String?

    enum CodingKeys: String, CodingKey {
        case id, action, target, params
        case waitAfter = "wait_after"
        case note
        case onFailure = "on_failure"
    }
}

/// A wait condition for recipe steps.
public struct RecipeWaitCondition: Codable, Sendable {
    public let condition: String
    public let target: Locator?
    public let value: String?
    public let timeout: Double?
}

/// Result of running a recipe.
public struct RecipeRunResult: Sendable {
    public let recipeName: String
    public let success: Bool
    public let stepsCompleted: Int
    public let totalSteps: Int
    public let stepResults: [RecipeStepResult]
    public let error: String?
}

/// Result of a single recipe step.
public struct RecipeStepResult: Sendable {
    public let stepId: Int
    public let action: String
    public let success: Bool
    public let durationMs: Int
    public let error: String?
    public let note: String?
}
