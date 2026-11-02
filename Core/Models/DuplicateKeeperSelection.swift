import Foundation

/// Which copy of each duplicate group is kept.
///
/// The scanner proposes a keeper — the oldest copy — but the decision belongs to
/// the user: the copy worth keeping is the one in the folder they work in, and a
/// page that rendered the proposal as a fixed verdict left them no way to say so.
///
/// Choices are keyed by the group's content hash rather than by its id. Ids are
/// positions in the run that produced them, so after a rescan group 3 is not the
/// group it was; a choice stored under an id would then be applied to a group of
/// different files. The hash names the content, which is what the choice is
/// about — and a choice whose copy is no longer in the group falls back to the
/// scanner's proposal rather than to no keeper at all.
///
/// It is a value type with no view in it so the rule it encodes — exactly one
/// copy leaves the removal set, exactly one joins it — is testable on its own.
public struct DuplicateKeeperSelection: Sendable {
    /// The copy the user chose, per content hash.
    private var chosen: [String: URL] = [:]

    public init() {}

    /// The copy this group keeps: the user's choice while it is still one of the
    /// group's members, otherwise the scanner's proposal.
    public func keeper(of group: DuplicateGroup) -> URL? {
        if let chosen = chosen[group.contentHash],
           group.members.contains(where: { $0.url == chosen }) {
            return chosen
        }
        return group.members.first(where: \.isRecommendedToKeep)?.url
            ?? group.members.first?.url
    }

    /// Makes `url` the copy this group keeps.
    ///
    /// Returns the pair whose selection state has to change — the copy that
    /// leaves the removal set and the copy that joins it — or `nil` when the
    /// group already keeps that copy, so a click on the current keeper is not a
    /// selection change. Nothing else in the group is touched: rebuilding the
    /// whole group's selection would discard the individual choices the user had
    /// already made in it.
    ///
    /// A copy the group does not hold is refused: there is nothing to keep.
    @discardableResult
    public mutating func choose(_ url: URL, in group: DuplicateGroup) -> (kept: URL, released: URL?)? {
        guard group.members.contains(where: { $0.url == url }) else { return nil }
        let previous = keeper(of: group)
        guard previous != url else { return nil }
        chosen[group.contentHash] = url
        return (kept: url, released: previous)
    }

    /// Forgets every choice, for a result set that no longer exists.
    public mutating func removeAll() {
        chosen.removeAll()
    }
}
