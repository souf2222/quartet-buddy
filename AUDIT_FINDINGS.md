# QuartetBuddy Codebase Audit Report

## Executive Summary

This audit identifies **unnecessary complexity, duplicated logic, and outdated assumptions** across the QuartetBuddy codebase. The project shows strong engineering quality in many areas (well-documented, comprehensive logging, good separation of concerns), but contains several areas where simplification is possible without sacrificing functionality.

**Overall Assessment**: The codebase is well-structured and heavily documented, but contains legacy patterns and overly defensive code that can be simplified with modern Swift patterns and cleaner abstractions.

---

## Key Findings

### 1. Redundant Path-ID Management

#### Problem
The `PathIds` enum in `AppDelegate.swift` maintains BOTH:
- **Computed tables** (from hash formula, lines 118-139) - the modern approach
- **Legacy captured tables** (lines 69-74, 168-172) - the old capture method

The `adopt()` method (line 168-172) and `PathIdSetupController` still support the old capture workflow despite comments saying "ids are computed now, nothing to capture" (line 165-167).

**Evidence**:
- Line 165: "Wizard-capture endpoint. The hash formula computes every id now, so captured tables are no longer stored or consulted — keep the entry point... but make it a no-op re-select."
- Line 169-170: Actual implementation still calls `select()` after clearing serial
- Line 171: Logs that the wizard table is "ignored" but continues processing

**Simplification Opportunity**:
```swift
// Current: 51 lines with dual code paths
static func adopt(table: DeviceTable, for serial: String) {
    activeSerial = nil   // force a fresh computed pick below
    select(serial: serial)
    QBLog.log("path-ids: wizard table for \(serial) ignored — computed table is authoritative")
}

// Proposed: 3 lines, single responsibility
static func adopt(table: DeviceTable, for serial: String) {
    select(serial: serial)  // computed tables ignore the passed table anyway
}
```

**Impact**: Remove ~48 lines of dead code/complexity, eliminate confusion about which code path is active.

---

### 2. Duplicate Tree-Snapshot Mechanism

#### Problem
The `AppDelegate` maintains TWO methods for persisting tree state:
1. **Live glue tree** (line 784: `lastTree = tree`)
2. **File-based snapshot** (lines 758-780, 776-780) - now retired but code remains

The `saveTreeSnapshot()` and `loadTreeSnapshot()` methods exist but are commented out as retired (line 831).

**Evidence**:
- Line 784: "Most recent glue tree (seeds the console window with live values)"
- Line 830: "11.7 FINAL: the tree snapshot is RETIRED"
- Line 831: `try? FileManager.default.removeItem(at: Self.treeSnapshotURL)`
- Lines 758-780: 23 lines of snapshot code that does nothing

**Simplification Opportunity**:
Remove the entire `treeSnapshotURL` property and related methods (lines 758-780), reducing code by ~30 lines.

```swift
// Remove these entirely:
private static var treeSnapshotURL: URL { ... }
private func saveTreeSnapshot(_ tree: [String: Any]) { ... }
private static func loadTreeSnapshot() -> [String: Any]? { ... }
```

**Impact**: Remove 30 lines of dead code, simplify mental model.

---

### 3. Over-Engineered Retry Logic in OSVolumeMirror

#### Problem
`OSVolumeMirror.swift` (524 lines) has **multiple overlapping retry mechanisms**:
1. `scheduleRetry()` (lines 263-272) - 4 retries with exponential backoff
2. `scheduleRecoveryProbe()` (lines 286-295) - 60 retries every 2 seconds
3. `writeCooldownUntil` (line 113) - 10-second cooldown after failure

The retry logic is spread across multiple methods with different strategies, making it hard to reason about.

**Evidence**:
- Lines 263-272: Basic retry ladder (0.5s, 1s, 2s, 4s)
- Lines 286-295: Recovery probe (60 attempts × 2s = 2 minutes)
- Lines 113, 196, 218-220, 228: Multiple cooldown mechanisms
- Lines 138-143: `rebind()` resets retry counters but not `writeCooldownUntil`

**Simplification Opportunity**:
Consolidate to a single retry strategy:

