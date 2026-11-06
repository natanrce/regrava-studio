import Foundation

/// "Search your Mac for projects": project bundles found anywhere on this Mac through the
/// Spotlight index, by file name.
public enum MacProjectSearch {
    /// At most this many Spotlight matches are read; non-folder matches are dropped after.
    public static let limit = 250

    /// The Spotlight file-name pattern (`*` and `?` wildcards) for a search term: the term's
    /// wildcard and escape characters are removed, then surrounding whitespace, and it must
    /// appear anywhere in the name before the extension.
    public static func namePattern(term: String, fileExtension: String = ProjectStore.fileExtension) -> String {
        let cleaned = term.filter { !"*?\\".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "*.\(fileExtension)" : "*\(cleaned)*.\(fileExtension)"
    }

    /// The card name: the last path component without the extension, removed only when the
    /// name ends with it exactly (same letter case).
    public static func projectName(path: String, fileExtension: String = ProjectStore.fileExtension) -> String {
        let base = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        let suffix = ".\(fileExtension)"
        guard base.hasSuffix(suffix), base != suffix else { return base }
        return String(base.dropLast(suffix.count))
    }

    /// The card subtitle: the folder holding the project, with the home folder shown as `~`.
    public static func location(path: String) -> String {
        var parts = path.components(separatedBy: "/")
        parts.removeLast()
        let folder = parts.joined(separator: "/")
        guard let range = folder.range(of: "^/Users/[^/]+", options: .regularExpression) else { return folder }
        return folder.replacingCharacters(in: range, with: "~")
    }

    /// "1 project found", "N projects found".
    public static func foundLabel(count: Int) -> String {
        "\(count) \(count == 1 ? "project" : "projects") found"
    }
}
