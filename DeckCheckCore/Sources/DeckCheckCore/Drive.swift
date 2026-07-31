import Foundation

// Minimal Google Drive request builders. The app already holds the `drive.file`
// scope (it created the sheet), which also covers files it creates — including the
// container-bound Apps Script project. Used only to trash that script when the user
// turns in-browser gap-check off, so the onEdit trigger stops.
public enum GoogleDrive {
    static let base = "https://www.googleapis.com/drive/v3/files"

    /// Permanently delete a Drive file the app owns (here: the bound script project,
    /// addressed by its scriptId, which is also its Drive fileId).
    public static func deleteFileRequest(fileId: String, accessToken: String) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .delete,
            url: URL(string: "\(base)/\(fileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileId)")!,
            headers: ["Authorization": "Bearer \(accessToken)"]
        )
    }
}
