// LocatorBuilder.swift - Bridge between MCP tool parameters and AXorcist Locators
//
// Takes the simple parameters an agent passes to MCP tools and builds
// proper AXorcist Locators. This is the key abstraction that replaces
// v1's SmartResolver.

import AXorcist
import Foundation

/// Builds AXorcist Locators from MCP tool parameters.
///
/// Priority: dom_id > identifier > (query + role) > query alone
public enum LocatorBuilder {

    /// Build a Locator from tool parameters.
    public static func build(
        query: String? = nil,
        role: String? = nil,
        domId: String? = nil,
        domClass: String? = nil,
        identifier: String? = nil
    ) -> Locator {
        var criteria: [Criterion] = []

        // DOM id is the most reliable - use it alone if present
        if let domId {
            criteria.append(Criterion(attribute: "AXDOMIdentifier", value: domId, matchType: .exact))
            return Locator(criteria: criteria)
        }

        // AX identifier is next most reliable
        if let identifier {
            criteria.append(Criterion(attribute: "AXIdentifier", value: identifier, matchType: .exact))
        }

        // Role narrows the search
        if let role {
            criteria.append(Criterion(attribute: "AXRole", value: role, matchType: .exact))
        }

        // DOM class
        if let domClass {
            criteria.append(Criterion(attribute: "AXDOMClassList", value: domClass, matchType: .contains))
        }

        // Query matches against computed name
        var locator = Locator(criteria: criteria)
        if let query {
            locator.computedNameContains = query
        }

        return locator
    }

    /// Build a simple Locator from just a query string.
    public static func fromQuery(_ query: String) -> Locator {
        build(query: query)
    }

    /// Build a Locator targeting a specific role.
    public static func forRole(_ role: String, named query: String? = nil) -> Locator {
        build(query: query, role: role)
    }
}