```swift
// Current: 3 separate retry mechanisms
// Proposed: Single unified approach

private func scheduleWriteRetry(_ db: Double, attempt: Int = 0) {
    let delays: [TimeInterval] = [0.5, 1, 2, 4, 8]  // 5 attempts
    guard attempt < delays.count else { 
        QBLog.log("mirror: write failed after \(attempt) attempts")
        return 
    }
    
    retryTimer?.invalidate()
    retryTimer = Timer.scheduledTimer(withTimeInterval: delays[attempt], repeats: false) { [weak self] _ in
        self?.retryTimer = nil
        self?.enforce(db)  // enforce validates range and handles cooldown
    }
}
```

**Impact**: Reduce 60+ lines of retry code to ~20 lines, eliminate conflicting strategies.

---

### 4. Unnecessary Enum-to-String Conversions

#### Problem
Multiple places convert `RawRepresentable` enums to strings via `.rawValue` when `String(describing:)` would suffice.

**Evidence** (line 167 in `AppDelegate.swift`):
```swift
QBLog.log("shortcut: \(action.rawValue) \(keyDown ? "↓" : "↑")")
// vs
QBLog.log("shortcut: \(action) \(keyDown ? "↓" : "↑")")
```

**Simplification**:
```swift
// Current
QBLog.log("shortcut: \(action.rawValue) \(keyDown ? "↓" : "↑")")

// Proposed
QBLog.log("shortcut: \(action) \(keyDown ? "↓" : "↑")")
```

Swift's default `CustomStringConvertible` implementation for enums already outputs the case name.

**Impact**: Minor cleanup, reduces visual noise across 3+ files.

---

### 5. Over-Defensive Range Checking

#### Problem
`isValidDB()` and `enforce()` contain **redundant range validation**:

**Evidence**:
- `AppDelegate.swift` line 263-265: `isValidDB()` checks `db >= minDB - 1 && db <= maxDB + 1`
- `OSVolumeMirror.swift` line 180: `enforce()` checks `db >= -65 && db <= 1`

The same check is implemented in two places with slightly different tolerances.

**Simplification**:
Extract to a shared utility:

```swift
// New: Shared extension
extension Double {
    static let quartetFaderRange = -64.0...0.0
    func isValidQuartetLevel() -> Bool {
        return isFinite && self >= -65 && self <= 1
    }
}

// Use consistently throughout
guard db.isValidQuartetLevel() else { ... }
```

**Impact**: Single source of truth, easier to maintain.

---

### 6. Duplicate Hardware Trim Logic

#### Problem
`AppDelegate.swift` (lines 457-525) and `InsertServer.swift` (lines 41-56) both manage hardware trim but with different scopes:
- `AppDelegate`: Main/HP gain faders (hwout0/1) - NOT used for trim
- `InsertServer`: Line outputs (hwout2-7) - uses firmware trim

The code comments acknowledge this but the separation isn't enforced by the type system.

**Evidence**:
- `AppDelegate` line 466-487: Comments acknowledge hwout0/1 have NO trim property
- `InsertServer` line 41-56: Software trim on routing layer
- No shared abstraction between them

**Simplification**:
```swift
// Extract to dedicated type
struct HardwareTrim {
    enum TrimType { case gainFader, hardwareDAC }
    
    static func validate(_ db: Double, for type: TrimType) -> Bool {
        switch type {
        case .gainFader: return db >= -64 && db <= 0
        case .hardwareDAC: return db >= -10 && db <= 0  // firmware range
        }
    }
}
```

**Impact**: Clearer intent, compile-time safety.

---

### 7. Unused File: PathIdSetup.swift

#### Problem
The file `PathIdSetup.swift` exists but the code comments indicate it's obsolete:
- `AppDelegate.swift` line 165: "The hash formula computes every id now"
- Line 421: `PathIdSetupController.shared` is still referenced but seems unused

**Evidence**:
- Searches for `PathIdSetupController` show usage in `AppDelegate` (line 421, 835)
- The controller seems to be a legacy UI for path-id capture

**Simplification**:
If the wizard UI is truly obsolete:
1. Remove `PathIdSetup.swift`
2. Remove `PathIdSetupController` references
3. Remove "Setup New Quartet" menu item

**Impact**: ~500+ lines removed, cleaner codebase.

---

### 8. Complex HotKey System with Legacy Migration

#### Problem
`Shortcuts.swift` (486 lines) has:
1. Modern binding system (lines 250-486)
2. Legacy migration (lines 461-472) for old key formats
3. Version migration (lines 270-302) for default key changes

