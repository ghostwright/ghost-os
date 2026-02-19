# Ghost OS v2 Progress

## Current State: Phases 0-4 COMPLETE, bug fixes applied, ready for testing

## Architecture Changes (from live testing feedback)

After live testing revealed 8 bugs, the action module was rewritten from scratch:

**Old approach (broken):** Called `element.press()`, `element.click()`, `element.typeText()`
directly on Element objects. This bypassed AXorcist's focus management, action validation,
and element resolution.

**New approach (correct):** Uses AXorcist's COMMAND SYSTEM:
- `ghost_click` -> `PerformActionCommand` with Locator -> AXorcist handles finding + AXPress
- `ghost_type` -> `SetFocusedValueCommand` with Locator -> AXorcist handles focus + setValue
- Synthetic fallback only when AXorcist's AX-native path returns error

**Screenshot bridge (fixed):** Changed from `Task.detached` (crashed with CGS_REQUIRE_INIT)
to `Task {}` + `RunLoop.main.run(until:)` spinning (v1's proven pattern).

## Bug Fix Summary

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| elementExists false positives | findElement matched stringValue (terminal scrollback) | Custom computedName-only search |
| Screenshot crash | Task.detached ran on non-CG thread | Task {} + RunLoop.main spinning |
| Screenshot too large | PNG, text-wrapped JSON | JPEG 70% + MCP image content type |
| Type readback wrong | Reading wrong element / only trying value() | Multi-strategy readback |
| Click never AX-native | Used element.press() not AXorcist command | PerformActionCommand |
| Type into broken | Didn't use AXorcist's setValue flow | SetFocusedValueCommand |
| Focus flaky | Single attempt, short wait | Retry with longer waits |
| Find duplicates | Chrome multiple windows | Deduplicate by element hash |

## What's Next

1. **Live test** the rebuilt action module
2. **Phase 5**: RecipeEngine implementation
3. **Phase 7**: Testing against 10 apps
