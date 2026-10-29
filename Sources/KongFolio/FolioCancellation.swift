import Foundation

enum FolioCancellation {
    static func message(_ error:Error) -> String? { matches(error) ? nil : error.localizedDescription }
    static func matches(_ error: Error, depth: Int = 0) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        if value.domain == "Swift.CancellationError" && value.code == 1 { return true }
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return true }
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return true }
        if depth < 4, let cause = value.userInfo[NSUnderlyingErrorKey] as? Error { return matches(cause,depth:depth+1) }
        return false
    }
}
