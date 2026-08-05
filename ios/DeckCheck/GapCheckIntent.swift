import AppIntents
import DeckCheckCore

/// "Gap Check Decklist" — the app's one App Intent, and the reason DeckCheck can be
/// reached from the share sheet without shipping a Share Extension.
///
/// A Share Extension would be the obvious way to do this, and on a free Apple ID it
/// can't work: the extension is a separate process, so handing the text to the app
/// needs either an App Group (a paid-membership entitlement) or
/// `NSExtensionContext.open`, which Apple supports only for Today widgets. An App
/// Intent has neither problem — it runs *as* the app.
///
/// What it unlocks, all from this one declaration:
///
/// - **Share sheet.** Wrap it in a shortcut that takes share-sheet input and toggle
///   "Show in Share Sheet". Select a list anywhere → Share → straight to the report.
/// - **Home Screen / Control Center / Action Button.** A shortcut that feeds it the
///   clipboard, one press from anywhere.
/// - **Spotlight and Siri**, via `GapCheckShortcuts` below.
///
/// See `docs/usage.md` for the share-sheet recipe.
struct GapCheckDecklistIntent: AppIntent {
    static var title: LocalizedStringResource = "Gap Check Decklist"

    static var description = IntentDescription(
        "Check a decklist against your collection and show what you're missing.",
        categoryName: "Decks",
        searchKeywords: ["deck", "decklist", "gap", "missing", "buy list"]
    )

    /// The report is the point, and it's far too rich for a Shortcuts dialog — so this
    /// intent brings the app forward rather than returning a value.
    static var openAppWhenRun = true

    @Parameter(
        title: "Decklist",
        description: "A TCG Live or Limitless decklist.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var decklist: String

    static var parameterSummary: some ParameterSummary {
        Summary("Gap check \(\.$decklist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Reject prose before it becomes a baffling empty report. `DecklistDetection`
        // is stricter than the parser on purpose — see its doc comment.
        guard DecklistDetection.looksLikeDecklist(decklist) else {
            throw GapCheckIntentError.notADecklist
        }
        DecklistInbox.shared.deliver(decklist)
        return .result()
    }
}

enum GapCheckIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notADecklist

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notADecklist:
            "That doesn't look like a decklist. Expected lines like “4 Iono PAL 185”."
        }
    }
}

/// Puts the intent in Spotlight and Siri with no setup. The share-sheet route still
/// needs a user-made shortcut — iOS has no way for an app to install one itself — but
/// the action is already here waiting, so building that shortcut is a matter of
/// picking DeckCheck from the list rather than writing anything.
struct GapCheckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GapCheckDecklistIntent(),
            phrases: [
                "Gap check with \(.applicationName)",
                "Check a decklist with \(.applicationName)",
                "What am I missing in \(.applicationName)",
            ],
            shortTitle: "Gap Check",
            systemImageName: "checklist"
        )
    }
}
