import Foundation

extension Duration {
    /// Duration in milliseconds, for timing logs.
    var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }
}
