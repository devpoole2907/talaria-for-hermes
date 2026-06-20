import Foundation

extension Date {
    var relativeShort: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    var dayAndTime: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