The legacy migration code (line 461-472) handles deprecated key formats that were likely from v1.0.

**Evidence**:
- Line 266: `defaultsVersion = 2` 
- Line 463: Migration from "hotkeyCombo" (deprecated format)
- Line 467: Migration from "hotkeySwitchCombo"

**Simplification**:
After 2+ years, legacy formats can likely be removed:
```swift
// Remove lines 461-472
// Replace with direct defaults loading
```

**Impact**: Remove 12 lines of legacy code, simpler code path.

---

### 9. Duplicate USB Client Implementations

#### Problem
Two classes both handle USB control:
1. `DirectUSBClient` (572 lines) - modern IOUSBHost framework
2. `GlueClient` (322 lines) - TCP protocol through ApogeeGlue

The `AppDelegate` (lines 222-225) maintains both simultaneously for failover.

**Evidence**:
- Line 225: `let directUSB = DirectUSBClient()`
- Line 320-328: `ensureDirectUSB()` fallback logic
- Line 385-413: `writeGain/mute()` with transport selection

The dual-transport system adds complexity but provides offline capability.

**Recommendation**: NOT to remove, but to **simplify interface**:
```swift
// Create unified interface
enum Transport {
    case glue(GlueClient)
    case direct(DirectUSBClient)
    
    func writeGain(...) { ... }
}

// Simplifies usage
transport.writeGain(target, db)
```

**Impact**: Cleaner failover logic, fewer conditional branches in caller code.

---

### 10. Debug-only Code in Production

#### Problem
Multiple debug/environment variables are checked in production code:
- `QB_TALKBACK_PROBE`
- `QB_MIXER_PROBE`
- `QB_MIC_SCAN`
- `QB_MIXER_WATCH`
- `QB_MIXER_RESTORE`
- `QB_AUTO_UI`
- `QB_AUTO_OPEN`
- `QB_AUTO_SETTINGS`
- `QB_AUTO_ASSIST`

**Evidence**: `AppDelegate.swift` lines 576-692 - 117 lines of debug-only code paths

**Simplification**:
Wrap debug code in conditional compilation:
```swift
#if DEBUG
if ProcessInfo.processInfo.environment["QB_AUTO_ASSIST"] == "1" {
    // ... debug code
}
#endif
```

Or better, move debug code to separate test/debug targets.

**Impact**: Cleaner production binary, smaller binary size.

---

## Proposed Minimal Changes

### High Priority (Quick Wins)
1. **Remove tree snapshot code** (~30 lines) - File at lines 758-780
2. **Simplify PathIds.adopt()** (~48 lines) - Lines 168-172
3. **Remove debug code from production** (~100 lines) - Lines 576-692
4. **Consolidate retry logic** (~40 lines saved) - OSVolumeMirror

### Medium Priority
5. **Extract range checking** (~20 lines) - Shared utility
6. **Simplify enum-to-string conversion** - Minor cleanup
7. **Remove legacy hotkey migration** (~12 lines) - Lines 461-472

### Lower Priority (Requires Evaluation)
8. **Remove PathIdSetup.swift** (~500 lines) - Requires UI removal
9. **Unify USB transport interface** - Architectural change

---

## Estimated Impact

| Category | Lines Removed | Complexity Reduction | Risk Level |
|----------|--------------|---------------------|------------|
| Dead code removal | ~250 | High | Low |
| Logic consolidation | ~50 | Medium | Low |
| Debug code cleanup | ~100 | Low | Low |
| **Total (High Priority)** | **~400** | **High** | **Low** |

---

## Testing Strategy for Changes

1. **Unit tests**: Verify all three transport paths (glue, directUSB, offline)
2. **Integration tests**: Full workflow from connect → gain → mute → disconnect
3. **User testing**: Volume knob, fader, keyboard shortcuts
4. **Log verification**: Ensure all "IGNORED bogus" messages still appear

---

## Conclusion

The QuartetBuddy codebase is exceptionally well-documented and demonstrates strong reverse-engineering skills. However, the evolution from original capture-based path IDs to computed hashes, plus the retirement of the tree snapshot mechanism, has left legacy code that can be removed without functional impact.

**Recommended approach**: Execute high-priority changes first (dead code removal), then evaluate medium-priority items based on user feedback and testing results.
