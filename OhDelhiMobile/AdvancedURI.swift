//
//  AdvancedURI.swift
//  OhDelhiMobile
//
//  Thin helper around Obsidian's Advanced URI plugin. The iPhone fires
//  a single URI per action — chaining multiple URIs doesn't work on
//  iOS because each `UIApplication.shared.open` backgrounds this app.
//  Side effects (confirmed_delivery stamp, daily-note DELIVERED log)
//  happen on the Mac via DeliveryStore's transition detector.
//
//  Lifted verbatim from OmmediateMobile / OatlyMobile: string-
//  concatenated URL with value-only percent encoding, no `openmode`
//  parameter, fire-and-forget — no await, no completion handler.
//

import Foundation
import UIKit

enum AdvancedURI {

    /// Vault name as Obsidian sees it. Must match the user's vault.
    static let vault = "DTObs"

    /// Set a single frontmatter key/value on a note. Fire-and-forget.
    ///
    /// Example:
    ///   `setFrontmatter(filepath: "…/Delivery.md", key: "status", value: "delivered")`
    static func setFrontmatter(filepath: String, key: String, value: String) {
        let encodedPath  = encode(filepath)
        let encodedValue = encode(value)
        let urlString = "obsidian://adv-uri?vault=\(vault)&filepath=\(encodedPath)&frontmatterkey=\(key)&data=\(encodedValue)"
        open(urlString)
    }

    // MARK: - Internals

    /// Character set for percent-encoding a URL *value* (not a whole query
    /// string). `.urlQueryAllowed` keeps `?&=#+` unencoded because they're
    /// legal in a query string overall — but inside a *value* they read as
    /// separators and break the receiver's parsing.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=#+")
        return allowed
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? s
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}
