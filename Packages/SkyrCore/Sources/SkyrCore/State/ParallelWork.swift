import Foundation

/// Runs `work` on every element at once and returns the results in the elements' order.
///
/// Written with plain tasks on purpose. On the Swift 6.2 toolchain a `withTaskGroup` built in a
/// release configuration can hand back no results at all for children it was given (seen on
/// 2026-09-13: the library scan listed one folder, collected nothing, and emptied the whole
/// library). Independent tasks awaited one by one do not have that problem. Cancelling the caller
/// cancels every task still running.
public nonisolated func parallelResults<Element: Sendable, Output: Sendable>(
    _ elements: [Element],
    priority: TaskPriority = .userInitiated,
    _ work: @escaping @Sendable (Element) async -> Output
) async -> [Output] {
    let tasks = elements.map { element in
        Task.detached(priority: priority) { await work(element) }
    }
    return await withTaskCancellationHandler {
        var outputs: [Output] = []
        outputs.reserveCapacity(tasks.count)
        for task in tasks {
            outputs.append(await task.value)
        }
        return outputs
    } onCancel: {
        for task in tasks { task.cancel() }
    }
}
