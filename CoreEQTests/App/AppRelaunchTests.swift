import Foundation
import Testing

/// The script that reopens CoreEQ once it has quit.
///
/// Run through `/bin/sh`, so the one thing that must not happen is a value
/// becoming part of the script: a bundle path with a quote in it would then be
/// code. Both values go in as positional arguments and the script only ever
/// refers to them quoted.
struct AppRelaunchTests {

    @Test func valuesArePassedAsArgumentsNotSplicedIntoTheScript() {
        let path = "/Applications/My \"Apps\"; rm -rf ~/CoreEQ.app"
        let arguments = AppRelaunch.arguments(pid: 4242, bundlePath: path)

        #expect(arguments.count == 4)
        #expect(arguments[0] == "-c")
        #expect(!arguments[1].contains("4242"))
        #expect(!arguments[1].contains(path))
        #expect(arguments[2] == "4242")
        #expect(arguments[3] == path)
    }

    /// The new instance must not start before this one has gone, or two copies
    /// would tap the same audio.
    @Test func theScriptWaitsForThisProcessBeforeOpening() throws {
        let script = AppRelaunch.arguments(pid: 1, bundlePath: "/x.app")[1]
        let wait = try #require(script.range(of: "kill -0 \"$0\""))
        let open = try #require(script.range(of: "open \"$1\""))

        #expect(wait.lowerBound < open.lowerBound)
    }
}
