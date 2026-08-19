/// The behavioural family RTI's prompts are shaped for. Modes (built-in +
/// user-defined personas) were removed in the 2026-08-19 strip — RTI now
/// always runs as the single built-in Meeting persona — but `ModeKind`
/// stays because the CORE prompt catalogue (`PromptCatalogue`,
/// `PromptComposer`, `AssistantAction`) is keyed by it.
public enum ModeKind: Sendable {
    case meeting, interview, coding, other
}
