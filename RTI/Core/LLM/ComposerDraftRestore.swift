import Foundation

/// Decides what a returned draft does to the composer field.
///
/// A draft comes back after a Stop during a vault search, a failed save, a
/// screen-policy change or a Chats hand-over. The field may already hold a
/// newer draft, for example a follow-up queued while the search ran. Text the
/// user typed is never overwritten: the returned draft goes into an empty
/// field only, and is dropped otherwise.
public enum ComposerDraftRestore {
    /// The text the field should hold, or nil to leave the field as it is.
    public static func fieldText(current: String, restored: String?) -> String? {
        guard let restored, !restored.isEmpty,
              current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return restored
    }
}
