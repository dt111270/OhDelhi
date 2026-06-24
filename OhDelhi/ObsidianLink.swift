//
//  ObsidianLink.swift
//  OhDelhi
//
//  Builds `obsidian://open?vault=…&file=…` URLs that, when tapped, open the
//  corresponding `.md` note in Obsidian. Used by the detail-pane "Open in
//  Obsidian" button.
//

import Foundation

enum ObsidianLink {

    /// Obsidian vault name. Matches David's `~/Documents/DTObs` vault.
    static let vaultName = "DTObs"

    /// Build an `obsidian://` URL that opens the given `.md` file by name.
    /// We pass only the filename stem; Obsidian resolves it against the vault.
    static func url(for fileURL: URL) -> URL? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard let encoded = stem.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "obsidian://open?vault=\(vaultName)&file=\(encoded)")
    }
}
