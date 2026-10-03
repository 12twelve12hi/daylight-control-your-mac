import Foundation

/// `Daylight [--self-test] [--perf-log] [--latency-probe] [--port N]`.
struct LaunchArguments: Equatable {
    var selfTest = false
    var perfLog = false
    var latencyProbe = false
    var port: UInt16?

    static func parse(_ arguments: [String]) -> LaunchArguments {
        var result = LaunchArguments()
        var index = 1
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
            default:
                if argument.hasPrefix("--port="), let value = UInt16(argument.dropFirst("--port=".count)) {
                    result.port = value
                }
            }
            index += 1
        }
        return result
    }
}
