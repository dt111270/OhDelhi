//
//  NoteEditor.swift
//  OhDelhi
//
//  Small helper for safely updating fields inside a note's YAML frontmatter,
//  plus appending log lines to today's daily note. Operates on the raw text —
//  preserves comments, body content, and the ordering of all other frontmatter
//  keys.
//
//  Lifted from Ommediate. Used by the "Mark as Received" button and the
//  status menu to flip status + stamp confirmed_delivery + log to the DN.
//

import Foundation

enum NoteEditor {

    enum EditError: Error {
        case fileUnreadable
        case noFrontmatter
    }

    /// Replace (or insert) a single frontmatter key/value in a `.md` file.
    ///
    /// - If the key already exists in the frontmatter, its line is rewritten.
    /// - If the key doesn't exist, a line is appended at the end of the
    ///   frontmatter block (before the closing `---`).
    /// - Passing `value: nil` writes an empty value (`key:`) — used to clear a field.
    ///
    /// `value` is written verbatim. Caller is responsible for any quoting
    /// or escaping required by YAML.
    static func setField(_ key: String, to value: String?, in fileURL: URL) throws {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw EditError.fileUnreadable
        }
        guard text.hasPrefix("---\n") else {
            throw EditError.noFrontmatter
        }
        guard let closingFenceRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            throw EditError.noFrontmatter
        }

        let frontmatter = String(text[text.startIndex..<closingFenceRange.lowerBound])
        let rest        = String(text[closingFenceRange.lowerBound..<text.endIndex])

        let newLine: String = {
            if let v = value, !v.isEmpty {
                return "\(key): \(v)"
            }
            return "\(key):"
        }()

        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key)):.*$"
        let regex   = try NSRegularExpression(pattern: pattern, options: [])
        let nsFm    = frontmatter as NSString
        let fullRange = NSRange(location: 0, length: nsFm.length)

        let updatedFm: String
        if regex.firstMatch(in: frontmatter, options: [], range: fullRange) != nil {
            updatedFm = regex.stringByReplacingMatches(
                in: frontmatter,
                options: [],
                range: fullRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: newLine)
            )
        } else {
            var fm = frontmatter
            if !fm.hasSuffix("\n") { fm += "\n" }
            fm += newLine
            updatedFm = fm
        }

        let result = updatedFm + rest
        guard result != text else { return }   // nothing changed — don't touch the file
        try result.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Convenience: write today's date (yyyy-MM-dd) to a frontmatter field.
    static func setTodayDate(_ key: String, in fileURL: URL) throws {
        let today = isoDate.string(from: Date())
        try setField(key, to: today, in: fileURL)
    }

    /// Delete a frontmatter key's line entirely (used to clear the transient
    /// `mobile_edit` instruction once it's been applied). No-op if the key
    /// isn't present or the file has no frontmatter.
    static func removeField(_ key: String, in fileURL: URL) throws {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw EditError.fileUnreadable
        }
        guard text.hasPrefix("---\n"),
              let closingFenceRange = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            throw EditError.noFrontmatter
        }

        let frontmatter = String(text[text.startIndex..<closingFenceRange.lowerBound])
        let rest        = String(text[closingFenceRange.lowerBound..<text.endIndex])

        // Drop the whole line beginning `key:` (including its trailing newline).
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key)):.*$\\n?"
        let regex   = try NSRegularExpression(pattern: pattern, options: [])
        let nsFm    = frontmatter as NSString
        let updatedFm = regex.stringByReplacingMatches(
            in: frontmatter, options: [],
            range: NSRange(location: 0, length: nsFm.length),
            withTemplate: ""
        )

        let result = updatedFm + rest
        guard result != text else { return }
        try result.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Daily note logging

    /// Vault root for resolving daily notes. Matches Ommediate's convention.
    private static var vaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DTObs")
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    /// `"HH:mm"` for use inside the daily-note `- *HH:MM* - VERB: …` template.
    static func currentTimeHHMM(_ date: Date = Date()) -> String {
        hhmm.string(from: date)
    }

    /// Append a line to the `### Log` section of today's daily note. Creates
    /// the file with just the line if it doesn't exist (matches the
    /// `daily-note-create` skill convention). Inserts at the end of the Log
    /// section — i.e. right before the next `##`/`###` header, or at end of
    /// file if no following section.
    ///
    /// `dedupeOn`, if supplied, is checked against the existing daily note
    /// content; if found anywhere in the file, the append is skipped. Use the
    /// distinguishing portion of the line (e.g. `"DELIVERED: [[stem]]"`) so a
    /// stray double-click doesn't log twice.
    ///
    /// The line should already be formatted — e.g.
    ///   `- *14:30* - DELIVERED: [[2026-05-19 Amazon - BOOX Go 7]]`
    @discardableResult
    static func appendToDailyNote(
        _ line: String,
        on date: Date = Date(),
        dedupeOn key: String? = nil
    ) throws -> Bool {
        let dayString = isoDate.string(from: date)
        let path = vaultRoot.appendingPathComponent("\(dayString).md")

        if !FileManager.default.fileExists(atPath: path.path) {
            try (line + "\n").write(to: path, atomically: true, encoding: .utf8)
            return true
        }

        let text = try String(contentsOf: path, encoding: .utf8)

        if let key, !key.isEmpty, text.contains(key) {
            return false   // dedup hit — caller-supplied key already in today's note
        }

        let nsText = text as NSString
        let logHeader = try NSRegularExpression(pattern: "(?im)^###\\s+log\\s*$", options: [])
        guard let logMatch = logHeader.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            // No `### Log` section — just append at end of file.
            var out = text
            if !out.hasSuffix("\n") { out += "\n" }
            out += line + "\n"
            try out.write(to: path, atomically: true, encoding: .utf8)
            return true
        }

        let logEnd = logMatch.range.location + logMatch.range.length
        let nextSection = try NSRegularExpression(pattern: "(?m)^(##|###)\\s", options: [])
        let searchRange = NSRange(location: logEnd, length: nsText.length - logEnd)
        let insertionPoint: Int
        if let nextMatch = nextSection.firstMatch(in: text, range: searchRange) {
            insertionPoint = nextMatch.range.location
        } else {
            insertionPoint = nsText.length
        }

        var before = nsText.substring(with: NSRange(location: 0, length: insertionPoint))
        // Trim any trailing blank lines before inserting, then put a single
        // newline back so the new line sits cleanly under the previous content.
        while before.hasSuffix("\n\n") { before.removeLast() }
        if !before.hasSuffix("\n") { before += "\n" }
        let after = nsText.substring(from: insertionPoint)
        let out = before + line + "\n" + after
        try out.write(to: path, atomically: true, encoding: .utf8)
        return true
    }
}
