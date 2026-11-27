// Agent Privilege Manager: the Touch ID (or login password) dialog of the omp command
// guard, shown with the given reason. Exit 0 when the user authenticates, 1 when they
// decline or fail, 2 when this Mac offers no owner authentication.
// Build and install: scripts/build-agent-privilege-manager.sh
import Foundation
import LocalAuthentication

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

final class Outcome: @unchecked Sendable {
    var granted = false
    var message = ""
}

let reason = CommandLine.arguments.dropFirst().joined(separator: " ")
if reason.isEmpty { fail("usage: agent-privilege-manager <reason>", 2) }

let context = LAContext()
var unavailable: NSError?
if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) {
    fail(unavailable?.localizedDescription ?? "owner authentication unavailable", 2)
}

let outcome = Outcome()
let done = DispatchSemaphore(value: 0)
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
    outcome.granted = success
    outcome.message = error?.localizedDescription ?? ""
    done.signal()
}
done.wait()
if !outcome.granted { fail(outcome.message.isEmpty ? "declined" : outcome.message, 1) }
