import BackgroundTasks
import Foundation

/// CPU/network-only, user-initiated work. No GPU entitlement and no deferred queue.
/// Continued-processing registrations are explicitly exempt from launch-time registration.
@available(iOS 26.0, *)
@MainActor
final class ContinuedRunCoordinator {
    static let shared = ContinuedRunCoordinator()
    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var total = 1
    private var completed = 0
    var isActive: Bool { task != nil }

    func begin(total: Int, onReady: @escaping () -> Void, onExpiration: @escaping () -> Void) -> Bool {
        finish(success: false)
        let identifier = (Bundle.main.bundleIdentifier ?? "app.nodescope.speedtest") + ".probe." + UUID().uuidString
        self.identifier = identifier
        self.total = max(1, total); completed = 0
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] delivered in
            guard let continued = delivered as? BGContinuedProcessingTask else { delivered.setTaskCompleted(success: false); return }
            Task { @MainActor [weak self] in
                guard let self, self.identifier == identifier else { continued.setTaskCompleted(success: false); return }
                self.task = continued
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.identifier == identifier else { return }
                        self.finish(success: false)
                        onExpiration()
                    }
                }
                self.updateProgress(completed: self.completed, total: self.total)
                onReady()
            }
        }
        guard registered else { self.identifier = nil; return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "节点测速", subtitle: "0 / \(total) 个节点")
        // Never queue downloads to start later without the user observing the selected network.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request); return true }
        catch { self.identifier = nil; return false }
    }

    func updateProgress(completed: Int, total: Int) {
        self.completed = completed; self.total = max(1, total)
        task?.progress.totalUnitCount = Int64(self.total)
        task?.progress.completedUnitCount = Int64(min(completed, self.total))
        task?.updateTitle("节点测速", subtitle: "已完成 \(completed) / \(total) 个节点")
    }

    func finish(success: Bool) {
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
        let finished = task; task = nil
        finished?.setTaskCompleted(success: success)
    }
}
