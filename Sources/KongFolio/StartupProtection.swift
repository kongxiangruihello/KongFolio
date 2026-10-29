import Foundation

struct StartupProtection {
    struct State: Codable {
        var clean = true
        var reviewRequired = false
        var opening: String?
        var interrupted: [String:Int] = [:]
        var excludedSlots: Set<String> = []
    }
    var storage: URL
    var url: URL { storage.appendingPathComponent("StartupProtection.json") }
    func read() -> State { (try? JSONDecoder().decode(State.self,from:Data(contentsOf:url))) ?? State() }
    func write(_ state: State) throws {
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        try JSONEncoder().encode(state).write(to:url,options:.atomic)
    }
    func begin() throws -> State {
        var state: State
        if FileManager.default.fileExists(atPath:url.path) {
            do { state = try JSONDecoder().decode(State.self,from:Data(contentsOf:url)) }
            catch {
                try FileManager.default.copyItem(at:url,to:url.deletingPathExtension().appendingPathExtension("damaged-"+UUID().uuidString+".json"))
                state = State(clean:false,reviewRequired:true)
            }
        } else { state = State() }
        if !state.clean { state.reviewRequired = true; if let path = state.opening { state.interrupted[path,default:0] += 1 } }
        state.clean = false; state.opening = nil; try write(state); return state
    }
    func opening(_ path: String?) { var state = read(); state.opening = path; try? write(state) }
    func requireReview() throws { var state = read(); state.reviewRequired = true; try write(state) }
    func clean() { var state = read(); state.clean = true; state.opening = nil; try? write(state) }
    func finishReview(excluding slots: Set<String>) throws { var state = read(); state.reviewRequired = false; state.excludedSlots.formUnion(slots); try write(state) }
}
