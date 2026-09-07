import Foundation
import Combine

/// Test-only instrumentation for how often the App scene re-evaluates, and
/// which App-level object made it do so.
///
/// Every `@StateObject` on `MilaApp` subscribes the App `body` to that
/// object's `objectWillChange`; a publish re-evaluates the body and re-diffs
/// every scene (window root view, sidebar outline view, main menu) at
/// ~10–20 ms a time. A single object publishing at audio-buffer cadence is
/// therefore a whole core for as long as it keeps publishing — which is how a
/// recording pinned the main thread at 60–75% for its full duration (#280),
/// and why `RecordingMeters` / `InputLevelMeter` exist. Nothing in the
/// pipeline logs "the App body ran", so the regression is invisible until a
/// user opens Activity Monitor.
///
/// This probe makes it countable. `MilaApp.body` bumps `bodyEvaluations` on
/// each evaluation, and `MilaApp.init` registers every App-level object by
/// property name with a type-erased `objectWillChange`. `AppSceneChurnTests`
/// runs a fake recording in the app-hosted test bundle and asserts a publish
/// budget per object — a count, not a timing, so it holds on a loaded CI
/// runner — and names the object that blew it.
///
/// Compiled into release builds as an empty shell: the counter and the
/// registry only exist under `DEBUG`, and `noteBodyEvaluation()` is a no-op
/// there. Referencing it from `body` unconditionally keeps the App source
/// free of `#if` inside a result builder.
@MainActor
final class AppSceneChurnProbe {
    static let shared = AppSceneChurnProbe()

    /// One App-level object as seen by the test: its `MilaApp` property name
    /// and a publisher that fires whenever it is about to publish.
    struct Registered {
        let name: String
        let willChange: AnyPublisher<Void, Never>

        /// Erases `object.objectWillChange` while its concrete type is still
        /// known — at the `MilaApp.init` call site — so the registry never
        /// has to open an `any ObservableObject` (which Swift 5.10 refuses:
        /// the protocol's publisher is an associated type).
        static func of<O: ObservableObject>(_ name: String, _ object: O) -> Registered {
            Registered(name: name,
                       willChange: object.objectWillChange
                           .map { _ in () }
                           .eraseToAnyPublisher())
        }
    }

    /// Number of `MilaApp.body` evaluations so far in this process.
    private(set) var bodyEvaluations = 0
    /// Every App-level `@StateObject`, in registration order.
    private(set) var appLevelObjects: [Registered] = []
    /// The two objects a churn test drives directly. Weak: the App owns them.
    private(set) weak var session: RecordingSession?
    private(set) weak var actions: QuickActionsController?

    private init() {}

    /// Called from `MilaApp.body`. A no-op outside `DEBUG`.
    static func noteBodyEvaluation() {
        #if DEBUG
        shared.bodyEvaluations += 1
        #endif
    }

    /// Called once from `MilaApp.init` with every App-level object. A no-op
    /// outside `DEBUG` so release builds keep no extra references.
    func registerAppLevelObjects(session: RecordingSession,
                                 actions: QuickActionsController,
                                 _ objects: [Registered]) {
        #if DEBUG
        self.session = session
        self.actions = actions
        appLevelObjects = objects
        #endif
    }
}
