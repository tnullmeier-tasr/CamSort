import Foundation

/// Liest DJI-SRT-Dateien und berechnet die Durchschnittsgeschwindigkeit eines Clips.
enum SRTSpeed {
    /// Ø km/h: bevorzugt aus GPS-Strecke ÷ Dauer, sonst Mittel der H.S-Werte (m/s). nil = nicht lesbar.
    enum Result { case speed(Double), noGPS, unreadable }

    static func analyze(_ url: URL) -> Result {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
              text.contains("-->") else { return .unreadable }
        if let v = averageKmh(text: text) { return .speed(v) }
        return .noGPS
    }

    static func averageKmh(_ url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return averageKmh(text: text)
    }

    static func averageKmh(text: String) -> Double? {
        var points: [(t: Double, lat: Double, lon: Double)] = []
        var hs: [Double] = []

        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            guard let t = firstTime(b) else { continue }
            if let (lat, lon) = coords(b), lat != 0 || lon != 0 { points.append((t, lat, lon)) }
            if let v = number(after: #"H\.S\s*:?\s*"#, in: b) { hs.append(abs(v)) }
        }

        if points.count >= 2, let first = points.first, let last = points.last, last.t > first.t {
            var dist = 0.0
            for i in 1..<points.count { dist += haversine(points[i - 1], points[i]) }
            return dist / (last.t - first.t) * 3.6
        }
        if !hs.isEmpty { return hs.reduce(0, +) / Double(hs.count) * 3.6 }
        return nil
    }

    private static func firstTime(_ b: String) -> Double? {
        guard let r = b.range(of: #"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->"#, options: .regularExpression) else { return nil }
        let p = b[r].split(whereSeparator: { ":,. -".contains($0) || $0 == ">" }).compactMap { Double($0) }
        guard p.count >= 4 else { return nil }
        return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / 1000
    }

    private static func coords(_ b: String) -> (Double, Double)? {
        if let lat = number(after: #"latitude\s*:\s*"#, in: b), let lon = number(after: #"longitude\s*:\s*"#, in: b) { return (lat, lon) }
        // Älteres Format: GPS(lon, lat, alt)
        if let r = b.range(of: #"GPS\s*\(\s*-?\d+\.\d+\s*,\s*-?\d+\.\d+"#, options: .regularExpression) {
            let nums = b[r].dropFirst(3).split(whereSeparator: { "(, ".contains($0) }).compactMap { Double($0) }
            if nums.count >= 2 { return (nums[1], nums[0]) }
        }
        return nil
    }

    private static func number(after prefix: String, in s: String) -> Double? {
        guard let r = s.range(of: prefix + #"-?\d+(\.\d+)?"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let sub = s[r]
        guard let n = sub.range(of: #"-?\d+(\.\d+)?$"#, options: .regularExpression) else { return nil }
        return Double(sub[n])
    }

    private static func haversine(_ a: (t: Double, lat: Double, lon: Double), _ b: (t: Double, lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
