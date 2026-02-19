// LocatorBuilderTests.swift - Unit tests for LocatorBuilder

import AXorcist
import Testing
@testable import GhostOS

@Suite("LocatorBuilder Tests")
struct LocatorBuilderTests {

    @Test("Build with DOM ID uses exact match")
    func domIdLocator() {
        let locator = LocatorBuilder.build(domId: "compose-button")
        #expect(locator.criteria.count == 1)
        #expect(locator.criteria[0].attribute == "AXDOMIdentifier")
        #expect(locator.criteria[0].value == "compose-button")
        #expect(locator.computedNameContains == nil)
    }

    @Test("Build with query sets computedNameContains")
    func queryLocator() {
        let locator = LocatorBuilder.build(query: "Compose")
        #expect(locator.criteria.isEmpty)
        #expect(locator.computedNameContains == "Compose")
    }

    @Test("Build with query and role")
    func queryAndRoleLocator() {
        let locator = LocatorBuilder.build(query: "Compose", role: "AXButton")
        #expect(locator.criteria.count == 1)
        #expect(locator.criteria[0].attribute == "AXRole")
        #expect(locator.criteria[0].value == "AXButton")
        #expect(locator.computedNameContains == "Compose")
    }

    @Test("DOM ID takes priority over query")
    func domIdPriority() {
        let locator = LocatorBuilder.build(query: "Compose", role: "AXButton", domId: "btn-compose")
        // DOM ID should be the only criterion
        #expect(locator.criteria.count == 1)
        #expect(locator.criteria[0].attribute == "AXDOMIdentifier")
        // query should be ignored when DOM ID is present
        #expect(locator.computedNameContains == nil)
    }

    @Test("fromQuery convenience")
    func fromQueryConvenience() {
        let locator = LocatorBuilder.fromQuery("Send")
        #expect(locator.computedNameContains == "Send")
    }
}
