//
//  CorrectionProfileTests.swift
//  Project-EzraTests
//
//  The correction loop's guardrails are the product: a rule needs the same
//  correction twice (one-offs are noise), the set is capped and
//  frequency-ordered, and application in the resolver is deterministic and only
//  ever touches fields the engine produced.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Correction profile")
struct CorrectionProfileTests {

    private func correction(
        _ field: String, ai: String, user: String, task: TaskItem? = nil,
        at date: Date = Date()
    ) -> Correction {
        Correction(
            taskUUID: task?.uuid, fieldCorrected: field, aiValue: ai, userValue: user,
            createdAt: date)
    }

    // MARK: - Aggregation

    @Test("A single correction never becomes a rule; the second occurrence does")
    func thresholdIsTwo() {
        let gym1 = TaskItem(title: "Renew gym membership")
        let gym2 = TaskItem(title: "Cancel gym class")
        let once = [correction("category", ai: "Health", user: "Personal", task: gym1)]
        #expect(CorrectionProfile.rules(from: once, tasks: [gym1]).isEmpty)

        let twice = [
            correction("category", ai: "Health", user: "Personal", task: gym1),
            correction("category", ai: "Health", user: "Personal", task: gym2),
        ]
        let rules = CorrectionProfile.rules(from: twice, tasks: [gym1, gym2])
        #expect(rules.contains(.categoryOverride(keyword: "gym", category: "Personal")))
    }

    @Test("Owner aliases learn name→name only; 'you' never aliases")
    func ownerAliasRules() {
        let repeated = [
            correction("owner", ai: "Mom", user: "Grandma"),
            correction("owner", ai: "mom", user: "Grandma"),
        ]
        // Case-insensitive aggregation: "Mom" and "mom" are the same lesson.
        let rules = CorrectionProfile.rules(from: repeated, tasks: [])
        #expect(rules.contains(.ownerAlias(spoken: "mom", actual: "Grandma")))

        let toSelf = [
            correction("owner", ai: "Sarah", user: "you"),
            correction("owner", ai: "Sarah", user: "you"),
        ]
        #expect(CorrectionProfile.rules(from: toSelf, tasks: []).isEmpty)
    }

    @Test("Title rewrites learn only the crisp single-word substitution")
    func titleRewriteRules() {
        let crisp = [
            correction("title", ai: "Call the doctor", user: "Call the pediatrician"),
            correction("title", ai: "Book doctor visit", user: "Book pediatrician visit"),
        ]
        let rules = CorrectionProfile.rules(from: crisp, tasks: [])
        #expect(rules.contains(.titleRewrite(from: "doctor", to: "pediatrician")))

        // A full rewrite teaches nothing structural.
        let messy = [
            correction("title", ai: "Deal with the thing", user: "File the insurance claim"),
            correction("title", ai: "Deal with the thing", user: "File the insurance claim"),
        ]
        #expect(CorrectionProfile.rules(from: messy, tasks: []).isEmpty)
    }

    @Test("Rules are frequency-sorted and capped")
    func frequencyAndCap() {
        // Titles share exactly ONE significant word ("gym"), so the count-3 rule
        // is unambiguous; the alias only reaches count 2 and must sort after it.
        let gymTasks = [
            TaskItem(title: "Renew gym membership"),
            TaskItem(title: "Cancel gym class"),
            TaskItem(title: "Book gym session"),
        ]
        var corrections = gymTasks.map {
            correction("category", ai: "Health", user: "Personal", task: $0)
        }
        corrections.append(correction("owner", ai: "Mom", user: "Grandma"))
        corrections.append(correction("owner", ai: "Mom", user: "Grandma"))

        let rules = CorrectionProfile.rules(from: corrections, tasks: gymTasks)
        #expect(rules.first == .categoryOverride(keyword: "gym", category: "Personal"))
        #expect(rules.contains(.ownerAlias(spoken: "mom", actual: "Grandma")))

        #expect(CorrectionProfile.rules(from: corrections, tasks: gymTasks, limit: 1).count == 1)
    }

    // MARK: - Instruction text

    @Test("Instruction lines render every rule kind; empty rules render nothing")
    func instructionText() {
        #expect(CorrectionProfile.instructionLines([]) == nil)
        let text = CorrectionProfile.instructionLines([
            .categoryOverride(keyword: "gym", category: "Personal"),
            .ownerAlias(spoken: "mom", actual: "Grandma"),
            .titleRewrite(from: "doctor", to: "pediatrician"),
        ])!
        #expect(text.contains("gym"))
        #expect(text.contains("Personal"))
        #expect(text.contains("Grandma"))
        #expect(text.contains("pediatrician"))
    }

    // MARK: - Resolver application (the deterministic half)

    private func intent(
        _ title: String, category: String = "Admin", person: String? = nil
    ) -> TaskIntent {
        TaskIntent(
            title: title, category: category, personReference: person, confidence: 0.9,
            isJudgmentCall: false, reasoning: "")
    }

    @Test("categoryOverride fires on word-boundary keyword match; first (highest-frequency) wins")
    func categoryOverrideApplied() {
        let rules: [LearnedRule] = [
            .categoryOverride(keyword: "gym", category: "Personal"),
            .categoryOverride(keyword: "gym", category: "Health"),  // lower frequency, never reached
        ]
        let draft = IntentResolver.resolve(intent("Renew gym membership", category: "Health"), rules: rules)
        #expect(draft.category == "Personal")
        // No keyword in the title → untouched.
        let other = IntentResolver.resolve(intent("Pay the water bill", category: "Finance"), rules: rules)
        #expect(other.category == "Finance")
    }

    @Test("ownerAlias maps the spoken name; titleRewrite replaces on word boundaries")
    func aliasAndRewriteApplied() {
        let rules: [LearnedRule] = [
            .ownerAlias(spoken: "mom", actual: "Grandma"),
            .titleRewrite(from: "doctor", to: "pediatrician"),
        ]
        let aliased = IntentResolver.resolve(intent("Call about forms", person: "Mom"), rules: rules)
        #expect(aliased.ownerName == "Grandma")

        let rewritten = IntentResolver.resolve(intent("Call the doctor today"), rules: rules)
        #expect(rewritten.title == "Call the pediatrician today")
        // Never inside another word.
        let untouched = IntentResolver.resolve(intent("Read doctorow novel"), rules: rules)
        #expect(untouched.title == "Read doctorow novel")
    }

    @Test("A rule never invents a field the intent didn't produce")
    func rulesNeverInvent() {
        let rules: [LearnedRule] = [.ownerAlias(spoken: "mom", actual: "Grandma")]
        let draft = IntentResolver.resolve(intent("Call about forms"), rules: rules)
        #expect(draft.ownerName == nil)  // no personReference in → none out
    }

    @Test("aiOriginal snapshots AFTER rules — an un-edited confirm records no phantom correction")
    func snapshotAfterRules() {
        let rules: [LearnedRule] = [.categoryOverride(keyword: "gym", category: "Personal")]
        let draft = IntentResolver.resolve(intent("Renew gym membership", category: "Health"), rules: rules)
        #expect(draft.category == "Personal")
        #expect(draft.aiOriginal?.category == "Personal")
        #expect(draft.corrections.isEmpty)  // rule application is not a user edit
    }
}
