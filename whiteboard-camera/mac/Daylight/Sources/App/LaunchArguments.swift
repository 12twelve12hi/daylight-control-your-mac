import Foundation

/// `Daylight [--self-test] [--perf-log] [--latency-probe] [--port N]`, plus the UI test options
/// `--ui-test [--ui-test-appearance light|dark] [--ui-test-open <surface>] [--ui-test-settings-tab <name>]
/// [--ui-test-overlay-enabled]` (docs/handoff/vp-mac-ui.md, "Design contract"). The `--ui-test-*` options apply only
/// together with `--ui-test`; without it `uiTestOptions` stays empty. Unknown values are ignored; a repeated option
/// keeps the last recognised value.
struct LaunchArguments: Equatable {
    var selfTest = false
    var perfLog = false
    var latencyProbe = false
    var port: UInt16?
    var uiTest = false
    var uiTestOptions = UITestOptions()

    static func parse(_ arguments: [String]) -> LaunchArguments {
        var result = LaunchArguments()
        var index = 1
        /// The value after an option, when there is one that is not itself an option; `index` moves past it.
        func takeValue() -> String? {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return nil }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--self-test": result.selfTest = true
            case "--perf-log": result.perfLog = true
            case "--latency-probe": result.latencyProbe = true
            case "--port":
                if index + 1 < arguments.count, let value = UInt16(arguments[index + 1]) {
                    result.port = value
                    index += 1
                }
            case "--ui-test": result.uiTest = true
            case "--ui-test-appearance":
                if let value = takeValue(), let appearance = UITestAppearance(rawValue: value.lowercased()) {
                    result.uiTestOptions.appearance = appearance
                }
            case "--ui-test-open":
                if let value = takeValue(), let surface = UITestSurface(rawValue: value.lowercased()) {
                    result.uiTestOptions.open = surface
                }
            case "--ui-test-settings-tab":
                if let value = takeValue(), let tab = SettingsTab.named(value) {
                    result.uiTestOptions.settingsTab = tab
                }
            case "--ui-test-overlay-enabled": result.uiTestOptions.overlayEnabled = true
            default:
                if argument.hasPrefix("--port="), let value = UInt16(argument.dropFirst("--port=".count)) {
                    result.port = value
                }
            }
            index += 1
        }
        if !result.uiTest { result.uiTestOptions = UITestOptions() }
        return result
    }
}
