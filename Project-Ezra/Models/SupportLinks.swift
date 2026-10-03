//
//  SupportLinks.swift
//  Project-Ezra
//
//  The two web pages the App Store requires an app like this one to have, in one place.
//
//  **Why this file exists (2026-09-20).** App Review guideline 5.1.1(i) says an app that
//  collects data must link to its privacy policy from App Store Connect AND "within the
//  app in an easily accessible manner". This app collects three things — product
//  interaction, an anonymous install id, and, on an escalated capture, the raw words the
//  person said (all three declared in `PrivacyInfo.xcprivacy` and described in plain
//  English by `DataBoundary`). So the requirement applies, and until 2026-09-20 there was
//  no link anywhere in the app. A missing in-app privacy link is one of the most common
//  first-submission rejections there is, and nothing in a green build says a word about it.
//
//  **Both are nil, and nil is the honest state.** The pages are not written and not
//  hosted, and inventing a URL here would ship a dead link — worse than no link, because
//  a 404 under "Privacy policy" is what a reviewer taps first. So the app renders these
//  rows only when a real URL exists, and says nothing when one does not. Setting them is
//  an owner step (`TODO.md`), and the DEBUG diagnostics card says so on every launch until
//  it is done, because a launch gate nobody is reminded of is a launch gate nobody meets.
//
//  The same two URLs go into App Store Connect, where the privacy policy field is
//  required and the support URL is required. Keeping them here keeps the app and the
//  listing from drifting apart.
//

import Foundation

enum SupportLinks {

    /// Where the privacy policy lives. Must agree with `PrivacyInfo.xcprivacy` and with
    /// `DataBoundary`'s sentences — the manifest declares the categories, the sentences
    /// say what leaves in plain words, and the policy is the long form of both.
    static let privacyPolicy: URL? = nil

    /// Where someone goes when the app is not working. App Store Connect requires this
    /// field and reviewers do open it; a page that does not load is a finding.
    static let support: URL? = nil

    /// Whether the app can meet guideline 5.1.1(i) as built. Read by the DEBUG
    /// diagnostics line, and by `SupportLinksTests`.
    static var isReadyForSubmission: Bool { privacyPolicy != nil }

    /// What the DEBUG diagnostics card says about it. One line, naming the consequence
    /// rather than the field — "privacyPolicy is nil" tells the reader nothing about why
    /// they should care at nine o'clock on a submission evening.
    static var debugStatusLine: String {
        switch (privacyPolicy, support) {
        case (nil, nil): return "links: none set — privacy policy blocks submission"
        case (nil, _): return "links: support only — privacy policy blocks submission"
        case (_, nil): return "links: privacy policy set · support URL still owed"
        default: return "links: ready"
        }
    }
}
