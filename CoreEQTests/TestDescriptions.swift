import Testing

// Without these, a parameterised case is labelled with the type's full
// synthesised description — every filter, every identifier — and the one thing
// that identifies the case is lost in it.

extension EQProfile: CustomTestStringConvertible {
    var testDescription: String { name }
}

extension EQFilter: CustomTestStringConvertible {
    var testDescription: String {
        band.map { "band \($0)" } ?? "\(kind.rawValue) at \(Int(frequency)) Hz"
    }
}
