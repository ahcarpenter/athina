import Foundation

/// A serial executor backed by a dedicated thread with its own run loop.
///
/// Accessibility observers need a run loop to deliver notifications, and AX
/// reads of a hung app can block for the messaging timeout, so both live on
/// this thread instead of the main thread.
final class RunLoopExecutor: SerialExecutor, @unchecked Sendable {
    private let thread: Thread
    private let runLoop: CFRunLoop

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let box = RunLoopBox()
        let thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive when no sources are attached.
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        self.thread = thread
        self.runLoop = box.runLoop!
    }

    private final class RunLoopBox: @unchecked Sendable {
        var runLoop: CFRunLoop?
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            unowned.runSynchronously(on: executor)
        }
        CFRunLoopWakeUp(runLoop)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(Thread.current === thread, "expected to run on \(thread.name ?? "run loop thread")")
    }

    var currentRunLoop: CFRunLoop { runLoop }
}

/// Global actor for everything that touches the accessibility API.
@globalActor
public actor AXActor {
    public static let shared = AXActor()
    static let executor = RunLoopExecutor(name: "athina.accessibility")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        AXActor.executor.asUnownedSerialExecutor()
    }

    /// The run loop AX observer sources are scheduled on.
    static var runLoop: CFRunLoop { executor.currentRunLoop }
}
