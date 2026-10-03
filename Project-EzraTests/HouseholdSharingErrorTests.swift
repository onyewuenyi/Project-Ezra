//
//  HouseholdSharingErrorTests.swift
//  Project-EzraTests
//
//  The sharing failures a real person meets, in the product's words. Before 2026-09-18
//  every path rethrew the framework error, so "nobody is signed into iCloud" — the
//  likeliest failure of all, and the one the two-phone sitting will hit first — reached
//  the invite sheet as "CKErrorDomain error 9".
//

import CloudKit
import Testing

@testable import Project_Ezra

@Suite("Household sharing — failures in the product's words")
struct HouseholdSharingErrorTests {

    private func ck(_ code: CKError.Code) -> CKError {
        CKError(code)
    }

    @Test("An account problem is named, and says what to do about it")
    func accountProblems() {
        for code in [CKError.Code.notAuthenticated, .managedAccountRestricted, .permissionFailure] {
            #expect(HouseholdSharingError.naming(ck(code)) == .accountRequired)
        }
        #expect(
            HouseholdSharingError.accountRequired.errorDescription
                == "Sign in to iCloud on this device to share your household.")
    }

    @Test("A network problem and a full account are named too")
    func networkAndStorage() {
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable] {
            #expect(HouseholdSharingError.naming(ck(code)) == .offline)
        }
        #expect(HouseholdSharingError.naming(ck(.quotaExceeded)) == .storageFull)
    }

    @Test("A failure we have not met is never disguised as one we have")
    func unknownStaysUnknown() {
        #expect(HouseholdSharingError.naming(ck(.internalError)) == nil)
        #expect(HouseholdSharingError.naming(ck(.serverRecordChanged)) == nil)
        // A non-CloudKit error is not ours to name either.
        #expect(HouseholdSharingError.naming(CancellationError()) == nil)
    }

    @Test("Every sentence is plain words — no vendor name, no error code")
    func sentencesArePlain() {
        let all: [HouseholdSharingError] = [
            .unavailable, .linkNotReady, .noSharedStore, .accountRequired, .offline, .storageFull,
        ]
        for error in all {
            let sentence = try! #require(error.errorDescription)
            #expect(!sentence.isEmpty)
            #expect(!sentence.contains("CKError"))
            #expect(!sentence.contains("CloudKit"))
            #expect(!sentence.lowercased().contains("error "))
        }
    }
}
