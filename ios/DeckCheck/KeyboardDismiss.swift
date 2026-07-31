import SwiftUI
import UIKit

/// Resign the first responder app-wide (dismiss the keyboard).
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// Adds a **Done** button above the keyboard that dismisses text entry. Needed
    /// because `TextEditor` (and Forms) have no return-key dismissal — without this
    /// there was no way out of a field but to hard-close the app.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
    }
}
