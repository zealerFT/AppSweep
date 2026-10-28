import Darwin
import Foundation

// Command Line Tools does not ship XCTest or Swift Testing. This small runner
// executes the same isolated checks without installing a global toolchain.
final class TestResults: @unchecked Sendable {
    static let shared = TestResults()
    private let lock = NSLock()
    private var count = 0
    var failures: Int { lock.withLock { count } }
    func record(_ message: String, file: StaticString, line: UInt) {
        lock.withLock { count += 1; print("FAIL \(file):\(line): \(message)") }
    }
}

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    TestResults.shared.record(message, file: file, line: line)
}

func expectTrue(_ condition: @autoclosure () throws -> Bool, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) {
    do { if try !condition() { fail("Expected true. " + message, file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func expectFalse(_ condition: @autoclosure () throws -> Bool, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    do { if try condition() { fail("Expected false. " + message, file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func expectEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T,
                               file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try left(), b = try right()
        if a != b { fail("Expected \(a) == \(b)", file: file, line: line) }
    } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func expectNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { fail("Expected nil", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func requireValue<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try value() else {
        fail("Required value is nil", file: file, line: line)
        throw CocoaError(.coderValueNotFound)
    }
    return value
}

@main
enum SafetyChecks {
    static func main() async {
        let suite = AppSweepCoreTests()
        let tests: [(String, @Sendable () async throws -> Void)] = [
            ("catalog boundaries", { try suite.testCatalogIncludesNestedAppsButNotTheirHelpersOrSymlinks() }),
            ("invalid app packages are informational", { try suite.testInvalidApplicationPackagesAreInformational() }),
            ("exact bundle ID matches", { try suite.testOnlyExactBundleIDPathsAreCandidates() }),
            ("personal data defaults", { try suite.testPersonalDataIsNeverSelectedByDefault() }),
            ("ByHost UUID matching", { try suite.testByHostRequiresAnExactIdentifierAndUUID() }),
            ("duplicate ownership", { try suite.testDuplicateCopiesBlockAllResidualData() }),
            ("Apple and self protection", { try suite.testAppleAndSelfApplicationsAreProtected() }),
            ("case-insensitive bundle identity", { try suite.testCaseVariantsShareBundleIdentity() }),
            ("bundle ID traversal", { try suite.testBundleIdentifierRejectsPathTraversal() }),
            ("application path boundaries", { try suite.testApplicationPathCannotEscapeRootsOrEnterAnotherApp() }),
            ("symlink candidate", { try suite.testSymlinkCandidateIsBlockedAndNotFollowed() }),
            ("symlink Library root", { try suite.testSymlinkLibraryRootIsReportedAndSkipped() }),
            ("permission failure visibility", { try suite.testUnreadableDirectoryIsNotReportedAsNoRemnants() }),
            ("embedded service detection", { try suite.testEmbeddedServiceRequiresOfficialUninstaller() }),
            ("structured launch job matching", { try suite.testLaunchJobIsMatchedByStructuredProgramPath() }),
            ("unrelated launch jobs", { try suite.testUnrelatedLaunchJobDoesNotBlockApplication() }),
            ("running app refusal", { try await suite.testRunningApplicationPreventsAllMoves() }),
            ("stale identity refusal", { try await suite.testChangedFileIdentityPreventsRemoval() }),
            ("new duplicate revalidation", { try await suite.testNewDuplicateAfterScanPreventsDataRemoval() }),
            ("selected-only removal and history", { try await suite.testOnlySelectedItemsMoveAndHistoryIsSaved() }),
            ("partial failure stops app removal", { try await suite.testTrashFailureStopsBeforeMovingAppAndRecordsPartialResult() }),
            ("corrupt journal refusal", { try await suite.testCorruptJournalPreventsAnyMove() }),
            ("symlink journal refusal", { try await suite.testSymlinkJournalIsRejected() }),
            ("unknown selection refusal", { try await suite.testUnknownSelectionCannotInjectAPath() }),
            ("empty selection refusal", { try await suite.testEmptySelectionDoesNotCreateJournal() }),
            ("protected selection refusal", { try await suite.testBlockedAppCannotBeSelectedThroughTheService() })
        ]
        for (name, test) in tests {
            let before = TestResults.shared.failures
            do { try await test() } catch { fail("\(name): \(error)") }
            print("\(TestResults.shared.failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(tests.count) checks, \(TestResults.shared.failures) failures")
        exit(TestResults.shared.failures == 0 ? 0 : 1)
    }
}
