import Foundation
import Vision
import CoreGraphics
import DeckCheckCore

/// Apple Vision text recognition tuned for card reads — the checkpoint
/// logic (validated on real cards, #4) as a reusable scanner. Produces the OCR
/// candidates the resolver needs.
struct ScanResult {
    var rawLines: [String] = []
    var numberTotals: [(number: String, printedTotal: String)] = []
    var looseNumbers: [String] = []
    var setCodeCandidates: [String] = []
    /// HP read off the card (e.g. "160") — a recognizer disambiguator.
    var hpGuess: String?
    /// Best-guess card name: the longest alphabetic line (names dominate the card face).
    var nameGuess: String?
}

enum CardScanner {
    static func scan(_ cgImage: CGImage) async -> ScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                try? handler.perform([request])

                var result = ScanResult()
                var bestName: (text: String, len: Int)?
                for obs in request.results ?? [] {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let s = top.string
                    result.rawLines.append(s)
                    extract(from: s, into: &result)
                    let letters = s.filter(\.isLetter).count
                    if letters >= 3, s.rangeOfCharacter(from: .decimalDigits) == nil,
                       letters > (bestName?.len ?? 0) {
                        bestName = (s, letters)
                    }
                }
                result.nameGuess = bestName?.text
                continuation.resume(returning: result)
            }
        }
    }

    private static let numberTotal = try! NSRegularExpression(pattern: #"(\d{1,3})\s*/\s*(\d{1,3})"#)
    private static let setCode = try! NSRegularExpression(pattern: #"\b[A-Z]{2,4}[0-9]?\b"#)
    private static let loose = try! NSRegularExpression(pattern: #"\b\d{1,3}\b"#)
    // "HP 160" / "160 HP" — HP is always ≥30 (2–3 digits), which also avoids matching
    // stray single digits.
    private static let hp = try! NSRegularExpression(pattern: #"HP\s*(\d{2,3})|(\d{2,3})\s*HP"#,
                                                     options: [.caseInsensitive])

    private static func extract(from text: String, into r: inout ScanResult) {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for m in numberTotal.matches(in: text, range: whole) {
            r.numberTotals.append((stripZeros(ns.substring(with: m.range(at: 1))),
                                   ns.substring(with: m.range(at: 2))))
        }
        for m in setCode.matches(in: text, range: whole) {
            let c = ns.substring(with: m.range)
            if !r.setCodeCandidates.contains(c) { r.setCodeCandidates.append(c) }
        }
        for m in loose.matches(in: text, range: whole) {
            let n = stripZeros(ns.substring(with: m.range))
            if !r.looseNumbers.contains(n) { r.looseNumbers.append(n) }
        }
        if r.hpGuess == nil, let m = hp.firstMatch(in: text, range: whole) {
            let g = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            r.hpGuess = ns.substring(with: g)
        }
    }

    static func stripZeros(_ s: String) -> String {
        let t = String(s.drop { $0 == "0" })
        return t.isEmpty ? "0" : t
    }
}

extension ScanResult {
    /// Map the OCR read into the core resolver's input.
    func asRecognizedCard() -> RecognizedCard {
        RecognizedCard(
            nameGuess: nameGuess,
            setCodes: setCodeCandidates,
            numberTotals: numberTotals.map { NumberTotal(number: $0.number, printedTotal: $0.printedTotal) },
            looseNumbers: looseNumbers,
            hp: hpGuess
        )
    }
}
