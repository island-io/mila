import Foundation
import Combine

/// Fires a one-shot LLM call against a finished recording's transcript and
/// stores the result on the `Recording.summary` field.
///
/// Sits downstream of `TranscriptionService.process(...)` so a freshly-
/// transcribed recording with an empty summary gets one without the user
/// having to opt into Live AI mode. Live AI mode itself still produces
/// summaries during recording — this only fires when there isn't one
/// yet, so we never overwrite the live session's output and never spend
/// a second CLI call when one already happened.
///
/// Uses the same `LLMRunner` + sandboxing the rename sheet's "Send to
/// Claude" path uses, so any `$PATH` / TCC-popup mitigations carry over
/// for free.
@MainActor
final class RecordingSummarizer: ObservableObject {
    private let store: RecordingStore
    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings

    /// Background work tracked per-recording so a second `summarizeIfNeeded`
    /// call for the same id (e.g. a re-transcribe trigger) doesn't spawn
    /// two overlapping CLI invocations.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Timeout for the one-shot summary call. Comfortably larger than
    /// the live-session per-tick budget because cold-starting `claude`
    /// can take 30–60s on the first invocation after a sleep / fresh
    /// boot. Foreground UI isn't blocked — the recording is already
    /// saved with `.completed` status before we get here — so the
    /// generous bound is fine.
    var timeoutSeconds: TimeInterval = 300

    init(store: RecordingStore,
         llmSettings: LLMSettings,
         liveAISettings: LiveAISettings) {
        self.store = store
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings
    }

    /// Returns true iff `recording` needs (and can get) a one-shot summary.
    /// Public so callers + tests can ask the same question we ask
    /// internally without re-deriving the predicate.
    func shouldSummarize(_ recording: Recording) -> Bool {
        guard llmSettings.isConfigured else { return false }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return false }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty { return false }
        return true
    }

    /// Kick off a background summary for `recording` if the gate above
    /// allows. Returns immediately — the caller doesn't await the LLM.
    /// Idempotent: a second call while one is in flight is a no-op so a
    /// re-enqueue from the transcription path can't double-bill.
    func summarizeIfNeeded(_ recording: Recording) {
        guard shouldSummarize(recording) else { return }
        guard inFlight[recording.id] == nil else { return }
        let id = recording.id
        let tool = llmSettings.tool
        let executableOverride = llmSettings.executablePath.isEmpty
            ? nil
            : llmSettings.executablePath
        let model = liveAISettings.model
        let promptLanguageName: String = {
            switch liveAISettings.outputLanguage {
            case .auto:
                return recording.fullText.isPredominantlyHebrew ? "Hebrew" : "English"
            case .english:
                return "English"
            case .hebrew:
                return "Hebrew"
            }
        }()
        let prompt = liveAISettings.summaryPrompt
            .replacingOccurrences(of: "{{LANGUAGE}}", with: promptLanguageName)
        let transcript = recording.fullText
        let timeout = timeoutSeconds
        let task = Task { @MainActor [weak self] in
            defer { self?.inFlight[id] = nil }
            do {
                print("RecordingSummarizer: starting one-shot summary for \(id.uuidString.prefix(8)) transcript=\(transcript.count)c")
                let raw = try await LLMRunner.run(
                    tool: tool,
                    prompt: prompt,
                    transcript: transcript,
                    executablePathOverride: executableOverride,
                    model: model.isEmpty ? nil : model,
                    timeout: timeout
                )
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else {
                    print("RecordingSummarizer: empty output — skipping update")
                    return
                }
                // The recording may have been deleted, renamed, or had a
                // live-session summary land between enqueue and now. Re-
                // fetch and re-check the gate so we never clobber a
                // summary the user can already see.
                guard let self else { return }
                guard var current = self.store.recordings.first(where: { $0.id == id }) else {
                    print("RecordingSummarizer: recording \(id.uuidString.prefix(8)) is gone, dropping summary")
                    return
                }
                let existing = (current.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !existing.isEmpty {
                    print("RecordingSummarizer: recording \(id.uuidString.prefix(8)) already has a summary, dropping")
                    return
                }
                current.summary = cleaned
                self.store.update(current)
                print("RecordingSummarizer: saved summary for \(id.uuidString.prefix(8)) (\(cleaned.count)c)")
            } catch {
                print("RecordingSummarizer: failed for \(id.uuidString.prefix(8)) — \(error.localizedDescription)")
            }
        }
        inFlight[id] = task
    }

    /// Cancel any in-flight summary work for `recordingID`. Used when a
    /// recording is being permanently deleted so we don't spend a CLI
    /// call on output that has nowhere to land.
    func cancel(recordingID: UUID) {
        if let task = inFlight.removeValue(forKey: recordingID) {
            task.cancel()
        }
    }
}
