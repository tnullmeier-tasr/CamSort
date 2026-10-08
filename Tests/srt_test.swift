import Foundation
let r = SRTSpeed.analyze(URL(fileURLWithPath: CommandLine.arguments[1]))
switch r {
case .speed(let v): print("speed", v)
case .noGPS: print("noGPS")
case .unreadable: print("unreadable")
}
// synthetic GPS test: 10 m per second north = 36 km/h
var s = ""
for i in 0..<11 {
    let lat = 47.0 + Double(i) * 10.0 / 111_195.0
    s += "\(i+1)\n00:00:\(String(format: "%02d", i)),000 --> 00:00:\(String(format: "%02d", i)),033\n[latitude: \(lat)] [longitude: 8.000000]\n\n"
}
print("synthetic", SRTSpeed.averageKmh(text: s) ?? -1)
