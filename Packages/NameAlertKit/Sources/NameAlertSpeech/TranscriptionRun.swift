import NameAlertCore
import os

/// One call of `transcribe`: the stream it feeds and the task that feeds it. Every engine records its latest run under
/// a lock before `transcribe` returns, so a `stop` that comes right after always finds and ends it.
///
/// The task is created after the run is recorded, so it is handed over afterwards. A run that was ended in between
/// cancels it the moment it arrives.
final class TranscriptionRun: Sendable {
    let output: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation
    private let work = OSAllocatedUnfairLock(initialState: Work())

    private struct Work: Sendable {
        var task: Task<Void, Never>?
        var isCancelled = false
    }

    init(output: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation) {
        self.output = output
    }

    /// Hands over the task that feeds the stream.
    func start(_ task: Task<Void, Never>) {
        let cancelled = work.withLock { work in
            work.task = task
            return work.isCancelled
        }
        if cancelled { task.cancel() }
    }

    /// Stops the work, now or as soon as the task is handed over.
    func cancel() {
        let task = work.withLock { work in
            work.isCancelled = true
            return work.task
        }
        task?.cancel()
    }

    /// Stops the work and finishes the stream.
    func end() {
        cancel()
        output.finish()
    }

    /// Returns once the task has returned, or at once if it was never handed over.
    func finished() async {
        await work.withLock { $0.task }?.value
    }
}
