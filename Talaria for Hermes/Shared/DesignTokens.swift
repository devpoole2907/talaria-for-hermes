import SwiftUI

enum Spacing {
    static let xs: Double = 4
    static let s: Double = 8
    static let m: Double = 12
    static let l: Double = 16
    static let xl: Double = 24
    static let xxl: Double = 32
}

enum Radii {
    static let small: Double = 6
    static let medium: Double = 10
    static let large: Double = 16
}

enum AnimationDurations {
    static let quick: Duration = .milliseconds(150)
    static let standard: Duration = .milliseconds(250)
}

enum Palette {
    static let user: Color = .accentColor
    static let assistant: Color = .primary
    static let toolPending: Color = .orange
    static let toolRunning: Color = .blue
    static let toolComplete: Color = .green
    static let toolError: Color = .red
}

enum TapTarget {
    static let minimum: Double = 44
}
