//
//  ImageTextExtractor.swift
//  Project-Ezra
//
//  The OCR half of image capture V1: a photographed list becomes text, and the
//  text rides the EXISTING ramble pipeline — segmentation, resolver, confirm
//  cards, corrections all come free, on-device and on the heuristic path alike
//  (Vision needs no Apple Intelligence). Pure Vision wrapper; no UI, no state.
//
//  Empty output is a NORMAL outcome (a photo of the dog has no tasks in it), not
//  an error — the composer decides what an empty read means to the user.
//

import CoreGraphics
import Foundation
import Vision

enum ImageTextExtractor {

    /// Recognized lines in Vision's reading order, joined by newlines — the shape
    /// `Segmentation` already splits. `.accurate` + language correction: this runs
    /// once per picked image, seconds are fine, misreads are not.
    nonisolated static func text(from image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image, orientation: nil)
        return
            observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
