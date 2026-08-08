//
//  ImageCaptureTests.swift
//  Project-EzraTests
//
//  Image capture V1's two testable halves: the Vision OCR wrapper (real inference
//  on a generated fixture image — Vision runs in the simulator), and the imageRef
//  provenance round-trip through park → resume → commit. The picker UI itself is
//  manual-sim territory (synthetic taps are blocked on this host).
//

import CoreData
import Testing
import UIKit

@testable import Project_Ezra

@MainActor
struct ImageCaptureTests {

    /// Draw known task lines into a bitmap — a synthetic "photographed list".
    private func fixtureImage(lines: [String]) -> CGImage {
        let size = CGSize(width: 800, height: 60 + lines.count * 70)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 40, y: 40 + CGFloat(index) * 70), withAttributes: attributes)
            }
        }
        return image.cgImage!
    }

    @Test("OCR reads a printed list back, lines in order")
    func recognizesPrintedLines() async throws {
        let image = fixtureImage(lines: ["renew my passport", "call the dentist"])
        let text = try await ImageTextExtractor.text(from: image)
        let lower = text.lowercased()
        #expect(lower.contains("renew my passport"))
        #expect(lower.contains("call the dentist"))
        // Reading order: the first line precedes the second.
        let first = try #require(lower.range(of: "passport"))
        let second = try #require(lower.range(of: "dentist"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test("A blank image reads as empty — a normal outcome, not an error")
    func blankImageReadsEmpty() async throws {
        let text = try await ImageTextExtractor.text(from: fixtureImage(lines: []))
        #expect(text.isEmpty)
    }

    @Test("imageRef rides park → parked fetch → commit, with .image provenance")
    func imageRefRoundTrip() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()

        let parked = brain.park(
            [], rawCapture: "renew my passport", source: .image, imageRef: "fixture.jpg",
            into: nil, in: context)
        #expect(parked?.imageRef == "fixture.jpg")
        #expect(AppBrain.parkedCaptures(in: context).first?.imageRef == "fixture.jpg")

        _ = brain.commit(
            [], rawCapture: "renew my passport", source: .image, imageRef: "fixture.jpg",
            parked: parked, into: context)
        let committed = try #require(parked)
        #expect(committed.imageRef == "fixture.jpg")
        #expect(committed.source == .image)
        #expect(committed.committedAt != nil)
    }

    @Test("The file store round-trips bytes and delete removes them")
    func fileStoreRoundTrip() throws {
        let payload = Data("not really a jpeg".utf8)
        let ref = try #require(CaptureImageStore.save(payload))
        #expect(FileManager.default.fileExists(atPath: CaptureImageStore.url(for: ref).path))
        #expect(try Data(contentsOf: CaptureImageStore.url(for: ref)) == payload)
        CaptureImageStore.delete(ref)
        #expect(!FileManager.default.fileExists(atPath: CaptureImageStore.url(for: ref).path))
    }
}
