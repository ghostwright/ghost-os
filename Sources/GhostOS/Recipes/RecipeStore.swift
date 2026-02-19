// RecipeStore.swift - File-based recipe storage
//
// Loads/saves/lists/deletes recipes from ~/.ghost-os/recipes/

import Foundation

/// File-based recipe storage.
public enum RecipeStore {

    private static let recipesDir = NSString(string: "~/.ghost-os/recipes").expandingTildeInPath

    /// List all available recipes.
    public static func listRecipes() -> [Recipe] {
        let fm = FileManager.default
        ensureDirectory()

        var recipes: [Recipe] = []
        guard let files = try? fm.contentsOfDirectory(atPath: recipesDir) else { return [] }

        let decoder = JSONDecoder()
        for file in files where file.hasSuffix(".json") {
            let path = (recipesDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path) else { continue }
            if let recipe = try? decoder.decode(Recipe.self, from: data) {
                recipes.append(recipe)
            }
        }

        return recipes.sorted { $0.name < $1.name }
    }

    /// Load a specific recipe by name.
    public static func loadRecipe(named name: String) -> Recipe? {
        let path = (recipesDir as NSString).appendingPathComponent("\(name).json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Recipe.self, from: data)
    }

    /// Save a recipe.
    public static func saveRecipe(_ recipe: Recipe) throws {
        ensureDirectory()
        let path = (recipesDir as NSString).appendingPathComponent("\(recipe.name).json")
        let data = try JSONEncoder().encode(recipe)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Delete a recipe by name.
    public static func deleteRecipe(named name: String) -> Bool {
        let path = (recipesDir as NSString).appendingPathComponent("\(name).json")
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Save a recipe from raw JSON string.
    public static func saveRecipeJSON(_ jsonString: String) throws -> String {
        guard let data = jsonString.data(using: .utf8) else {
            throw GhostError.invalidParameter("Invalid JSON string")
        }
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        try saveRecipe(recipe)
        return recipe.name
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: recipesDir,
            withIntermediateDirectories: true
        )
    }
}
