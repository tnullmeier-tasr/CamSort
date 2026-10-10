import Foundation

/// Restzeit-Schätzung: misst die bisherige Geschwindigkeit und rechnet hoch. Pausen werden herausgerechnet.
struct ETA {
    private var start: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    mutating func begin() { start = Date(); pausedAt = nil; pausedTotal = 0 }
    mutating func pause() { if pausedAt == nil { pausedAt = Date() } }
    mutating func resume() { if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p); pausedAt = nil } }

    var elapsed: TimeInterval {
        guard let s = start else { return 0 }
        return (pausedAt ?? Date()).timeIntervalSince(s) - pausedTotal
    }

    /// done/total in beliebiger Einheit (Bytes, Clips …)
    func remaining(done: Double, total: Double) -> TimeInterval? {
        let e = elapsed
        guard done > 0, total > done, e > 3 else { return nil }   // erst nach ein paar Sekunden schätzen
        return e / done * (total - done)
    }

    static func text(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "Restzeit wird berechnet …" }
        if t < 60 { return "noch weniger als 1 Minute" }
        let m = Int(t / 60 + 0.5)
        if m < 60 { return "noch ca. \(m) Min." }
        return "noch ca. \(m / 60) Std. \(m % 60) Min."
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) Sek." }
        if s < 3600 { return "\(s / 60) Min. \(s % 60) Sek." }
        return "\(s / 3600) Std. \((s % 3600) / 60) Min."
    }
}
