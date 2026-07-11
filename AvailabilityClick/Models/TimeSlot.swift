import Foundation

struct TimeSlot: Equatable, Hashable {
    let start: Date
    let end: Date

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}
