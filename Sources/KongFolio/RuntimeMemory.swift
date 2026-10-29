import Foundation
import Darwin

struct RuntimeMemory {
    static func residentMB() -> Int {
        var value = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Int(value.resident_size / 1048576) : 0
    }
    static func constrained(resident: Int, budget: Int, wasConstrained: Bool) -> Bool {
        guard resident > 0 else { return wasConstrained }
        return resident > max(128,budget) || (wasConstrained && resident > max(128,budget)*3/4)
    }
}
