import Foundation

/// Is this arbitrary text plausibly a decklist?
///
/// The paste button and the share/Shortcuts entry point both hand the app text that
/// nobody vetted — whatever happened to be on the clipboard, or whatever was selected
/// in Safari. Running the gap-check on a paragraph of prose produces a confusing empty
/// report; refusing it with a reason is better.
///
/// `DecklistParser` alone isn't a sufficient test. It's deliberately tolerant — any
/// line starting with a quantity is a card line — so "4 things I learned about
/// Charizard" parses as one card named "things I learned about Charizard". That's the
/// right call for a *known* decklist, where tolerance rescues odd exports, and the
/// wrong one for deciding whether this is a decklist at all.
///
/// So the bar here is higher than "parsed at least one line", and it's stated as a
/// value function so it can be tested without a clipboard or a phone.
public enum DecklistDetection {

    /// What a blob of text looks like to the parser.
    public struct Summary: Equatable {
        /// Lines that parsed as `<qty> <name> …`.
        public let lineCount: Int
        /// Sum of the quantities — the "/60".
        public let cardCount: Int
        /// Lines carrying a trailing `<SETCODE> <Number>` pair. The strongest signal
        /// that this came out of TCG Live or Limitless rather than out of a sentence.
        public let linesWithSetCode: Int

        public init(lineCount: Int, cardCount: Int, linesWithSetCode: Int) {
            self.lineCount = lineCount
            self.cardCount = cardCount
            self.linesWithSetCode = linesWithSetCode
        }

        /// Worth handing to the gap-checker.
        ///
        /// Two or more card lines, **or** a single line that carries a set code and
        /// number. The second case matters because a one-line paste is a legitimate
        /// thing to check ("do I have 4 Iono PAL 185?"), and the set code makes it
        /// unambiguous. A lone bare line is rejected — that's the shape prose takes.
        public var looksLikeDecklist: Bool {
            if lineCount >= 2 { return true }
            return lineCount == 1 && linesWithSetCode == 1
        }
    }

    public static func summary(_ text: String) -> Summary {
        let lines = DecklistParser.parse(text)
        return Summary(
            lineCount: lines.count,
            cardCount: lines.reduce(0) { $0 + $1.quantity },
            linesWithSetCode: lines.filter { $0.setCode != nil && $0.number != nil }.count
        )
    }

    /// Convenience for the call sites that only need the verdict.
    public static func looksLikeDecklist(_ text: String) -> Bool {
        summary(text).looksLikeDecklist
    }
}
