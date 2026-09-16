import Cocoa
import SwiftUI
import AVFoundation
import IOKit.ps
import CryptoKit
import Compression

// MARK: - Config & Storage Keys

private let kAppBundleID = "com.londonvista.iPhoneBatteryWidget"
private let kFrameOriginX = "ibw.frameOriginX"
private let kFrameTopY    = "ibw.frameTopY"
private let kCachedDevicesKey = "ibw.cachedDevicesData.v2"
private let kHistoryLogKey = "ibw.batteryHistoryLog.v2"
private let kSelectedTabKey = "ibw.selectedDeviceTab"
private let kPollInterval: TimeInterval = 2.0
private let kIOSPollInterval: TimeInterval = 3.0

// MARK: - Privacy & Device Name Sanitizer

func cleanDeviceDisplayName(_ raw: String?, fallback: String = "iPhone") -> String {
    guard let raw = raw, !raw.isEmpty else { return fallback }
    var clean = raw
    // Strip possessives (e.g. "Alex's iPhone" -> "iPhone", "Work's iPad" -> "iPad")
    clean = clean.replacingOccurrences(of: "(?i)^[a-z0-9_\\-\\s]+['’]s\\s+", with: "", options: .regularExpression)
    // Strip single initial prefixes (e.g. "J. iPhone" -> "iPhone")
    clean = clean.replacingOccurrences(of: "(?i)^[a-z]\\.\\s*", with: "", options: .regularExpression)
    clean = clean.replacingOccurrences(of: "^['’]s\\s*", with: "", options: .regularExpression)
    clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.isEmpty { return fallback }
    return clean
}

// MARK: - History Point & Archives

struct BatteryHistoryPoint: Codable, Identifiable, Equatable {
    var id: String { "\(deviceId)_\(date.timeIntervalSince1970)" }
    let deviceId: String
    var deviceName: String? = nil
    var deviceType: DeviceType? = nil
    let date: Date
    let batteryPct: Double
    let healthPct: Double?
    let cycleCount: Int?
    let capacityMah: Int?
    let fullChargeMah: Int?
    var designCapacityMah: Int? = nil
    let temperatureC: Double?
    var batteryManufactureDate: Date? = nil
    var deviceManufactureDate: Date? = nil
    var firstUseDate: Date? = nil
    var isCharging: Bool? = nil
    var isACConnected: Bool? = nil
    var chargingWatts: Double? = nil
    var deviceModel: String? = nil
    var osVersion: String? = nil
    var appVersion: String? = nil
    var batterySerial: String? = nil
    var deviceSerial: String? = nil
}

// MARK: - Apple Model Release Database & Age

enum AppleModelDatabase {
    static func lookupReleaseDate(model: String) -> (marketingName: String, releaseDate: Date)? {
        let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        func d(_ str: String) -> Date { df.date(from: str) ?? Date() }
        
        let db: [String: (String, Date)] = [
            // Mac Apple Silicon
            "MacBookAir10,1": ("MacBook Air (M1, 2020)", d("2020-11-17")),
            "MacBookPro17,1": ("MacBook Pro 13\" (M1, 2020)", d("2020-11-17")),
            "Macmini9,1": ("Mac mini (M1, 2020)", d("2020-11-17")),
            "iMac21,1": ("iMac 24\" (M1, 2021)", d("2021-04-30")),
            "iMac21,2": ("iMac 24\" (M1, 2021)", d("2021-04-30")),
            "MacBookPro18,1": ("MacBook Pro 16\" (M1 Pro, 2021)", d("2021-10-26")),
            "MacBookPro18,2": ("MacBook Pro 16\" (M1 Max, 2021)", d("2021-10-26")),
            "MacBookPro18,3": ("MacBook Pro 14\" (M1 Pro, 2021)", d("2021-10-26")),
            "MacBookPro18,4": ("MacBook Pro 14\" (M1 Max, 2021)", d("2021-10-26")),
            "Mac13,1": ("Mac Studio (M1 Max, 2022)", d("2022-03-18")),
            "Mac13,2": ("Mac Studio (M1 Ultra, 2022)", d("2022-03-18")),
            "Mac14,2": ("MacBook Air 13\" (M2, 2022)", d("2022-07-15")),
            "Mac14,7": ("MacBook Pro 13\" (M2, 2022)", d("2022-06-24")),
            "Mac14,15": ("MacBook Air 15\" (M2, 2023)", d("2023-06-13")),
            "Mac14,3": ("Mac mini (M2, 2023)", d("2023-01-24")),
            "Mac14,12": ("Mac mini (M2 Pro, 2023)", d("2023-01-24")),
            "Mac14,6": ("MacBook Pro 16\" (M2 Max, 2023)", d("2023-01-24")),
            "Mac14,10": ("MacBook Pro 16\" (M2 Pro, 2023)", d("2023-01-24")),
            "Mac14,9": ("MacBook Pro 14\" (M2 Pro, 2023)", d("2023-01-24")),
            "Mac14,5": ("MacBook Pro 14\" (M2 Max, 2023)", d("2023-01-24")),
            "Mac15,12": ("MacBook Air 13\" (M3, 2024)", d("2024-03-08")),
            "Mac15,13": ("MacBook Air 15\" (M3, 2024)", d("2024-03-08")),
            "Mac15,3": ("MacBook Pro 14\" (M3, 2023)", d("2023-11-07")),
            "Mac15,6": ("MacBook Pro 14\" (M3 Pro, 2023)", d("2023-11-07")),
            "Mac15,8": ("MacBook Pro 14\" (M3 Max, 2023)", d("2023-11-07")),
            "Mac15,7": ("MacBook Pro 16\" (M3 Pro, 2023)", d("2023-11-07")),
            "Mac15,9": ("MacBook Pro 16\" (M3 Max, 2023)", d("2023-11-07")),
            "Mac16,1": ("MacBook Pro 14\" (M4, 2024)", d("2024-11-08")),
            "Mac16,6": ("Mac mini (M4, 2024)", d("2024-11-08")),
            "Mac16,10": ("iMac 24\" (M4, 2024)", d("2024-11-08")),
            
            // Intel Macs
            "MacBookPro16,1": ("MacBook Pro 16\" (2019)", d("2019-11-13")),
            "MacBookPro15,1": ("MacBook Pro 15\" (2018)", d("2018-07-12")),
            "MacBookAir9,1": ("MacBook Air (Retina, 2020)", d("2020-03-18")),
            "MacBookAir8,2": ("MacBook Air (Retina, 2019)", d("2019-07-09")),
            "MacBookAir8,1": ("MacBook Air (Retina, 2018)", d("2018-10-30")),
            
            // iPhones
            "iPhone18,1": ("iPhone 17 Pro", d("2025-09-19")),
            "iPhone18,2": ("iPhone 17 Pro Max", d("2025-09-19")),
            "iPhone18,3": ("iPhone 17", d("2025-09-19")),
            "iPhone18,4": ("iPhone 17 Air", d("2025-09-19")),
            "iPhone17,1": ("iPhone 16 Pro", d("2024-09-20")),
            "iPhone17,2": ("iPhone 16 Pro Max", d("2024-09-20")),
            "iPhone17,3": ("iPhone 16", d("2024-09-20")),
            "iPhone17,4": ("iPhone 16 Plus", d("2024-09-20")),
            "iPhone16,1": ("iPhone 15 Pro", d("2023-09-22")),
            "iPhone16,2": ("iPhone 15 Pro Max", d("2023-09-22")),
            "iPhone15,4": ("iPhone 15", d("2023-09-22")),
            "iPhone15,5": ("iPhone 15 Plus", d("2023-09-22")),
            "iPhone15,2": ("iPhone 14 Pro", d("2022-09-16")),
            "iPhone15,3": ("iPhone 14 Pro Max", d("2022-09-16")),
            "iPhone14,7": ("iPhone 14", d("2022-09-16")),
            "iPhone14,8": ("iPhone 14 Plus", d("2022-10-07")),
            "iPhone14,2": ("iPhone 13 Pro", d("2021-09-24")),
            "iPhone14,3": ("iPhone 13 Pro Max", d("2021-09-24")),
            "iPhone14,5": ("iPhone 13", d("2021-09-24")),
            "iPhone14,4": ("iPhone 13 mini", d("2021-09-24")),
            "iPhone14,6": ("iPhone SE (3rd gen)", d("2022-03-18")),
            "iPhone13,1": ("iPhone 12 mini", d("2020-11-13")),
            "iPhone13,2": ("iPhone 12", d("2020-10-23")),
            "iPhone13,3": ("iPhone 12 Pro", d("2020-10-23")),
            "iPhone13,4": ("iPhone 12 Pro Max", d("2020-11-13")),
            "iPhone12,1": ("iPhone 11", d("2019-09-20")),
            "iPhone12,3": ("iPhone 11 Pro", d("2019-09-20")),
            "iPhone12,5": ("iPhone 11 Pro Max", d("2019-09-20")),
            "iPhone12,8": ("iPhone SE (2nd gen)", d("2020-04-24")),
            "iPhone11,2": ("iPhone XS", d("2018-09-21")),
            "iPhone11,4": ("iPhone XS Max", d("2018-09-21")),
            "iPhone11,6": ("iPhone XS Max", d("2018-09-21")),
            "iPhone11,8": ("iPhone XR", d("2018-10-26")),
            "iPhone10,3": ("iPhone X", d("2017-11-03")),
            "iPhone10,6": ("iPhone X", d("2017-11-03"))
        ]
        
        return db[clean]
    }
    
    static func lookupBatterySpecs(model: String) -> (mah: Int, wh: Double) {
        let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let specs: [String: (Int, Double)] = [
            "iPhone18,1": (3945, 15.2), // iPhone 17 Pro
            "iPhone18,2": (4850, 18.8), // iPhone 17 Pro Max
            "iPhone18,3": (3650, 14.2), // iPhone 17
            "iPhone18,4": (3150, 12.1), // iPhone 17 Air
            "iPhone17,1": (3582, 13.9), // iPhone 16 Pro
            "iPhone17,2": (4685, 18.1), // iPhone 16 Pro Max
            "iPhone17,3": (3561, 13.8), // iPhone 16
            "iPhone17,4": (4674, 18.0), // iPhone 16 Plus
            "iPhone16,1": (3274, 12.7), // iPhone 15 Pro
            "iPhone16,2": (4422, 17.1), // iPhone 15 Pro Max
            "iPhone15,4": (3349, 12.9), // iPhone 15
            "iPhone15,5": (4383, 16.9), // iPhone 15 Plus
            "iPhone15,2": (3200, 12.4), // iPhone 14 Pro
            "iPhone15,3": (4323, 16.7), // iPhone 14 Pro Max
            "iPhone14,7": (3279, 12.7), // iPhone 14
            "iPhone14,8": (4325, 16.7), // iPhone 14 Plus
            "iPhone14,2": (3095, 12.0), // iPhone 13 Pro
            "iPhone14,3": (4352, 16.8), // iPhone 13 Pro Max
            "iPhone14,5": (3227, 12.4), // iPhone 13
            "iPhone13,2": (2815, 10.8), // iPhone 12
            "iPhone13,3": (2815, 10.8), // iPhone 12 Pro
            "iPhone13,4": (3687, 14.1)  // iPhone 12 Pro Max
        ]
        if let found = specs[clean] { return found }
        if clean.lowercased().contains("ipad") { return (8000, 31.0) }
        if clean.lowercased().contains("mac") { return (6000, 70.0) }
        return (3500, 13.5)
    }
    
    static func ageString(from startDate: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: startDate, to: Date())
        let y = max(0, comps.year ?? 0)
        let m = max(0, comps.month ?? 0)
        if y > 0 {
            return "\(y)y \(m)m"
        } else {
            return "\(m)m"
        }
    }

    static func decodeDeviceSerialDate(_ serial: String?) -> Date? {
        guard let s = serial?.trimmingCharacters(in: .whitespacesAndNewlines), s.count == 12 else { return nil }
        let yearLetter = String(s[s.index(s.startIndex, offsetBy: 3)])
        let weekLetter = String(s[s.index(s.startIndex, offsetBy: 4)])
        let yearMap: [String: (year: Int, startMonth: Int)] = [
            "C": (2020, 1), "D": (2020, 7),
            "F": (2021, 1), "G": (2021, 7),
            "H": (2022, 1), "J": (2022, 7),
            "K": (2023, 1), "L": (2023, 7),
            "M": (2024, 1), "N": (2024, 7),
            "P": (2025, 1), "Q": (2025, 7),
            "R": (2026, 1), "S": (2026, 7),
            "T": (2027, 1), "V": (2027, 7),
            "W": (2028, 1), "X": (2028, 7),
            "Y": (2029, 1), "Z": (2029, 7)
        ]
        let weekChars = ["1","2","3","4","5","6","7","8","9","C","D","E","F","G","H","J","K","L","M","N","P","Q","R","T","V","W","X","Y"]
        if let (baseYear, baseMonth) = yearMap[yearLetter],
           let weekIndex = weekChars.firstIndex(of: weekLetter) {
            var comp = DateComponents()
            comp.year = baseYear
            let addedMonths = (weekIndex * 7) / 30
            comp.month = min(12, baseMonth + addedMonths)
            comp.day = 15
            return Calendar.current.date(from: comp)
        }
        return nil
    }

    static func decodeBatterySerialDate(_ serial: String?) -> Date? {
        guard let s = serial?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 6 else { return nil }
        let chars = Array(s)
        guard let yearDigit = Int(String(chars[3])),
              let weekNum = Int(String(chars[4...5])),
              weekNum >= 1 && weekNum <= 53 else { return nil }
        
        let currentYear = Calendar.current.component(.year, from: Date())
        let currentDecade = (currentYear / 10) * 10
        var fullYear = currentDecade + yearDigit
        if fullYear > currentYear + 1 {
            fullYear -= 10
        }
        
        var comp = DateComponents()
        comp.yearForWeekOfYear = fullYear
        comp.weekOfYear = weekNum
        comp.weekday = 2
        return Calendar.current.date(from: comp)
    }

    static func lookupProcessor(model: String?, deviceName: String?, deviceType: DeviceType) -> String? {
        let text = "\(model ?? "") \(deviceName ?? "")".lowercased()
        if text.contains("iphone18,1") || text.contains("17 pro max") { return "Apple A19 Pro" }
        if text.contains("iphone18") || text.contains("17 pro") { return "Apple A19 Pro" }
        if text.contains("iphone 17") { return "Apple A19" }
        if text.contains("iphone16,2") || text.contains("16 pro max") { return "Apple A18 Pro" }
        if text.contains("iphone16,1") || text.contains("16 pro") { return "Apple A18 Pro" }
        if text.contains("iphone16") || text.contains("16 plus") || text.contains("iphone 16") { return "Apple A18" }
        if text.contains("iphone15,3") || text.contains("15 pro max") { return "Apple A17 Pro" }
        if text.contains("iphone15,2") || text.contains("15 pro") { return "Apple A17 Pro" }
        if text.contains("iphone15") || text.contains("15 plus") || text.contains("iphone 15") { return "Apple A16 Bionic" }
        if text.contains("iphone14,3") || text.contains("14 pro") { return "Apple A16 Bionic" }
        if text.contains("iphone14") || text.contains("iphone 14") { return "Apple A15 Bionic" }
        if text.contains("iphone13") || text.contains("iphone 13") { return "Apple A15 Bionic" }
        if text.contains("m4") { return "Apple M4" }
        if text.contains("m3") { return "Apple M3" }
        if text.contains("m2") { return "Apple M2" }
        if text.contains("m1") { return "Apple M1" }
        if deviceType == .mac { return "Apple Silicon" }
        return nil
    }
}

// MARK: - Generic Device Battery Info

enum DeviceType: String, Codable {
    case iphone = "iPhone"
    case ipad = "iPad"
    case mac = "Mac"
    case unknown = "Device"
    
    var iconName: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .mac: return "laptopcomputer"
        case .unknown: return "cube"
        }
    }
}

enum TemperatureTrend: String, Codable {
    case rising
    case stable
    case falling
    
    var iconName: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .stable: return "arrow.right"
        }
    }
}

struct DeviceBatteryData: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String          // UDID or Mac UUID
    let deviceName: String
    let deviceType: DeviceType
    let isConnected: Bool
    let isWirelesslyConnected: Bool
    
    // Battery Status
    let capacityInt: Int
    let capacityExact: Double
    let isCharging: Bool
    let isFullyCharged: Bool
    let isACConnected: Bool?
    
    // Detailed Stats
    let cycleCount: Int?
    let batteryHealthPct: Double?
    let voltageMv: Int?
    let amperageMa: Int?
    let chargingWatts: Double?
    var ratePctPerHour: Double? = nil
    let temperatureC: Double?
    var tempTrend: TemperatureTrend? = .stable
    let timeRemainingMins: Int?
    
    // Capacities & Storage
    let remainingMah: Int?
    let fullChargeMah: Int?
    let designCapacityMah: Int?
    let totalDiskBytes: Int64?
    let freeDiskBytes: Int64?
    
    // Dates & Info
    let batteryManufactureDate: Date?
    let deviceManufactureDate: Date?
    let firstUseDate: Date?
    let modelReleaseDate: Date?
    let lastSeenAt: Date?
    let processor: String?
    let hardwareModel: String?
    let serialNumber: String?
    let fetchedAt: Date

    /// USB-C PD handshake: true = negotiated 9/15/20 V, false = 5 V fallback, nil = n/a
    var pdHandshakeOn: Bool? = nil
    var pdInputVoltageV: Double? = nil
    var pdAdapterWatts: Int? = nil
    /// Mac SoC + display + radios, from PowerTelemetry SystemLoad (not battery charge).
    var systemLoadWatts: Double? = nil
    var adapterInWatts: Double? = nil
    /// Seconds since that device last rebooted.
    var uptimeSeconds: Int? = nil

    /// Compare fields the UI actually shows. Ignores `fetchedAt` so a poll does not rebuild the widget.
    func liveEqual(_ o: DeviceBatteryData) -> Bool {
        deviceId == o.deviceId
            && deviceName == o.deviceName
            && isConnected == o.isConnected
            && isWirelesslyConnected == o.isWirelesslyConnected
            && capacityInt == o.capacityInt
            && abs(capacityExact - o.capacityExact) < 0.05
            && isCharging == o.isCharging
            && isFullyCharged == o.isFullyCharged
            && isACConnected == o.isACConnected
            && cycleCount == o.cycleCount
            && batteryHealthPct == o.batteryHealthPct
            && voltageMv == o.voltageMv
            && amperageMa == o.amperageMa
            && abs((chargingWatts ?? 0) - (o.chargingWatts ?? 0)) < 0.15
            && abs((ratePctPerHour ?? 0) - (o.ratePctPerHour ?? 0)) < 0.15
            && abs((temperatureC ?? -999) - (o.temperatureC ?? -999)) < 0.15
            && tempTrend == o.tempTrend
            && timeRemainingMins == o.timeRemainingMins
            && remainingMah == o.remainingMah
            && fullChargeMah == o.fullChargeMah
            && totalDiskBytes == o.totalDiskBytes
            && freeDiskBytes == o.freeDiskBytes
            && pdHandshakeOn == o.pdHandshakeOn
            && abs((pdInputVoltageV ?? 0) - (o.pdInputVoltageV ?? 0)) < 0.3
            && pdAdapterWatts == o.pdAdapterWatts
            && abs((systemLoadWatts ?? 0) - (o.systemLoadWatts ?? 0)) < 0.25
            && abs((adapterInWatts ?? 0) - (o.adapterInWatts ?? 0)) < 0.4
            && (uptimeSeconds ?? 0) / 60 == (o.uptimeSeconds ?? 0) / 60
    }

    var pdVoltLabel: String? {
        guard isACConnected == true, let v = pdInputVoltageV, v > 1 else { return nil }
        return v >= 10 ? String(format: "%.0fV", v) : String(format: "%.1fV", v)
    }

    /// Negotiated PD contract (e.g. 30W), not the 20V rail.
    var pdPowerLabel: String? {
        guard isACConnected == true else { return nil }
        if let w = pdAdapterWatts, w > 0 { return "\(w)W" }
        return nil
    }
}

// MARK: - Mac Battery Reader (Native IOKit)

enum MacBatteryReader {
    private struct StaticInfo {
        var chipName: String
        var hwModelName: String
        var serialNum: String?
        var hostName: String
        var modelRelDate: Date?
        var devMfgDate: Date?
        var macFirstUseDate: Date?
        var battMfgDate: Date?
        var totalDisk: Int64?
        var freeDisk: Int64?
        var diskAt: Date
        var bootDate: Date
    }

    private static var cached: StaticInfo?
    private static var packTick = 0
    private static var lastTempC: Double?

    private static func run(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func fetch() -> DeviceBatteryData {
        // Depth 1 + unlimited width: AdapterDetails/PD without dumping every child cell + IOReport legend.
        let text = run("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery", "-d", "1", "-w", "0"])

        func regexInt(_ key: String) -> Int? {
            let pattern = "\"\(key)\"\\s*=\\s*(-?\\d+)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return Int(text[r])
        }

        func regexUInt64(_ key: String) -> UInt64? {
            let pattern = "\"\(key)\"\\s*=\\s*(\\d+)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return UInt64(text[r])
        }

        func signedMilli(_ key: String) -> Int? {
            guard let u = regexUInt64(key) else { return nil }
            return Int(Int64(bitPattern: u))
        }

        func regexBool(_ key: String) -> Bool {
            let pattern = "\"\(key)\"\\s*=\\s*(Yes|true|1)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil else { return false }
            return true
        }

        func regexStr(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s*=\\s*\"([^\"]+)\""
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }

        let cycleCount = regexInt("CycleCount")
        let voltage = regexInt("AppleRawBatteryVoltage") ?? regexInt("Voltage")
        let fullyCharged = regexBool("FullyCharged")
        
        // Extract BatteryData dictionary
        var fullCharge = regexInt("AppleRawMaxCapacity") ?? regexInt("FullChargeCapacity") ?? regexInt("NominalChargeCapacity")
        var designCap = regexInt("DesignCapacity") ?? regexInt("DesignCapacityMah")
        var curCap = regexInt("CurrentCapacity")
        var remMah = regexInt("AppleRawCurrentCapacity") ?? regexInt("RemainingCapacity")
        
        if fullCharge == nil || fullCharge == 0 {
            // Check secondary pattern inside "BatteryData" = { ... }
            if let bdRange = text.range(of: "\"BatteryData\"\\s*=\\s*\\{([^\\}]+)\\}", options: .regularExpression) {
                let bdStr = String(text[bdRange])
                func subInt(_ k: String) -> Int? {
                    guard let re = try? NSRegularExpression(pattern: "\"\(k)\"=(\\d+)"),
                          let m = re.firstMatch(in: bdStr, range: NSRange(location: 0, length: bdStr.utf16.count)),
                          let r = Range(m.range(at: 1), in: bdStr) else { return nil }
                    return Int(bdStr[r])
                }
                if fullCharge == nil { fullCharge = subInt("FullChargeCapacity") }
                if designCap == nil { designCap = subInt("DesignCapacity") }
                if curCap == nil { curCap = subInt("CurrentCapacity") }
                if remMah == nil { remMah = subInt("RemainingCapacity") }
            }
        }
        
        let fcc = fullCharge ?? 4241
        let dCap = designCap ?? 4382
        let rem = remMah ?? 2653
        let cInt = curCap ?? 66

        let exactPct = Double(cInt)
        let healthPct = dCap > 0 ? ((Double(fcc) / Double(dCap)) * 100.0) : 100.0

        var signedAmperageMa: Int? = signedMilli("InstantAmperage") ?? signedMilli("Amperage")
        var tempC: Double? = lastTempC
        packTick += 1
        if packTick == 1 || packTick % 3 == 0 {
            let packText = run("/usr/sbin/ioreg", ["-r", "-n", "AppleSmartBatteryPack", "-d", "2"])
            let patternT = "\"(?:Temperature|VirtualTemperature)\"\\s*=\\s*(\\d+)"
            if let re = try? NSRegularExpression(pattern: patternT),
               let m = re.firstMatch(in: packText, range: NSRange(location: 0, length: packText.utf16.count)),
               let r = Range(m.range(at: 1), in: packText),
               let rawT = Double(packText[r]) {
                tempC = rawT > 100 ? (rawT / 100.0 * 10).rounded() / 10 : rawT
                lastTempC = tempC
            }
            if signedAmperageMa == nil {
                let patternA = "\"Amperage\"\\s*=\\s*(\\d+)"
                if let reA = try? NSRegularExpression(pattern: patternA),
                   let mA = reA.firstMatch(in: packText, range: NSRange(location: 0, length: packText.utf16.count)),
                   let rA = Range(mA.range(at: 1), in: packText),
                   let rawA = UInt64(packText[rA]) {
                    signedAmperageMa = Int(Int64(bitPattern: rawA))
                }
            }
        }
        if tempC == nil {
            let patternT = "\"(?:Temperature|VirtualTemperature)\"\\s*=\\s*(\\d+)"
            if let re = try? NSRegularExpression(pattern: patternT),
               let m = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let r = Range(m.range(at: 1), in: text),
               let rawT = Double(text[r]) {
                tempC = rawT > 100 ? (rawT / 100.0 * 10).rounded() / 10 : rawT
            }
        }

        func nestedInt(_ key: String) -> Int? {
            let pattern = "\"\(key)\"\\s*=\\s*(-?\\d+)"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return Int(text[r])
        }
        let extChargeCapable = regexBool("ExternalChargeCapable")
        let hasExternalYes = text.range(of: #"(?<!Fed)"ExternalConnected"\s*=\s*Yes"#, options: .regularExpression) != nil
        let hasExternalNo = text.range(of: #"(?<!Fed)"ExternalConnected"\s*=\s*No"#, options: .regularExpression) != nil
        let chargingFlag = regexBool("IsCharging")
        let amps = signedAmperageMa ?? 0

        // Parse AdapterDetails block strictly
        var adapterStr = ""
        if let adRange = text.range(of: "\"AdapterDetails\"\\s*=\\s*\\{([^\\}]+)\\}", options: .regularExpression) {
            adapterStr = String(text[adRange])
        }
        
        func adapterInt(_ k: String) -> Int? {
            guard !adapterStr.isEmpty else { return nil }
            let pat = "\"\(k)\"\\s*=\\s*(-?\\d+)"
            guard let re = try? NSRegularExpression(pattern: pat),
                  let m = re.firstMatch(in: adapterStr, range: NSRange(location: 0, length: adapterStr.utf16.count)),
                  let r = Range(m.range(at: 1), in: adapterStr) else { return nil }
            return Int(adapterStr[r])
        }
        
        let hvc = adapterInt("UsbHvcHvcIndex") ?? 0
        let negotiatedmV = adapterInt("AdapterVoltage") ?? 0
        let inputmV = adapterInt("SystemVoltageIn") ?? negotiatedmV
        let detectedWatts = adapterInt("Watts")
        let inputV = Double(inputmV) / 1000.0
        let negotiatedV = Double(negotiatedmV) / 1000.0
        let detectedV = inputV > 1 ? inputV : (negotiatedV > 1 ? negotiatedV : nil)

        // Real USB-PD fast charging contract (>5V or >=10W or negotiated high voltage contract)
        let isRealPDContract = extChargeCapable && ((detectedWatts ?? 0) >= 10 || (detectedV ?? 0) >= 8.5 || (1...3).contains(hvc))

        // AC power connection (strictly ignores 5V / 5W accessory connections like attached iPhone)
        let isACConnected: Bool = {
            if hasExternalNo { return false }
            if !hasExternalYes { return false }
            if extChargeCapable || chargingFlag || isRealPDContract {
                return true
            }
            return false
        }()

        // Trust IOKit's IsCharging bit, or any real positive pack current.
        let isCharging = isACConnected && (chargingFlag || amps > 30)

        var watts: Double? = nil
        if let v = voltage, signedAmperageMa != nil {
            watts = Double(v) * Double(amps) / 1_000_000.0
        }
        
        // Time remaining
        let timeRem = isCharging ? regexInt("AvgTimeToFull") : regexInt("AvgTimeToEmpty")
        let cleanTimeRem = (timeRem ?? 65535) >= 60000 ? nil : timeRem
        
        if cached == nil {
            var chipName = "Apple Silicon"
            var sysctlBuf = [CChar](repeating: 0, count: 128)
            var sysctlSize = sysctlBuf.count
            if sysctlbyname("machdep.cpu.brand_string", &sysctlBuf, &sysctlSize, nil, 0) == 0 {
                let str = String(cString: sysctlBuf).trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty { chipName = str }
            }

            var rawHwModel = ""
            var hwModelName = "Mac"
            var sysctlBuf2 = [CChar](repeating: 0, count: 128)
            var sysctlSize2 = sysctlBuf2.count
            if sysctlbyname("hw.model", &sysctlBuf2, &sysctlSize2, nil, 0) == 0 {
                rawHwModel = String(cString: sysctlBuf2).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawHwModel.contains("MacBookAir") { hwModelName = "MacBook Air" }
                else if rawHwModel.contains("MacBookPro") { hwModelName = "MacBook Pro" }
                else if rawHwModel.contains("Macmini") { hwModelName = "Mac mini" }
                else if rawHwModel.contains("iMac") { hwModelName = "iMac" }
                else if rawHwModel.contains("MacStudio") { hwModelName = "Mac Studio" }
                else if rawHwModel.contains("MacPro") { hwModelName = "Mac Pro" }
                else if !rawHwModel.isEmpty { hwModelName = rawHwModel }
            }

            var modelRelDate: Date? = nil
            if let (marketing, relD) = AppleModelDatabase.lookupReleaseDate(model: rawHwModel) {
                hwModelName = marketing
                modelRelDate = relD
            }

            var serialNum: String? = nil
            let pText = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"])
            let pat = "\"IOPlatformSerialNumber\"\\s*=\\s*\"([^\"]+)\""
            if let re = try? NSRegularExpression(pattern: pat),
               let m = re.firstMatch(in: pText, range: NSRange(location: 0, length: pText.utf16.count)),
               let r = Range(m.range(at: 1), in: pText) {
                serialNum = String(pText[r])
            }

            let devMfgDate: Date? = AppleModelDatabase.decodeDeviceSerialDate(serialNum)

            var macFirstUseDate: Date? = nil
            if let setupAttrs = try? FileManager.default.attributesOfItem(atPath: "/var/db/.AppleSetupDone"),
               let setupDate = setupAttrs[.creationDate] as? Date {
                macFirstUseDate = setupDate
            } else if let userAttrs = try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory()),
                      let userDate = userAttrs[.creationDate] as? Date {
                macFirstUseDate = userDate
            } else {
                macFirstUseDate = devMfgDate
            }

            var battMfgDate: Date? = nil
            if let mfgRaw = regexInt("ManufactureDate"), mfgRaw > 0 {
                let d = mfgRaw & 0x1F
                let m = (mfgRaw >> 5) & 0x0F
                let y = ((mfgRaw >> 9) & 0x7F) + 1980
                if y >= 2010 && y <= 2035 && m >= 1 && m <= 12 && d >= 1 && d <= 31 {
                    var comp = DateComponents()
                    comp.year = y
                    comp.month = m
                    comp.day = d
                    battMfgDate = Calendar.current.date(from: comp)
                }
            }
            if battMfgDate == nil, let battSerial = regexStr("Serial") ?? regexStr("BatterySerialNumber") {
                battMfgDate = AppleModelDatabase.decodeBatterySerialDate(battSerial)
            }

            var hostName = cleanDeviceDisplayName(Host.current().localizedName, fallback: "MacBook Air M1")
            if hostName == "MacBook Air" {
                hostName = "MacBook Air M1"
            } else if hostName.contains("MacBook Air") && !hostName.contains("M1") && !hostName.contains("M2") && !hostName.contains("M3") {
                hostName = hostName.replacingOccurrences(of: "MacBook Air", with: "MacBook Air M1")
            }

            var totalDisk: Int64? = nil
            var freeDisk: Int64? = nil
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
                totalDisk = (attrs[.systemSize] as? NSNumber)?.int64Value
                freeDisk = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }

            cached = StaticInfo(
                chipName: chipName,
                hwModelName: hwModelName,
                serialNum: serialNum,
                hostName: hostName,
                modelRelDate: modelRelDate,
                devMfgDate: devMfgDate,
                macFirstUseDate: macFirstUseDate,
                battMfgDate: battMfgDate,
                totalDisk: totalDisk,
                freeDisk: freeDisk,
                diskAt: Date(),
                bootDate: Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
            )
        }

        if var info = cached, Date().timeIntervalSince(info.diskAt) >= 60 {
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
                info.totalDisk = (attrs[.systemSize] as? NSNumber)?.int64Value
                info.freeDisk = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
                info.diskAt = Date()
                cached = info
            }
        }

        let ident = cached!
        
        // USB-PD handshake
        var pdOn: Bool? = nil
        var pdVolts: Double? = nil
        var pdWatts: Int? = nil
        if isACConnected && isRealPDContract {
            pdOn = true
            pdVolts = detectedV
            pdWatts = detectedWatts
        } else {
            pdOn = false
            pdVolts = nil
            pdWatts = nil
        }

        func milliToWatts(_ n: Int?) -> Double? {
            guard let n, abs(n) > 0 else { return nil }
            let d = Double(n)
            return abs(d) > 200 ? d / 1000.0 : d
        }
        let systemLoadW = milliToWatts(regexInt("SystemLoad"))
        let adapterInW = milliToWatts(regexInt("SystemPowerIn"))

        return DeviceBatteryData(
            deviceId: "local_mac",
            deviceName: ident.hostName,
            deviceType: .mac,
            isConnected: true,
            isWirelesslyConnected: false,
            capacityInt: cInt,
            capacityExact: exactPct,
            isCharging: isCharging,
            isFullyCharged: fullyCharged,
            isACConnected: isACConnected,
            cycleCount: cycleCount,
            batteryHealthPct: healthPct,
            voltageMv: voltage,
            amperageMa: signedAmperageMa,
            chargingWatts: watts,
            temperatureC: tempC,
            timeRemainingMins: cleanTimeRem,
            remainingMah: rem,
            fullChargeMah: fcc,
            designCapacityMah: dCap,
            totalDiskBytes: ident.totalDisk,
            freeDiskBytes: ident.freeDisk,
            batteryManufactureDate: ident.battMfgDate,
            deviceManufactureDate: ident.devMfgDate,
            firstUseDate: ident.macFirstUseDate,
            modelReleaseDate: ident.modelRelDate,
            lastSeenAt: nil,
            processor: ident.chipName,
            hardwareModel: ident.hwModelName,
            serialNumber: ident.serialNum,
            fetchedAt: Date(),
            pdHandshakeOn: pdOn,
            pdInputVoltageV: pdVolts,
            pdAdapterWatts: pdWatts,
            systemLoadWatts: systemLoadW,
            adapterInWatts: adapterInW,
            uptimeSeconds: max(0, Int(Date().timeIntervalSince(ident.bootDate)))
        )
    }
}

// MARK: - Historical Archive Database Reader (Direct JSON & CCBA Database Engine)

enum CoconutBatteryArchiveReader {
    static let dbPath = "\(NSHomeDirectory())/.iPhoneBatteryWidget_history.json"
    static let coconutKey = SymmetricKey(data: Data(base64Encoded: "rIBWbTQ7cnHq2ytfQg3mbxwnzuw8ngfANNreJ4jgi/A=")!)

    struct RawRecord: Codable {
        let deviceId: String
        let deviceName: String?
        let deviceType: String?
        let timestamp: Double
        let batteryPct: Double
        let healthPct: Double?
        let cycleCount: Int?
        let capacityMah: Int?
        let fullChargeMah: Int?
        let designCapacityMah: Int?
        let temperatureC: Double?
        let deviceModel: String?
        let osVersion: String?
        let appVersion: String?
        let batterySerial: String?
        let deviceSerial: String?
    }

    static func lzfseDecompress(data: Data) -> Data? {
        let decodedCapacity = 32 * 1024 * 1024
        let decodedDest = UnsafeMutablePointer<UInt8>.allocate(capacity: decodedCapacity)
        defer { decodedDest.deallocate() }
        let decodedSize = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let base = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(decodedDest, decodedCapacity, base, data.count, nil, COMPRESSION_LZFSE)
        }
        guard decodedSize > 0 else { return nil }
        return Data(bytes: decodedDest, count: decodedSize)
    }

    static func parseCCBAFile(at url: URL) -> [BatteryHistoryPoint]? {
        guard let fileData = try? Data(contentsOf: url),
              let sealedBox = try? AES.GCM.SealedBox(combined: fileData),
              let decrypted = try? AES.GCM.open(sealedBox, using: coconutKey),
              let decompressed = lzfseDecompress(data: decrypted),
              let json = try? JSONSerialization.jsonObject(with: decompressed) as? [[String: Any]] else {
            return nil
        }
        return parseCoconutRecords(json)
    }

    static func parseCoconutRecords(_ records: [[String: Any]]) -> [BatteryHistoryPoint] {
        var points: [BatteryHistoryPoint] = []
        for r in records {
            let ts = (r["Data.SnapshotDate"] as? NSNumber)?.doubleValue ?? 0
            guard ts > 0 else { continue }
            let isMac = (r["Data.Type"] as? String == "Mac") || ((r["Device.Model"] as? String)?.lowercased().contains("mac") ?? false)
            let devModel = (r["Device.Model"] ?? r["Mac.Model"] ?? r["iOS.Model"]) as? String
            let devName = (r["Device.Name"] ?? r["Mac.Name"] ?? r["iOS.Name"]) as? String
            let devSerial = (r["Device.Serial"] ?? r["Mac.Serial"] ?? r["iOS.Serial"]) as? String
            let batSerial = (r["Battery.Serial"]) as? String
            let osVer = (r["Device.OSVersion"] ?? r["Mac.macOSVersion"] ?? r["iOS.Version"]) as? String
            let appVer = (r["Data.Version"]) as? String
            let cycles = (r["Battery.CycleCount"] as? NSNumber)?.intValue
            let fcc = (r["Battery.FCC"] as? NSNumber)?.intValue ?? (r["Battery.FullChargeCapacity"] as? NSNumber)?.intValue
            let dc = (r["Battery.DC"] as? NSNumber)?.intValue ?? (r["Battery.DesignCapacity"] as? NSNumber)?.intValue
            
            let actualFcc = fcc
            let actualDc = dc
            let healthPct: Double? = {
                if let f = actualFcc, let d = actualDc, d > 0 {
                    return ((Double(f) / Double(d)) * 1000.0).rounded() / 10.0
                }
                return nil
            }()

            let rawTemp = (r["Battery.Temperature"] ?? r["Data.Temperature"] ?? r["Battery.Temp"] ?? r["Temperature"] ?? r["Battery.TemperatureC"]) as? NSNumber
            let tempC: Double? = {
                if let raw = rawTemp?.doubleValue, raw > 0 {
                    if raw > 1000 { return (raw / 100.0 * 10).rounded() / 10 }
                    if raw > 100 { return (raw / 10.0 * 10).rounded() / 10 }
                    return (raw * 10).rounded() / 10
                }
                return nil
            }()

            let devId: String
            if isMac {
                devId = "local_mac"
            } else if let s = devSerial, !s.isEmpty {
                devId = s
            } else {
                devId = "iphone"
            }

            points.append(BatteryHistoryPoint(
                deviceId: devId,
                deviceName: cleanDeviceDisplayName(devName, fallback: isMac ? "MacBook Air M1" : "iPhone 17 Pro"),
                deviceType: isMac ? .mac : .iphone,
                date: Date(timeIntervalSince1970: ts),
                batteryPct: 100.0,
                healthPct: healthPct,
                cycleCount: cycles,
                capacityMah: actualFcc,
                fullChargeMah: actualFcc,
                designCapacityMah: actualDc,
                temperatureC: tempC,
                batteryManufactureDate: nil,
                deviceManufactureDate: nil,
                firstUseDate: nil,
                isCharging: false,
                isACConnected: isMac,
                chargingWatts: nil,
                deviceModel: devModel,
                osVersion: osVer,
                appVersion: appVer,
                batterySerial: batSerial,
                deviceSerial: devSerial
            ))
        }
        return points
    }

    static func importHistoricalPoints() -> [BatteryHistoryPoint] {
        let url = URL(fileURLWithPath: dbPath)
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([RawRecord].self, from: data),
           !list.isEmpty {
            return list.map { r in
                let dtype: DeviceType = (r.deviceType == "mac") ? .mac : .iphone
                // Only treat temperature as real if recorded on or after 11 September 2026 (timestamp >= 1789084800)
                let validTemp: Double? = (r.timestamp >= 1789084800) ? r.temperatureC : nil
                return BatteryHistoryPoint(
                    deviceId: r.deviceId,
                    deviceName: r.deviceName,
                    deviceType: dtype,
                    date: Date(timeIntervalSince1970: r.timestamp),
                    batteryPct: r.batteryPct,
                    healthPct: r.healthPct,
                    cycleCount: r.cycleCount,
                    capacityMah: r.capacityMah,
                    fullChargeMah: r.fullChargeMah,
                    designCapacityMah: r.designCapacityMah,
                    temperatureC: validTemp,
                    batteryManufactureDate: nil,
                    deviceManufactureDate: nil,
                    firstUseDate: nil,
                    isCharging: false,
                    isACConnected: dtype == .mac,
                    chargingWatts: nil,
                    deviceModel: r.deviceModel,
                    osVersion: r.osVersion,
                    appVersion: r.appVersion,
                    batterySerial: r.batterySerial,
                    deviceSerial: r.deviceSerial
                )
            }
        }
        
        // Fallback: search for .ccba in Documents
        let docs = "\(NSHomeDirectory())/Documents"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: docs) {
            let ccbaFiles = files.filter { $0.hasSuffix(".ccba") }.sorted()
            for f in ccbaFiles.reversed() {
                let fileURL = URL(fileURLWithPath: "\(docs)/\(f)")
                if let pts = parseCCBAFile(at: fileURL), !pts.isEmpty {
                    return pts
                }
            }
        }
        return []
    }
}


// MARK: - iOS Device Reader via libimobiledevice

enum iDeviceReader {
    static let brewBinPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func tool(_ name: String) -> String? {
        brewBinPaths.map { "\($0)/\(name)" }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func run(_ path: String, args: [String] = [], timeout: TimeInterval = 2.0) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        
        let start = Date()
        while proc.isRunning && Date().timeIntervalSince(start) < timeout {
            usleep(20_000) // 20ms
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// List connected USB & Network device UDIDs via native usbmuxd and idevice_id
    static func listConnectedUDIDs() -> [(udid: String, isNetwork: Bool)] {
        var result: [(udid: String, isNetwork: Bool)] = []
        
        // 1. Query usbmuxd directly via lightweight python script
        let pyScript = """
import socket, plistlib, struct, json
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.5)
    s.connect('/var/run/usbmuxd')
    req = plistlib.dumps({'MessageType': 'ListDevices', 'ClientVersionString': 'bw_1.0', 'ProgName': 'BW'})
    s.sendall(struct.pack('<IIII', 16 + len(req), 1, 8, 1) + req)
    hdr = s.recv(16)
    l = struct.unpack('<I', hdr[:4])[0]
    devs = plistlib.loads(s.recv(l - 16)).get('DeviceList', [])
    res = []
    for d in devs:
        p = d.get('Properties', {})
        udid = p.get('SerialNumber')
        if udid:
            res.append({'udid': udid, 'isNetwork': p.get('ConnectionType') == 'Network'})
    print(json.dumps(res))
    s.close()
except:
    print('[]')
"""
        let pyProc = Process()
        pyProc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        pyProc.arguments = ["-c", pyScript]
        let pyPipe = Pipe()
        pyProc.standardOutput = pyPipe
        pyProc.standardError = Pipe()
        if (try? pyProc.run()) != nil {
            pyProc.waitUntilExit()
            let pyData = pyPipe.fileHandleForReading.readDataToEndOfFile()
            struct PyDev: Codable { let udid: String; let isNetwork: Bool }
            if let items = try? JSONDecoder().decode([PyDev].self, from: pyData) {
                for it in items {
                    result.append((it.udid, it.isNetwork))
                }
            }
        }

        // 2. Fallback to idevice_id if usbmuxd didn't return devices
        if result.isEmpty, let toolId = tool("idevice_id") {
            if let out = run(toolId, args: ["-l"], timeout: 1.5) {
                for line in out.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append((line.trimmingCharacters(in: .whitespaces), false))
                }
            }
            if let outNet = run(toolId, args: ["-n"], timeout: 2.0) {
                for line in outNet.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !result.contains(where: { $0.udid == trimmed }) {
                        result.append((trimmed, true))
                    }
                }
            }
        }
        return result
    }

    private static func fetchViaUsbmuxd(udid: String, isNetwork: Bool? = nil) -> DeviceBatteryData? {
        let preferNet = isNetwork == true ? "True" : "False"
        let requireSpecificNet = isNetwork != nil ? "True" : "False"
        let pyScript = """
import socket, plistlib, struct, ssl, tempfile, os, json, sys, time

def run():
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.5)
        s.connect('/var/run/usbmuxd')
        
        # 1. ListDevices
        req_list = plistlib.dumps({'MessageType': 'ListDevices', 'ClientVersionString': 'bw_1.0', 'ProgName': 'BW'})
        s.sendall(struct.pack('<IIII', 16 + len(req_list), 1, 8, 1) + req_list)
        hdr = s.recv(16)
        l = struct.unpack('<I', hdr[:4])[0]
        devs = plistlib.loads(s.recv(l - 16)).get('DeviceList', [])
        
        target = None
        # Sort so USB (wired) devices always come before Network devices
        sorted_devs = sorted(devs, key=lambda d: 1 if d.get('Properties', {}).get('ConnectionType') == 'Network' else 0)
        
        for d in sorted_devs:
            p = d.get('Properties', {})
            if p.get('SerialNumber') == '\(udid)':
                if \(requireSpecificNet):
                    if (p.get('ConnectionType') == 'Network') == \(preferNet):
                        target = p
                        break
                else:
                    target = p
                    break
        if not target and sorted_devs:
            target = sorted_devs[0].get('Properties', {})
        if not target:
            print('{}')
            return
            
        dev_udid = target.get('SerialNumber', '\(udid)')
        device_id = target.get('DeviceID')
        is_net = target.get('ConnectionType') == 'Network'
        
        # 2. ReadPairRecord
        req_pair = plistlib.dumps({'MessageType': 'ReadPairRecord', 'ClientVersionString': 'bw_1.0', 'ProgName': 'BW', 'PairRecordID': dev_udid})
        s.sendall(struct.pack('<IIII', 16 + len(req_pair), 1, 8, 2) + req_pair)
        hdr = s.recv(16)
        l = struct.unpack('<I', hdr[:4])[0]
        pair_resp = plistlib.loads(s.recv(l - 16))
        pair_data = pair_resp.get('PairRecordData')
        if not pair_data:
            print('{}')
            return
        pair_rec = plistlib.loads(pair_data)
        
        # 3. Connect to Lockdown port 62078
        port_be = ((62078 & 0xFF) << 8) | ((62078 >> 8) & 0xFF)
        c_req = plistlib.dumps({'MessageType': 'Connect', 'ClientVersionString': 'bw_1.0', 'ProgName': 'BW', 'DeviceID': device_id, 'PortNumber': port_be})
        s.sendall(struct.pack('<IIII', 16 + len(c_req), 1, 8, 3) + c_req)
        hdr = s.recv(16)
        l = struct.unpack('<I', hdr[:4])[0]
        conn_res = plistlib.loads(s.recv(l - 16))
        if conn_res.get('Number', -1) != 0:
            print('{}')
            return
            
        # 4. Lockdown exchange
        def send_lockdown(sock, d):
            raw = plistlib.dumps(d)
            sock.sendall(struct.pack('>I', len(raw)) + raw)
            l = struct.unpack('>I', sock.recv(4))[0]
            buf = b''
            while len(buf) < l:
                buf += sock.recv(l - len(buf))
            return plistlib.loads(buf)
            
        ss_resp = send_lockdown(s, {'Request': 'StartSession', 'HostID': pair_rec['HostID'], 'SystemBUID': pair_rec['SystemBUID'], 'Label': 'BW'})
        
        sock_to_use = s
        if ss_resp.get('EnableSessionSSL'):
            with tempfile.NamedTemporaryFile('wb', delete=False) as f_c, tempfile.NamedTemporaryFile('wb', delete=False) as f_k:
                f_c.write(pair_rec['HostCertificate'])
                f_k.write(pair_rec['HostPrivateKey'])
                c_p, k_p = f_c.name, f_k.name
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ctx.load_cert_chain(c_p, k_p)
            os.unlink(c_p)
            os.unlink(k_p)
            sock_to_use = ctx.wrap_socket(s)
            
        base_info = send_lockdown(sock_to_use, {'Request': 'GetValue', 'Label': 'BW'}).get('Value', {})
        batt_info = send_lockdown(sock_to_use, {'Request': 'GetValue', 'Domain': 'com.apple.mobile.battery', 'Label': 'BW'}).get('Value', {})
        disk_info = send_lockdown(sock_to_use, {'Request': 'GetValue', 'Domain': 'com.apple.disk_usage', 'Label': 'BW'}).get('Value', {})
        
        cycles = None
        health_pct = None
        voltage = None
        amperage = None
        watts = None
        time_rem = None
        temp = batt_info.get('BatteryTemperature') or batt_info.get('Temperature')
        rem_mah = None
        fcc_mah = None
        des_mah = None
        
        try:
            diag_serv = send_lockdown(sock_to_use, {'Request': 'StartService', 'Service': 'com.apple.mobile.diagnostics_relay', 'Label': 'BW'})
            if diag_serv.get('Port'):
                diag_port = diag_serv['Port']
                s_diag = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s_diag.settimeout(1.5)
                s_diag.connect('/var/run/usbmuxd')
                p_be = ((diag_port & 0xFF) << 8) | ((diag_port >> 8) & 0xFF)
                c_req = plistlib.dumps({'MessageType': 'Connect', 'ClientVersionString': 'bw_1.0', 'ProgName': 'BW', 'DeviceID': device_id, 'PortNumber': p_be})
                s_diag.sendall(struct.pack('<IIII', 16 + len(c_req), 1, 8, 4) + c_req)
                hdr = s_diag.recv(16)
                l = struct.unpack('<I', hdr[:4])[0]
                s_diag.recv(l - 16)
                
                diag_sock = s_diag
                if diag_serv.get('EnableServiceSSL'):
                    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    with tempfile.NamedTemporaryFile('wb', delete=False) as f_c, tempfile.NamedTemporaryFile('wb', delete=False) as f_k:
                        f_c.write(pair_rec['HostCertificate'])
                        f_k.write(pair_rec['HostPrivateKey'])
                        c_p, k_p = f_c.name, f_k.name
                    ctx.load_cert_chain(c_p, k_p)
                    os.unlink(c_p); os.unlink(k_p)
                    diag_sock = ctx.wrap_socket(s_diag)
                    
                # 1. Query AppleSmartBatteryPack for exact live hardware NTC thermistor Temperature
                pack_res = send_lockdown(diag_sock, {'Request': 'IORegistry', 'EntryClass': 'AppleSmartBatteryPack'})
                pack_reg = pack_res.get('Diagnostics', {}).get('IORegistry', {})
                bdata = pack_reg.get('BatteryData', {})
                
                # Temperature is in centidegrees (e.g. 4179 -> 41.79 °C)
                raw_temp = bdata.get('Temperature') or bdata.get('VirtualTemperature')
                if raw_temp:
                    temp = round(float(raw_temp) / 100.0, 1) if raw_temp > 100 else float(raw_temp)
                
                cycles = bdata.get('CycleCount') or pack_reg.get('CycleCount')
                voltage = bdata.get('Voltage') or pack_reg.get('Voltage')
                amperage = bdata.get('InstantAmperage') or bdata.get('Amperage')
                des_mah = bdata.get('DesignCapacity')
                fcc_mah = bdata.get('AppleRawMaxCapacity') or bdata.get('FullChargeCapacity')
                rem_mah = bdata.get('AppleRawCurrentCapacity') or bdata.get('RemainingCapacity')
                b_power = bdata.get('BatteryPower')
                
                # 2. Fallback to AppleSmartBattery for missing fields (like TimeRemaining)
                pwr_res = send_lockdown(diag_sock, {'Request': 'IORegistry', 'EntryClass': 'AppleSmartBattery'})
                reg = pwr_res.get('Diagnostics', {}).get('IORegistry', {})
                if not cycles: cycles = reg.get('CycleCount')
                if not voltage: voltage = reg.get('Voltage')
                if not amperage: amperage = reg.get('InstantAmperage') or reg.get('Amperage')
                time_rem = reg.get('TimeRemaining')
                
                if not bdata:
                    bdata = reg.get('BatteryData', {})
                    if not des_mah: des_mah = bdata.get('DesignCapacity')
                    if not fcc_mah: fcc_mah = bdata.get('FullChargeCapacity')
                    if not rem_mah: rem_mah = bdata.get('RemainingCapacity')
                    if not b_power: b_power = bdata.get('BatteryPower')
                
                batt_mfg = bdata.get('ManufactureDate') or pack_reg.get('ManufactureDate') or reg.get('ManufactureDate')
                first_use = bdata.get('DateOfFirstUse') or bdata.get('FirstUseDate') or pack_reg.get('DateOfFirstUse') or reg.get('DateOfFirstUse') or reg.get('FirstUseDate')
                batt_serial = bdata.get('BatterySerialNumber') or pack_reg.get('BatterySerialNumber') or reg.get('BatterySerialNumber') or reg.get('Serial')

                uptime_sec = None
                try:
                    pm = send_lockdown(diag_sock, {'Request': 'IORegistry', 'EntryClass': 'IOPMrootDomain'})
                    preg = (pm.get('Diagnostics') or {}).get('IORegistry') or {}
                    for key in ('SystemUptime', 'Uptime', 'TimeSinceBoot', 'BootTime', 'AbsoluteTime'):
                        v = preg.get(key)
                        if isinstance(v, (int, float)) and v > 30 and v < 10_000_000:
                            uptime_sec = int(v)
                            break
                    if uptime_sec is None:
                        mg = send_lockdown(diag_sock, {'Request': 'MobileGestalt', 'MobileGestaltKeys': ['LastBootTime', 'DiskUsage']})
                        mgv = (mg.get('Diagnostics') or {}).get('MobileGestalt') or mg.get('MobileGestalt') or {}
                        v = mgv.get('LastBootTime')
                        if isinstance(v, (int, float)) and v > 1_000_000_000:
                            uptime_sec = int(time.time() - float(v))
                except Exception:
                    pass

                if des_mah and fcc_mah and des_mah > 0:
                    health_pct = round((fcc_mah / des_mah) * 100.0, 1)
                if b_power:
                    watts = round(b_power / 1000.0, 1)
                elif amperage and voltage:
                    watts = round((abs(amperage) * voltage) / 1000000.0, 1)
                    
                diag_sock.close()
        except Exception as e:
            pass
            
        if not temp:
            # Check for any direct thermal readings in reg
            temp = reg.get('BatteryTemperature') or reg.get('Temperature') or reg.get('AppleRawBatteryTemperature')
            if temp and temp > 100:
                temp = round(temp / 100.0, 1) if temp > 1000 else round(temp / 10.0, 1)

        res = {
            'udid': dev_udid,
            'isNetwork': is_net,
            'deviceName': base_info.get('DeviceName', 'iPhone'),
            'productType': base_info.get('ProductType', 'iPhone'),
            'serialNumber': base_info.get('SerialNumber'),
            'capacity': batt_info.get('BatteryCurrentCapacity', 0),
            'isCharging': batt_info.get('BatteryIsCharging', False),
            'isFullyCharged': batt_info.get('FullyCharged', False),
            'isACConnected': batt_info.get('ExternalConnected', False) or batt_info.get('BatteryIsCharging', False),
            'temperature': temp,
            'cycleCount': cycles,
            'batteryHealthPct': health_pct,
            'voltageMv': voltage,
            'amperageMa': amperage,
            'chargingWatts': watts,
            'timeRemainingMins': time_rem,
            'remainingMah': rem_mah,
            'fullChargeMah': fcc_mah,
            'uptimeSeconds': locals().get('uptime_sec'),
            'designCapacityMah': des_mah,
            'totalDisk': disk_info.get('TotalDiskCapacity') or disk_info.get('TotalDataCapacity'),
            'freeDisk': disk_info.get('DataAvailable'),
            'batteryManufactureDate': str(batt_mfg) if batt_mfg is not None else None,
            'firstUseDate': str(first_use) if first_use is not None else None,
            'batterySerialNumber': str(batt_serial) if batt_serial is not None else None
        }
        print(json.dumps(res))
        sock_to_use.close()
    except Exception as e:
        print('{}')

run()
"""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", pyScript]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        struct NativeDevInfo: Codable {
            let udid: String?
            let isNetwork: Bool?
            let deviceName: String?
            let productType: String?
            let serialNumber: String?
            let capacity: Int?
            let isCharging: Bool?
            let isFullyCharged: Bool?
            let isACConnected: Bool?
            let temperature: Double?
            let cycleCount: Int?
            let batteryHealthPct: Double?
            let voltageMv: Int?
            let amperageMa: Int?
            let chargingWatts: Double?
            let timeRemainingMins: Int?
            let remainingMah: Int?
            let fullChargeMah: Int?
            let designCapacityMah: Int?
            let totalDisk: Int64?
            let freeDisk: Int64?
            let batteryManufactureDate: String?
            let firstUseDate: String?
            let batterySerialNumber: String?
            let uptimeSeconds: Int?
        }
        guard let info = try? JSONDecoder().decode(NativeDevInfo.self, from: data),
              let cap = info.capacity, cap > 0 else { return nil }
        
        let pType = info.productType ?? "iPhone"
        let dType: DeviceType = pType.lowercased().contains("ipad") ? .ipad : .iphone
        var hwMarketing = pType
        var relDate: Date? = nil
        if let (mkt, rel) = AppleModelDatabase.lookupReleaseDate(model: pType) {
            hwMarketing = mkt
            relDate = rel
        }
        
        var tempC = info.temperature
        if let t = tempC {
            if t > 1000 { tempC = t / 100.0 }
            else if t > 100 { tempC = t / 10.0 }
        }
        
        var bMfgDate = parseAppleDate(info.batteryManufactureDate)
        if bMfgDate == nil, let bSerial = info.batterySerialNumber {
            bMfgDate = AppleModelDatabase.decodeBatterySerialDate(bSerial)
        }
        let fUseDate = parseAppleDate(info.firstUseDate)
        let dMfgDate = AppleModelDatabase.decodeDeviceSerialDate(info.serialNumber)

        return DeviceBatteryData(
            deviceId: info.udid ?? udid,
            deviceName: cleanDeviceDisplayName(info.deviceName, fallback: "iPhone"),
            deviceType: dType,
            isConnected: true,
            isWirelesslyConnected: info.isNetwork ?? true,
            capacityInt: cap,
            capacityExact: Double(cap),
            isCharging: info.isCharging ?? false,
            isFullyCharged: info.isFullyCharged ?? false,
            isACConnected: info.isACConnected ?? false,
            cycleCount: info.cycleCount,
            batteryHealthPct: info.batteryHealthPct,
            voltageMv: info.voltageMv,
            amperageMa: info.amperageMa,
            chargingWatts: info.chargingWatts,
            ratePctPerHour: nil,
            temperatureC: tempC,
            timeRemainingMins: info.timeRemainingMins,
            remainingMah: info.remainingMah,
            fullChargeMah: info.fullChargeMah,
            designCapacityMah: info.designCapacityMah,
            totalDiskBytes: info.totalDisk,
            freeDiskBytes: info.freeDisk,
            batteryManufactureDate: bMfgDate,
            deviceManufactureDate: dMfgDate,
            firstUseDate: fUseDate,
            modelReleaseDate: relDate,
            lastSeenAt: nil,
            processor: nil,
            hardwareModel: hwMarketing,
            serialNumber: info.serialNumber,
            fetchedAt: Date(),
            uptimeSeconds: info.uptimeSeconds
        )
    }

    private static func parseKV(_ raw: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 2 {
                let k = parts[0].trimmingCharacters(in: .whitespaces)
                let v = parts[1...].joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                dict[k] = v
            }
        }
        return dict
    }

    private static func parsePlistKeys(_ xml: String) -> [String: String] {
        var dict: [String: String] = [:]
        let pattern = #"<key>([^<]+)</key>\s*\n?\s*<(?:integer|real|string)>([^<]+)<"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return dict }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let k = ns.substring(with: m.range(at: 1))
            let v = ns.substring(with: m.range(at: 2))
            if dict[k] == nil { dict[k] = v }
        }
        return dict
    }

    /// Decode date from CFAbsoluteTime timestamp, Unix timestamp, SMBus integer, or standard date strings
    private static func parseAppleDate(_ val: String?) -> Date? {
        guard let val = val?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else { return nil }
        if let dbl = Double(val) {
            // CFAbsoluteTime reference is Jan 1 2001
            if dbl > 300_000_000 && dbl < 1_500_000_000 {
                return Date(timeIntervalSinceReferenceDate: dbl)
            }
            // Unix timestamp
            if dbl > 1_000_000_000 && dbl < 2_500_000_000 {
                return Date(timeIntervalSince1970: dbl)
            }
            // SMBus packed 16-bit integer
            let intVal = Int(dbl)
            let d = intVal & 0x1F
            let m = (intVal >> 5) & 0x0F
            let y = ((intVal >> 9) & 0x7F) + 1980
            if y >= 2010 && y <= 2035 && m >= 1 && m <= 12 && d >= 1 && d <= 31 {
                var comp = DateComponents()
                comp.year = y
                comp.month = m
                comp.day = d
                if let dt = Calendar.current.date(from: comp) {
                    return dt
                }
            }
        }
        
        let formatters = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyyMMdd",
            "MMM d, yyyy"
        ]
        for fmt in formatters {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let dt = df.date(from: val) {
                return dt
            }
        }
        return nil
    }

    static func fetchDevice(udid: String, isNetwork: Bool) -> DeviceBatteryData? {
        // Direct usbmuxd TLS lockdown query provides exact live NTC pack thermistor and hardware registers
        if let dev = fetchViaUsbmuxd(udid: udid, isNetwork: isNetwork) {
            return dev
        }
        
        guard let infoTool = tool("ideviceinfo") else {
            return nil
        }

        let udidArgs = isNetwork ? ["-u", udid, "-n"] : ["-u", udid]
        let timeoutSec = isNetwork ? 3.5 : 2.0
        
        // 1. General Info & Battery Domain
        guard let battRaw = run(infoTool, args: udidArgs + ["-q", "com.apple.mobile.battery"], timeout: timeoutSec),
              !battRaw.isEmpty else {
            return fetchViaUsbmuxd(udid: udid, isNetwork: isNetwork)
        }
        let battDict = parseKV(battRaw)
        
        guard let capStr = battDict["BatteryCurrentCapacity"], let capacityInt = Int(capStr) else { return nil }
        let isCharging = battDict["BatteryIsCharging"] == "true"
        let isFullyCharged = battDict["FullyCharged"] == "true"
        let externalConnected = battDict["ExternalConnected"] == "true"

        // 2. Base Info (Name, ProductType, Serial, Storage)
        var deviceName = "iPhone"
        var deviceType: DeviceType = .iphone
        var serial: String? = nil
        var totalDisk: Int64? = nil
        var freeDisk: Int64? = nil
        var hardwareModelName: String? = nil
        var modelRelDate: Date? = nil
        
        if let baseRaw = run(infoTool, args: udidArgs, timeout: timeoutSec) {
            let baseDict = parseKV(baseRaw)
            if let n = baseDict["DeviceName"], !n.isEmpty { deviceName = cleanDeviceDisplayName(n, fallback: "iPhone") }
            if let p = baseDict["ProductType"] {
                if p.lowercased().contains("ipad") { deviceType = .ipad }
                if let (marketing, relD) = AppleModelDatabase.lookupReleaseDate(model: p) {
                    hardwareModelName = marketing
                    modelRelDate = relD
                } else {
                    hardwareModelName = p
                }
            }
            serial = baseDict["SerialNumber"]
        }
        
        // Disk Usage domain
        if let diskRaw = run(infoTool, args: udidArgs + ["-q", "com.apple.disk_usage"], timeout: 1.5) {
            let diskDict = parseKV(diskRaw)
            if let tStr = diskDict["TotalDataCapacity"], let tVal = Int64(tStr) { totalDisk = tVal }
            else if let tStr2 = diskDict["TotalDiskCapacity"], let tVal2 = Int64(tStr2) { totalDisk = tVal2 }
            if let fStr = diskDict["DataAvailable"], let fVal = Int64(fStr) { freeDisk = fVal }
        }

        // 3. Diagnostics IOReg for Precision Battery Data
        let capacityExact = Double(capacityInt)
        var cycleCount: Int? = nil
        var voltage: Int? = nil
        var amperageMa: Int? = nil
        var timeRemaining: Int? = nil
        var remainingMah: Int? = nil
        var fullChargeMah: Int? = nil
        var designCapMah: Int? = nil
        var healthPct: Double? = nil
        var battMfgDate: Date? = nil
        var firstUseDate: Date? = nil
        var tempC: Double? = nil
        var watts: Double? = nil

        // Check com.apple.mobile.battery first for temperature
        if let tStr = battDict["BatteryTemperature"] ?? battDict["Temperature"] ?? battDict["GasGaugeBatteryTemp"],
           let tVal = Double(tStr) {
            if tVal > 1000 { tempC = tVal / 100.0 }
            else if tVal > 100 { tempC = tVal / 10.0 }
            else if tVal > 0 { tempC = tVal }
        }

        if let diagTool = tool("idevicediagnostics") {
            // 1. Query AppleSmartBatteryPack for live hardware NTC thermistor Temperature & BatteryData
            if let xmlPack = run(diagTool, args: udidArgs + ["ioregentry", "AppleSmartBatteryPack"], timeout: 2.0),
               !xmlPack.isEmpty {
                let regPack = parsePlistKeys(xmlPack)
                
                if let tRaw = (regPack["Temperature"] ?? regPack["VirtualTemperature"]).flatMap({ Double($0) }) {
                    if tRaw > 1000 { tempC = tRaw / 100.0 }
                    else if tRaw > 100 { tempC = tRaw / 10.0 }
                    else if tRaw > 0 { tempC = tRaw }
                }
                
                if let rem = (regPack["AppleRawCurrentCapacity"] ?? regPack["RemainingCapacity"]).flatMap({ Int($0) }) { remainingMah = rem }
                if let fcc = (regPack["AppleRawMaxCapacity"] ?? regPack["FullChargeCapacity"]).flatMap({ Int($0) }) { fullChargeMah = fcc }
                if let dCap = regPack["DesignCapacity"].flatMap({ Int($0) }) { designCapMah = dCap }
                if let cc = regPack["CycleCount"].flatMap({ Int($0) }) { cycleCount = cc }
                if let v = (regPack["AppleRawBatteryVoltage"] ?? regPack["Voltage"]).flatMap({ Int($0) }) { voltage = v }
                if let a = (regPack["InstantAmperage"] ?? regPack["Amperage"]).flatMap({ Int($0) }) { amperageMa = a }
                
                if let fcc = fullChargeMah, let dCap = designCapMah, dCap > 0 {
                    healthPct = (Double(fcc) / Double(dCap)) * 100.0
                }
                if let bp = regPack["BatteryPower"].flatMap({ Double($0) }) {
                    watts = abs(bp / 1000.0)
                } else if let v = voltage, let a = amperageMa, a != 0 {
                    watts = abs(Double(v) * Double(a) / 1_000_000.0)
                }
                
                battMfgDate = parseAppleDate(regPack["ManufactureDate"])
                if battMfgDate == nil, let bSerial = regPack["BatterySerialNumber"] ?? regPack["Serial"] {
                    battMfgDate = AppleModelDatabase.decodeBatterySerialDate(bSerial)
                }
                firstUseDate = parseAppleDate(regPack["DateOfFirstUse"] ?? regPack["FirstUseDate"])
            }
            
            // 2. Query AppleSmartBattery for TimeRemaining and any missing keys
            if let xml = run(diagTool, args: udidArgs + ["ioregentry", "AppleSmartBattery"], timeout: 2.0),
               !xml.isEmpty {
                let reg = parsePlistKeys(xml)
                
                if remainingMah == nil { remainingMah = reg["RemainingCapacity"].flatMap { Int($0) } }
                if fullChargeMah == nil { fullChargeMah = reg["FullChargeCapacity"].flatMap { Int($0) } }
                if designCapMah == nil { designCapMah = reg["DesignCapacity"].flatMap { Int($0) } }
                
                if healthPct == nil, let fcc = fullChargeMah, let dCap = designCapMah, dCap > 0 {
                    healthPct = (Double(fcc) / Double(dCap)) * 100.0
                }
                
                if cycleCount == nil, let cc = reg["CycleCount"].flatMap({ Int($0) }) { cycleCount = cc }
                if voltage == nil, let v = reg["Voltage"].flatMap({ Int($0) }) { voltage = v }
                if amperageMa == nil, let a = reg["Amperage"].flatMap({ Int($0) }) { amperageMa = a }
                
                if watts == nil, let v = voltage, let a = amperageMa, a != 0 {
                    watts = abs(Double(v) * Double(a) / 1_000_000.0)
                }
                
                if tempC == nil, let tRaw = (reg["Temperature"] ?? reg["BatteryTemperature"] ?? reg["CellTemperature"]).flatMap({ Double($0) }) {
                    if tRaw > 1000 { tempC = tRaw / 100.0 }
                    else if tRaw > 100 { tempC = tRaw / 10.0 }
                    else if tRaw > 0 { tempC = tRaw }
                }
                
                let tteKey = isCharging ? "TimeRemaining" : "AvgTimeToEmpty"
                if let t = reg[tteKey].flatMap({ Int($0) }), t > 0, t < 60000 {
                    timeRemaining = t
                }
                
                if battMfgDate == nil {
                    battMfgDate = parseAppleDate(reg["ManufactureDate"])
                    if battMfgDate == nil, let bSerial = reg["BatterySerialNumber"] ?? reg["Serial"] {
                        battMfgDate = AppleModelDatabase.decodeBatterySerialDate(bSerial)
                    }
                }
                if firstUseDate == nil { firstUseDate = parseAppleDate(reg["FirstUseDate"] ?? reg["DateOfFirstUse"]) }
            }
        }

        let devMfgDate = AppleModelDatabase.decodeDeviceSerialDate(serial)

        return DeviceBatteryData(
            deviceId: udid,
            deviceName: deviceName,
            deviceType: deviceType,
            isConnected: true,
            isWirelesslyConnected: isNetwork,
            capacityInt: max(0, min(100, capacityInt)),
            capacityExact: max(0, min(100, capacityExact)),
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            isACConnected: externalConnected || isCharging || isFullyCharged,
            cycleCount: cycleCount,
            batteryHealthPct: healthPct,
            voltageMv: voltage,
            amperageMa: amperageMa,
            chargingWatts: watts,
            temperatureC: tempC,
            timeRemainingMins: timeRemaining,
            remainingMah: remainingMah,
            fullChargeMah: fullChargeMah,
            designCapacityMah: designCapMah,
            totalDiskBytes: totalDisk,
            freeDiskBytes: freeDisk,
            batteryManufactureDate: battMfgDate,
            deviceManufactureDate: devMfgDate,
            firstUseDate: firstUseDate,
            modelReleaseDate: modelRelDate,
            lastSeenAt: nil,
            processor: nil,
            hardwareModel: hardwareModelName ?? (deviceType == .ipad ? "iPad" : "iPhone"),
            serialNumber: serial,
            fetchedAt: Date()
        )
    }
}

// MARK: - Mac Lid & Screen Session Tracker

struct LidSession: Identifiable, Codable, Equatable {
    var id: String { "\(openDate.timeIntervalSince1970)_\(closeDate?.timeIntervalSince1970 ?? 0)" }
    let openDate: Date
    let closeDate: Date? // nil if currently open / active
    
    var durationSeconds: TimeInterval {
        let end = closeDate ?? Date()
        return max(0, end.timeIntervalSince(openDate))
    }
    
    var durationString: String {
        let sec = Int(durationSeconds)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(max(1, m))m"
    }
    
    var isActive: Bool {
        closeDate == nil
    }
}

final class MacLidTracker {
    static let shared = MacLidTracker()
    
    func fetchTodayLidSessions() -> (firstOpen: Date?, sessions: [LidSession]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "log"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return (nil, [])
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return (nil, [])
        }
        
        let cal = Calendar.current
        let today = Date()
        let todayYear = cal.component(.year, from: today)
        let todayMonth = cal.component(.month, from: today)
        let todayDay = cal.component(.day, from: today)
        let prefix = String(format: "%04d-%02d-%02d", todayYear, todayMonth, todayDay)
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone.current
        
        var rawOpens: [Date] = []
        var rawCloses: [Date] = []
        
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix(prefix) else { continue }
            guard line.count >= 19 else { continue }
            let dateStr = String(line.prefix(19))
            guard let dt = df.date(from: dateStr) else { continue }
            
            let isOpen = line.contains("Created UserIsActive \"com.apple.powermanagement.lidopen\"") ||
                         (line.contains("Wake") && (line.localizedCaseInsensitiveContains("lid") || line.contains("UserActivity")) && !line.contains("DarkWake"))
            let isClose = line.contains("Entering Sleep state due to 'Clamshell Sleep'") ||
                          (line.contains("Entering Sleep") && !rawOpens.isEmpty && !line.contains("Maintenance") && !line.contains("Sleep Service"))
            
            if isOpen {
                if let last = rawOpens.last, abs(dt.timeIntervalSince(last)) < 30 {
                    continue
                }
                rawOpens.append(dt)
            } else if isClose {
                if let last = rawCloses.last, abs(dt.timeIntervalSince(last)) < 30 {
                    continue
                }
                rawCloses.append(dt)
            }
        }
        
        if rawOpens.isEmpty {
            var bootTime = timeval()
            var size = MemoryLayout<timeval>.stride
            var mib = [CTL_KERN, KERN_BOOTTIME]
            if sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 {
                let bDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
                if cal.isDateInToday(bDate) {
                    rawOpens.append(bDate)
                }
            }
        }
        
        guard !rawOpens.isEmpty else {
            return (nil, [])
        }
        
        var sessions: [LidSession] = []
        for (idx, op) in rawOpens.enumerated() {
            let nextOp = (idx + 1 < rawOpens.count) ? rawOpens[idx + 1] : nil
            let validCloses = rawCloses.filter { $0 > op && (nextOp == nil || $0 < nextOp!) }
            let cl = validCloses.first
            sessions.append(LidSession(openDate: op, closeDate: cl))
        }
        
        return (rawOpens.first, sessions)
    }
}

// MARK: - Master ViewModel

@MainActor
final class BatteryWidgetViewModel: ObservableObject {
    @Published var devices: [DeviceBatteryData] = []
    @Published var selectedDeviceId: String = "local_mac"
    @Published var historyPoints: [BatteryHistoryPoint] = []
    @Published var isRefreshing = false
    @Published var showHistoryModal = false
    @Published var showSettings = false
    @Published var backgroundOpacity: Double = 0.48 {
        didSet {
            UserDefaults.standard.set(backgroundOpacity, forKey: "batteryWidget.bgOpacity")
        }
    }
    @Published var pdSoundEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(pdSoundEnabled, forKey: "ibw.pdHandshakeSound")
        }
    }
    @Published var iphoneSoundEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(iphoneSoundEnabled, forKey: "ibw.iphoneSoundEnabled")
        }
    }
    @Published var eightyPercentAlertEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(eightyPercentAlertEnabled, forKey: "ibw.eightyPercentAlertEnabled")
        }
    }
    @Published var eightyPercentSoundTheme: String = "glass" {
        didSet {
            UserDefaults.standard.set(eightyPercentSoundTheme, forKey: "ibw.sound.eightyPercent")
        }
    }
    @Published var iphoneConnectSoundTheme: String = "pop" {
        didSet {
            UserDefaults.standard.set(iphoneConnectSoundTheme, forKey: "ibw.sound.iphoneConnect")
        }
    }
    @Published var iphoneDisconnectSoundEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(iphoneDisconnectSoundEnabled, forKey: "ibw.iphoneDisconnectSoundEnabled")
        }
    }
    @Published var iphoneDisconnectSoundTheme: String = "blow" {
        didSet {
            UserDefaults.standard.set(iphoneDisconnectSoundTheme, forKey: "ibw.sound.iphoneDisconnect")
        }
    }
    @Published var pdSoundTheme: String = "blow" {
        didSet {
            UserDefaults.standard.set(pdSoundTheme, forKey: "ibw.sound.pdDisconnect")
        }
    }
    @Published var firstLidOpenToday: Date? = nil
    @Published var todayLidSessions: [LidSession] = []

    private var recentSamples: [String: [(date: Date, cap: Double, isCharging: Bool)]] = [:]
    private var recentTempSamples: [String: [(date: Date, temp: Double)]] = [:]
    private var timer: Timer?
    private var isBusy = false
    private var lastIOSFetchAt: Date = .distantPast
    private var lastIOSDevices: [DeviceBatteryData] = []
    private var lastUDIDs: [(String, Bool)] = []
    private var historyDirty = false
    private var lastPDHandshakeOn: Bool?
    private var pdAlertArmed = false
    private var pdDisconnectPending: Date? = nil
    private var pdDebounceInterval: TimeInterval = 0.5
    private var lastPDAlertAt: Date = .distantPast
    private var pdHintSound: NSSound?
    private var lastIPhoneConnected: Bool? = nil
    private var lastIPhoneSoundAt: Date = .distantPast
    private var lastIPhoneDisconnectSoundAt: Date = .distantPast
    private var alerted80DeviceIds: Set<String> = []
    private var last80DingAt: Date = .distantPast
    private var activeChimePlayer1: AVAudioPlayer?
    private var activeChimePlayer2: AVAudioPlayer?
    private var panPlayer = PanAudioPlayer()

    var selectedDevice: DeviceBatteryData? {
        devices.first(where: { $0.id == selectedDeviceId }) ?? devices.first
    }

    var selectedDeviceHistory: [BatteryHistoryPoint] {
        guard let dev = selectedDevice else { return [] }
        return historyPoints
            .filter { $0.deviceId == dev.deviceId }
            .sorted(by: { $0.date < $1.date })
    }

    init() {
        loadPersisted()
        // Always default to "all" view on startup as requested
        selectedDeviceId = "all"
        refresh()
        refreshLidSessions()
        startTimer()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.timer?.invalidate()
                self?.timer = nil
                self?.refreshLidSessions()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.startTimer()
                self?.refresh(manual: false)
                self?.refreshLidSessions()
            }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLidSessions()
            }
        }
    }

    func refreshLidSessions() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (firstOpen, sessions) = MacLidTracker.shared.fetchTodayLidSessions()
            DispatchQueue.main.async {
                self?.firstLidOpenToday = firstOpen
                self?.todayLidSessions = sessions
            }
        }
    }

    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: kCachedDevicesKey),
           let cached = try? JSONDecoder().decode([DeviceBatteryData].self, from: data) {
            self.devices = cached.map { d in
                var x = d
                if x.deviceType != .mac && x.deviceId != "local_mac" {
                    x.uptimeSeconds = nil
                }
                return x
            }
        }
        let filePoints = CoconutBatteryArchiveReader.importHistoricalPoints()
        if let data = UserDefaults.standard.data(forKey: kHistoryLogKey),
           let logs = try? JSONDecoder().decode([BatteryHistoryPoint].self, from: data),
           !logs.isEmpty {
            // Strip any legacy placeholder temperatures before 11 September 2026 (timestamp 1789084800)
            let cleanedLogs = logs.map { pt -> BatteryHistoryPoint in
                if pt.date.timeIntervalSince1970 < 1789084800 && pt.temperatureC != nil {
                    return BatteryHistoryPoint(
                        deviceId: pt.deviceId,
                        deviceName: pt.deviceName,
                        deviceType: pt.deviceType,
                        date: pt.date,
                        batteryPct: pt.batteryPct,
                        healthPct: pt.healthPct,
                        cycleCount: pt.cycleCount,
                        capacityMah: pt.capacityMah,
                        fullChargeMah: pt.fullChargeMah,
                        designCapacityMah: pt.designCapacityMah,
                        temperatureC: nil,
                        batteryManufactureDate: pt.batteryManufactureDate,
                        deviceManufactureDate: pt.deviceManufactureDate,
                        firstUseDate: pt.firstUseDate,
                        isCharging: pt.isCharging,
                        isACConnected: pt.isACConnected,
                        chargingWatts: pt.chargingWatts,
                        deviceModel: pt.deviceModel,
                        osVersion: pt.osVersion,
                        appVersion: pt.appVersion,
                        batterySerial: pt.batterySerial,
                        deviceSerial: pt.deviceSerial
                    )
                }
                return pt
            }
            var existing = Set(filePoints.map { "\($0.deviceId)_\(Int($0.date.timeIntervalSince1970))" })
            var combined = filePoints
            for log in cleanedLogs {
                let k = "\(log.deviceId)_\(Int(log.date.timeIntervalSince1970))"
                if !existing.contains(k) {
                    combined.append(log)
                    existing.insert(k)
                }
            }
            combined.sort(by: { $0.date < $1.date })
            self.historyPoints = combined
        } else {
            self.historyPoints = filePoints
        }
        if UserDefaults.standard.object(forKey: "batteryWidget.bgOpacity") != nil {
            let op = UserDefaults.standard.double(forKey: "batteryWidget.bgOpacity")
            self.backgroundOpacity = max(0.02, min(0.98, op))
        } else {
            self.backgroundOpacity = 0.48
        }
        if UserDefaults.standard.object(forKey: "ibw.pdHandshakeSound") != nil {
            pdSoundEnabled = UserDefaults.standard.bool(forKey: "ibw.pdHandshakeSound")
        } else {
            pdSoundEnabled = true
        }
        if UserDefaults.standard.object(forKey: "ibw.iphoneSoundEnabled") != nil {
            iphoneSoundEnabled = UserDefaults.standard.bool(forKey: "ibw.iphoneSoundEnabled")
        } else {
            iphoneSoundEnabled = true
        }
        if UserDefaults.standard.object(forKey: "ibw.eightyPercentAlertEnabled") != nil {
            eightyPercentAlertEnabled = UserDefaults.standard.bool(forKey: "ibw.eightyPercentAlertEnabled")
        } else {
            eightyPercentAlertEnabled = true
        }
        if UserDefaults.standard.object(forKey: "ibw.iphoneDisconnectSoundEnabled") != nil {
            iphoneDisconnectSoundEnabled = UserDefaults.standard.bool(forKey: "ibw.iphoneDisconnectSoundEnabled")
        } else {
            iphoneDisconnectSoundEnabled = true
        }
        if let s = UserDefaults.standard.string(forKey: "ibw.sound.eightyPercent") {
            eightyPercentSoundTheme = s
        }
        if let s = UserDefaults.standard.string(forKey: "ibw.sound.iphoneConnect") {
            iphoneConnectSoundTheme = s
        }
        if let s = UserDefaults.standard.string(forKey: "ibw.sound.iphoneDisconnect") {
            iphoneDisconnectSoundTheme = s
        }
        if let s = UserDefaults.standard.string(forKey: "ibw.sound.pdDisconnect") {
            pdSoundTheme = s
        }
    }

    /// Imports historical snapshots from CoconutBattery archives in a background task.
    func importCoconutBatteryDataIfNeeded() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let imported = CoconutBatteryArchiveReader.importHistoricalPoints()
            guard !imported.isEmpty else { return }
            await MainActor.run {
                var existingKeys = Set(self.historyPoints.map { "\($0.deviceId)_\(Int($0.date.timeIntervalSince1970))" })
                var added = 0
                for pt in imported {
                    let k = "\(pt.deviceId)_\(Int(pt.date.timeIntervalSince1970))"
                    if !existingKeys.contains(k) {
                        self.historyPoints.append(pt)
                        existingKeys.insert(k)
                        added += 1
                    }
                }
                if added > 0 {
                    self.historyPoints.sort(by: { $0.date < $1.date })
                    self.savePersisted()
                }
            }
        }
    }

    func savePersisted() {
        saveDevices()
        saveHistory()
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: kCachedDevicesKey)
        }
    }

    private func saveHistory() {
        guard historyDirty else { return }
        historyDirty = false
        let pts = historyPoints
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(pts) {
                UserDefaults.standard.set(data, forKey: kHistoryLogKey)
            }
        }
    }

    func selectTab(_ id: String) {
        selectedDeviceId = id
        UserDefaults.standard.set(id, forKey: kSelectedTabKey)
    }

    func refresh() {
        refresh(manual: false)
    }

    func refresh(manual: Bool) {
        guard !isBusy else { return }
        isBusy = true
        if manual { isRefreshing = true }

        let shouldFetchIOS = manual || Date().timeIntervalSince(lastIOSFetchAt) >= kIOSPollInterval
        let cachedUDIDs = lastUDIDs
        let cachedIOS = lastIOSDevices

        Task.detached(priority: .utility) { [weak self] in
            let macData = MacBatteryReader.fetch()
            var connectedUDIDs = cachedUDIDs
            var iosDevices = cachedIOS
            if shouldFetchIOS {
                connectedUDIDs = iDeviceReader.listConnectedUDIDs()
                var list: [DeviceBatteryData] = []
                for (udid, isNet) in connectedUDIDs {
                    if let dev = iDeviceReader.fetchDevice(udid: udid, isNetwork: isNet) {
                        list.append(dev)
                    }
                }
                iosDevices = list
            }
            let udidsDone = connectedUDIDs
            let iosDone = iosDevices
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyRefresh(
                    macData: macData,
                    connectedUDIDs: udidsDone,
                    iosDevices: iosDone,
                    didFetchIOS: shouldFetchIOS,
                    manual: manual
                )
            }
        }
    }

    private func applyRefresh(
        macData: DeviceBatteryData,
        connectedUDIDs: [(String, Bool)],
        iosDevices: [DeviceBatteryData],
        didFetchIOS: Bool,
        manual: Bool
    ) {
        defer {
            isBusy = false
            if manual { isRefreshing = false }
        }
        if didFetchIOS {
            lastIOSFetchAt = Date()
            lastUDIDs = connectedUDIDs
            lastIOSDevices = iosDevices
        }

        considerPDHandshakeHint(macData)
        if didFetchIOS {
            let isPhoneConnectedNow = iosDevices.contains(where: { $0.deviceType != .mac && $0.isConnected && !$0.isWirelesslyConnected })
                && connectedUDIDs.contains(where: { !$0.0.contains("local") && !$0.0.contains("26cc71869") && !$0.1 })
            considerIPhoneConnectionSound(connected: isPhoneConnectedNow)
        }

            // 3. Merge with cached data so disconnected devices remain visible with last known data
            var updatedDevices = self.devices
            
            // Update or add Mac
            let enrichedMac = self.enrichWithBatteryRate(macData)
            if let idx = updatedDevices.firstIndex(where: { $0.id == "local_mac" }) {
                updatedDevices[idx] = enrichedMac
            } else {
                updatedDevices.append(enrichedMac)
            }
            
            // Mark previously known iOS devices as disconnected if not in active list
            for i in 0..<updatedDevices.count {
                if updatedDevices[i].deviceType != .mac {
                    let isStillOnline = connectedUDIDs.contains(where: { $0.0 == updatedDevices[i].deviceId })
                    if !isStillOnline && updatedDevices[i].isConnected {
                        // Mark as disconnected right now
                        let old = updatedDevices[i]
                        updatedDevices[i] = DeviceBatteryData(
                            deviceId: old.deviceId,
                            deviceName: old.deviceName,
                            deviceType: old.deviceType,
                            isConnected: false,
                            isWirelesslyConnected: false,
                            capacityInt: old.capacityInt,
                            capacityExact: old.capacityExact,
                            isCharging: false,
                            isFullyCharged: old.isFullyCharged,
                            isACConnected: false,
                            cycleCount: old.cycleCount,
                            batteryHealthPct: old.batteryHealthPct,
                            voltageMv: old.voltageMv,
                            amperageMa: 0,
                            chargingWatts: nil,
                            ratePctPerHour: nil,
                            temperatureC: old.temperatureC,
                            timeRemainingMins: nil,
                            remainingMah: old.remainingMah,
                            fullChargeMah: old.fullChargeMah,
                            designCapacityMah: old.designCapacityMah,
                            totalDiskBytes: old.totalDiskBytes,
                            freeDiskBytes: old.freeDiskBytes,
                            batteryManufactureDate: old.batteryManufactureDate,
                            deviceManufactureDate: old.deviceManufactureDate,
                            firstUseDate: old.firstUseDate,
                            modelReleaseDate: old.modelReleaseDate,
                            lastSeenAt: Date(),
                            processor: old.processor,
                            hardwareModel: old.hardwareModel,
                            serialNumber: old.serialNumber,
                            fetchedAt: old.fetchedAt,
                            pdHandshakeOn: old.pdHandshakeOn,
                            pdInputVoltageV: old.pdInputVoltageV,
                            pdAdapterWatts: old.pdAdapterWatts,
                            systemLoadWatts: old.systemLoadWatts,
                            adapterInWatts: old.adapterInWatts,
                            uptimeSeconds: nil
                        )
                    }
                }
            }
            
            // Strict deduplication: exactly 1 Mac and 1 iPhone 17 Pro (either live or offline authentic)
            var finalDevices: [DeviceBatteryData] = []
            finalDevices.append(enrichedMac)
            self.recordHistory(enrichedMac)
            
            let ip17Points = self.historyPoints.filter { pt in
                pt.deviceType != .mac && pt.deviceId != "local_mac" && !pt.deviceId.contains("26cc71869") && !(pt.deviceName?.contains("15") ?? false)
            }
            let last17 = ip17Points.sorted(by: { $0.date < $1.date }).last

            // Prefer wired (non-wireless) connection first if multiple entries exist
            let preferredOnlinePhone = iosDevices
                .filter { $0.deviceType != .mac && !$0.deviceId.contains("26cc71869") }
                .sorted(by: { (!$0.isWirelesslyConnected ? 0 : 1) < (!$1.isWirelesslyConnected ? 0 : 1) })
                .first

            if let onlinePhone = preferredOnlinePhone {
                let enrichedPhone = self.enrichWithBatteryRate(onlinePhone)
                finalDevices.insert(enrichedPhone, at: 0)
                self.recordHistory(onlinePhone)
                UserDefaults.standard.set(onlinePhone.capacityExact, forKey: "ibw.lastKnowniPhonePct")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ibw.lastKnowniPhoneDate")
            } else if var cachedPhone = updatedDevices.first(where: { $0.deviceType != .mac && !$0.deviceId.contains("26cc71869") && !$0.deviceName.contains("15") }) {
                cachedPhone.uptimeSeconds = nil
                finalDevices.insert(cachedPhone, at: 0)
            } else {
                let lastKnownPct: Double = {
                    let saved = UserDefaults.standard.double(forKey: "ibw.lastKnowniPhonePct")
                    if saved > 0.0 { return saved }
                    return 74.0
                }()
                let fcc = last17?.fullChargeMah ?? 3908
                let remMah = Int((lastKnownPct / 100.0) * Double(fcc))
                
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let bDate = last17?.batteryManufactureDate ?? df.date(from: "2025-08-12")
                let dDate = last17?.deviceManufactureDate ?? df.date(from: "2025-08-25")
                let uDate = last17?.firstUseDate ?? df.date(from: "2025-09-20")
                let rDate = df.date(from: "2025-09-09")

                let synthDev = DeviceBatteryData(
                    deviceId: last17?.deviceId ?? "DJRXC6F3QC",
                    deviceName: cleanDeviceDisplayName(last17?.deviceName, fallback: "iPhone 17 Pro"),
                    deviceType: .iphone,
                    isConnected: false,
                    isWirelesslyConnected: false,
                    capacityInt: Int(lastKnownPct),
                    capacityExact: lastKnownPct,
                    isCharging: false,
                    isFullyCharged: false,
                    isACConnected: false,
                    cycleCount: last17?.cycleCount ?? 174,
                    batteryHealthPct: last17?.healthPct ?? 100.0,
                    voltageMv: 4120,
                    amperageMa: 0,
                    chargingWatts: nil,
                    ratePctPerHour: nil,
                    temperatureC: last17?.temperatureC ?? 26.5,
                    timeRemainingMins: nil,
                    remainingMah: remMah,
                    fullChargeMah: fcc,
                    designCapacityMah: last17?.designCapacityMah ?? 3998,
                    totalDiskBytes: 512_000_000_000,
                    freeDiskBytes: 340_000_000_000,
                    batteryManufactureDate: bDate,
                    deviceManufactureDate: dDate,
                    firstUseDate: uDate,
                    modelReleaseDate: rDate,
                    lastSeenAt: last17?.date ?? Date(),
                    processor: "Apple A19 Pro",
                    hardwareModel: last17?.deviceModel ?? "iPhone18,1",
                    serialNumber: last17?.deviceSerial ?? "DJRXC6F3QC",
                    fetchedAt: Date()
                )
                finalDevices.insert(synthDev, at: 0)
            }

            let unchanged = devices.count == finalDevices.count
                && zip(devices, finalDevices).allSatisfy { $0.liveEqual($1) }
            if !unchanged {
                devices = finalDevices
                saveDevices()
            }
            consider80PercentChargeDing(devices: finalDevices)
            if historyDirty { saveHistory() }
    }

    private func enrichWithBatteryRate(_ dev: DeviceBatteryData) -> DeviceBatteryData {
        let devId = dev.deviceId
        let now = Date()
        
        // 1. Add current reading to sample buffer
        var samples = recentSamples[devId] ?? []
        samples.append((date: now, cap: dev.capacityExact, isCharging: dev.isCharging))
        // Keep samples within last 2 hours
        samples = samples.filter { now.timeIntervalSince($0.date) < 7200 }
        recentSamples[devId] = samples
        
        let specs = AppleModelDatabase.lookupBatterySpecs(model: dev.hardwareModel ?? dev.deviceName)
        
        var finalWatts = dev.chargingWatts
        var finalAmperage = dev.amperageMa
        var finalRatePct = dev.ratePctPerHour
        var finalTimeRemaining = dev.timeRemainingMins
        
        // If hardware already gave precise watts/mA (e.g. Mac), compute ratePctPerHour from that
        if let w = finalWatts, abs(w) > 0.05 {
            let isDischarging = w < 0 || (!dev.isCharging && dev.isACConnected != true)
            let rate = (abs(w) / specs.wh) * 100.0
            finalRatePct = isDischarging ? -rate : rate
        } else {
            // Calculate rate from recent continuous sample run
            let matchingSamples = samples.filter { $0.isCharging == dev.isCharging }
            var calculatedRate: Double? = nil
            
            if let oldest = matchingSamples.first, matchingSamples.count >= 2 {
                let dtHours = now.timeIntervalSince(oldest.date) / 3600.0
                let dPct = dev.capacityExact - oldest.cap
                if dtHours >= (20.0 / 3600.0) && abs(dPct) >= 0.05 {
                    calculatedRate = dPct / dtHours
                }
            }
            
            // Fallback to historyPoints if available
            if calculatedRate == nil {
                let hist = historyPoints.filter { $0.deviceId == devId }.sorted(by: { $0.date > $1.date })
                if hist.count >= 2 {
                    let p1 = hist[0]
                    let p2 = hist[1]
                    let dtHours = p1.date.timeIntervalSince(p2.date) / 3600.0
                    let dPct = p1.batteryPct - p2.batteryPct
                    if dtHours >= 0.05 && abs(dPct) >= 0.1 {
                        calculatedRate = dPct / dtHours
                    }
                }
            }
            
            if dev.isCharging {
                let rate = max(5.0, min(80.0, calculatedRate.map { abs($0) } ?? 32.0))
                finalRatePct = rate
                finalWatts = (rate / 100.0) * specs.wh
                finalAmperage = Int((rate / 100.0) * Double(specs.mah))
                if finalTimeRemaining == nil && dev.capacityExact < 99.5 {
                    finalTimeRemaining = Int(((100.0 - dev.capacityExact) / rate) * 60.0)
                }
            } else if dev.isACConnected != true && !dev.isFullyCharged {
                let rate = max(1.0, min(30.0, calculatedRate.map { abs($0) } ?? 4.2))
                finalRatePct = -rate
                finalWatts = -((rate / 100.0) * specs.wh)
                finalAmperage = -Int((rate / 100.0) * Double(specs.mah))
                if finalTimeRemaining == nil && dev.capacityExact > 0.5 {
                    finalTimeRemaining = Int((dev.capacityExact / rate) * 60.0)
                }
            }
        }
        
        // Temperature Trend (Rising, Stable, Falling)
        var finalTempTrend: TemperatureTrend = .stable
        if let currentTemp = dev.temperatureC {
            var tSamples = recentTempSamples[devId] ?? []
            tSamples.append((date: now, temp: currentTemp))
            tSamples = tSamples.filter { now.timeIntervalSince($0.date) < 1800 }
            recentTempSamples[devId] = tSamples
            
            if let older = tSamples.first(where: { now.timeIntervalSince($0.date) >= 20 }), older.temp > 0 {
                let diff = currentTemp - older.temp
                if diff >= 0.12 {
                    finalTempTrend = .rising
                } else if diff <= -0.12 {
                    finalTempTrend = .falling
                } else {
                    finalTempTrend = .stable
                }
            } else if tSamples.count >= 2 {
                let prev = tSamples[tSamples.count - 2]
                let diff = currentTemp - prev.temp
                if diff >= 0.08 {
                    finalTempTrend = .rising
                } else if diff <= -0.08 {
                    finalTempTrend = .falling
                } else {
                    finalTempTrend = .stable
                }
            } else {
                let hist = historyPoints.filter { $0.deviceId == devId && $0.temperatureC != nil }.sorted(by: { $0.date > $1.date })
                if let latestHist = hist.first, let hTemp = latestHist.temperatureC {
                    let diff = currentTemp - hTemp
                    if diff >= 0.12 {
                        finalTempTrend = .rising
                    } else if diff <= -0.12 {
                        finalTempTrend = .falling
                    } else {
                        finalTempTrend = .stable
                    }
                }
            }
        }
        
        return DeviceBatteryData(
            deviceId: dev.deviceId,
            deviceName: dev.deviceName,
            deviceType: dev.deviceType,
            isConnected: dev.isConnected,
            isWirelesslyConnected: dev.isWirelesslyConnected,
            capacityInt: dev.capacityInt,
            capacityExact: dev.capacityExact,
            isCharging: dev.isCharging,
            isFullyCharged: dev.isFullyCharged,
            isACConnected: dev.isACConnected,
            cycleCount: dev.cycleCount,
            batteryHealthPct: dev.batteryHealthPct,
            voltageMv: dev.voltageMv,
            amperageMa: finalAmperage,
            chargingWatts: finalWatts,
            ratePctPerHour: finalRatePct,
            temperatureC: dev.temperatureC,
            tempTrend: finalTempTrend,
            timeRemainingMins: finalTimeRemaining,
            remainingMah: dev.remainingMah,
            fullChargeMah: dev.fullChargeMah,
            designCapacityMah: dev.designCapacityMah,
            totalDiskBytes: dev.totalDiskBytes,
            freeDiskBytes: dev.freeDiskBytes,
            batteryManufactureDate: dev.batteryManufactureDate,
            deviceManufactureDate: dev.deviceManufactureDate,
            firstUseDate: dev.firstUseDate,
            modelReleaseDate: dev.modelReleaseDate,
            lastSeenAt: dev.lastSeenAt,
            processor: dev.processor,
            hardwareModel: dev.hardwareModel,
            serialNumber: dev.serialNumber,
            fetchedAt: dev.fetchedAt,
            pdHandshakeOn: dev.pdHandshakeOn,
            pdInputVoltageV: dev.pdInputVoltageV,
            pdAdapterWatts: dev.pdAdapterWatts,
            systemLoadWatts: dev.systemLoadWatts,
            adapterInWatts: dev.adapterInWatts,
            uptimeSeconds: dev.uptimeSeconds
        )
    }

    private func recordHistory(_ dev: DeviceBatteryData) {
        // Record point if at least 180 seconds passed OR if charging status / temperature changed significantly
        let recent = historyPoints.last(where: { $0.deviceId == dev.deviceId })
        let shouldRecord: Bool
        if let recent = recent {
            let elapsed = abs(recent.date.timeIntervalSinceNow)
            let tempChanged = abs((recent.temperatureC ?? 0) - (dev.temperatureC ?? 0)) >= 0.3
            let pctChanged = abs(recent.batteryPct - dev.capacityExact) >= 0.5
            let stateChanged = (recent.isCharging != dev.isCharging) || (recent.isACConnected != dev.isACConnected)
            shouldRecord = elapsed >= 180 || (elapsed >= 30 && (tempChanged || pctChanged || stateChanged))
        } else {
            shouldRecord = true
        }
        
        if shouldRecord {
            let pt = BatteryHistoryPoint(
                deviceId: dev.deviceId,
                deviceName: dev.deviceName,
                deviceType: dev.deviceType,
                date: Date(),
                batteryPct: dev.capacityExact,
                healthPct: dev.batteryHealthPct,
                cycleCount: dev.cycleCount,
                capacityMah: dev.remainingMah,
                fullChargeMah: dev.fullChargeMah,
                designCapacityMah: dev.designCapacityMah,
                temperatureC: dev.temperatureC,
                batteryManufactureDate: dev.batteryManufactureDate,
                deviceManufactureDate: dev.deviceManufactureDate,
                firstUseDate: dev.firstUseDate,
                isCharging: dev.isCharging,
                isACConnected: dev.isACConnected,
                chargingWatts: dev.chargingWatts,
                deviceModel: dev.hardwareModel,
                osVersion: dev.deviceType == .mac ? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)" : "27.0",
                appVersion: "4.4.0",
                batterySerial: dev.serialNumber,
                deviceSerial: dev.serialNumber
            )
            historyPoints.append(pt)
            historyDirty = true
            if historyPoints.count > 5000 {
                historyPoints.removeFirst(historyPoints.count - 5000)
            }
        }
    }

    private func considerPDHandshakeHint(_ mac: DeviceBatteryData) {
        guard pdSoundEnabled else {
            lastPDHandshakeOn = mac.pdHandshakeOn
            pdDisconnectPending = nil
            return
        }

        let currentPD = mac.pdHandshakeOn == true

        if let previousPD = lastPDHandshakeOn {
            if previousPD && !currentPD {
                // Potential disconnect: start debounce timer
                if pdDisconnectPending == nil {
                    pdDisconnectPending = Date()
                }
            } else if currentPD {
                pdDisconnectPending = nil
            }
        }

        if let pending = pdDisconnectPending, !currentPD {
            if Date().timeIntervalSince(pending) >= pdDebounceInterval {
                playPDSound()
                pdDisconnectPending = nil
                lastPDHandshakeOn = false
            }
        } else {
            lastPDHandshakeOn = currentPD
        }
    }

    func playPDSound(named soundName: String? = nil, volume: Float = 0.80) {
        if soundName == nil && Date().timeIntervalSince(lastPDAlertAt) < 2.0 { return }
        if soundName == nil { lastPDAlertAt = Date() }
        let theme = soundName ?? pdSoundTheme
        let resolved = theme.prefix(1).uppercased() + theme.dropFirst().lowercased()
        panPlayer.playLeftToRight(named: resolved, volume: volume)
    }

    private func considerIPhoneConnectionSound(connected: Bool) {
        if let previous = lastIPhoneConnected {
            if !previous && connected && iphoneSoundEnabled {
                // iPhone plugged in / connected via wire
                playIPhoneSound()
            } else if previous && !connected && iphoneDisconnectSoundEnabled {
                // iPhone unplugged / disconnected
                playIPhoneDisconnectSound()
            }
        }
        lastIPhoneConnected = connected
    }

    func playIPhoneSound(named soundName: String? = nil, volume: Float = 0.85) {
        if soundName == nil && Date().timeIntervalSince(lastIPhoneSoundAt) < 2.0 { return }
        if soundName == nil { lastIPhoneSoundAt = Date() }
        let theme = soundName ?? iphoneConnectSoundTheme
        let resolved = theme.prefix(1).uppercased() + theme.dropFirst().lowercased()
        let sound = NSSound(named: NSSound.Name(resolved)) ?? NSSound(named: NSSound.Name("Pop"))
        sound?.volume = volume
        sound?.play()
    }

    func playIPhoneDisconnectSound(named soundName: String? = nil, volume: Float = 0.80) {
        if soundName == nil && Date().timeIntervalSince(lastIPhoneDisconnectSoundAt) < 2.0 { return }
        if soundName == nil { lastIPhoneDisconnectSoundAt = Date() }
        let theme = soundName ?? iphoneDisconnectSoundTheme
        let resolved = theme.prefix(1).uppercased() + theme.dropFirst().lowercased()
        let sound = NSSound(named: NSSound.Name(resolved)) ?? NSSound(named: NSSound.Name("Blow"))
        sound?.volume = volume
        sound?.play()
    }

    private func consider80PercentChargeDing(devices: [DeviceBatteryData]) {
        guard eightyPercentAlertEnabled else { return }
        for dev in devices {
            // ONLY play 80% sound for iPhone / iPad, NEVER for Mac
            guard dev.deviceType != .mac && dev.deviceId != "local_mac" else { continue }
            
            let isChargingOrAC = dev.isCharging || (dev.isACConnected == true)
            if isChargingOrAC {
                if dev.capacityExact >= 80.0 {
                    if !alerted80DeviceIds.contains(dev.deviceId) {
                        alerted80DeviceIds.insert(dev.deviceId)
                        if Date().timeIntervalSince(last80DingAt) >= 5.0 {
                            last80DingAt = Date()
                            play80PercentDingSound()
                        }
                    }
                } else if dev.capacityExact < 78.0 {
                    alerted80DeviceIds.remove(dev.deviceId)
                }
            } else {
                if dev.capacityExact < 79.0 {
                    alerted80DeviceIds.remove(dev.deviceId)
                }
            }
        }
    }

    func play80PercentDingSound(theme: String? = nil) {
        let selectedTheme = theme ?? eightyPercentSoundTheme
        let resolved = selectedTheme.prefix(1).uppercased() + selectedTheme.dropFirst().lowercased()
        let sound = NSSound(named: NSSound.Name(resolved)) ?? NSSound(named: NSSound.Name("Glass"))
        sound?.volume = 0.80
        sound?.play()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: kPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

// MARK: - Stereo Pan Audio Player (Left-to-Right Speaker Sweep)

final class PanAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var duration: TimeInterval = 0

    func playLeftToRight(named soundName: String, volume: Float = 0.85) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(soundName).aiff")
        guard FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            let fallback = NSSound(named: NSSound.Name(soundName))
            fallback?.volume = volume
            fallback?.play()
            return
        }
        self.player = p
        p.delegate = self
        p.volume = volume
        p.pan = -1.0 // Start full left speaker
        p.prepareToPlay()
        p.play()
        
        self.startTime = ProcessInfo.processInfo.systemUptime
        self.duration = max(0.2, min(1.4, p.duration))
        
        self.timer?.invalidate()
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] tm in
            guard let self, let p = self.player, p.isPlaying else {
                tm.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.startTime
            let progress = min(1.0, elapsed / self.duration)
            // Pan smoothly from -1.0 (Left Speaker) to +1.0 (Right Speaker)
            p.pan = Float(-1.0 + (2.0 * progress))
            if progress >= 1.0 {
                tm.invalidate()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }
}

// MARK: - Color Hex Helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        self.init(
            red:   Double((int >> 16) & 0xFF) / 255,
            green: Double((int >>  8) & 0xFF) / 255,
            blue:  Double( int        & 0xFF) / 255
        )
    }
}

func systemPowerColor(_ w: Double) -> Color {
    if w >= 16 { return Color(hex: "#FF9F0A") }
    if w >= 10 { return Color(hex: "#FFD60A") }
    return Color(hex: "#64D2FF")
}

func formatWatts(_ w: Double, prefix: String? = nil) -> String {
    let body = abs(w) >= 10 ? String(format: "%.0f W", abs(w)) : String(format: "%.1f W", abs(w))
    if let prefix { return prefix + body }
    if w < 0 { return "−" + body }
    return body
}

func coarseAgo(_ date: Date) -> String {
    let s = max(0, Int(-date.timeIntervalSinceNow))
    if s < 90 { return "just now" }
    if s < 3600 { return "\(max(1, s / 60))m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    let d = s / 86400
    return d == 1 ? "1d ago" : "\(d)d ago"
}

func formatUptime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let d = s / 86400
    let h = (s % 86400) / 3600
    let m = (s % 3600) / 60
    if d > 0 { return h > 0 ? "Up \(d)d \(h)h" : "Up \(d)d" }
    if h > 0 { return "Up \(h)h \(m)m" }
    return "Up \(max(1, m))m"
}

func formatTimeShort(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

func formatTimeFull(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

func quietStampText(_ info: DeviceBatteryData) -> String? {
    let isMac = info.deviceType == .mac || info.deviceId == "local_mac"
    if isMac {
        return "Last read \(coarseAgo(info.fetchedAt))"
    }
    if !info.isConnected {
        return "Last seen \(coarseAgo(info.lastSeenAt ?? info.fetchedAt))"
    }
    return "Last read \(coarseAgo(info.fetchedAt))"
}

struct QuietStamp: View {
    let info: DeviceBatteryData
    @State private var manualUptimeTimestamp: Double = 0
    @State private var hoverUptime: Bool = false

    private var storageKey: String {
        "ibw.manual_uptime_start_\(info.deviceId)"
    }

    private var isMac: Bool {
        info.deviceType == .mac || info.deviceId == "local_mac"
    }

    private func currentManualUptime() -> Int? {
        let ts = manualUptimeTimestamp > 0 ? manualUptimeTimestamp : UserDefaults.standard.double(forKey: storageKey)
        let fallbackTs = ts > 0 ? ts : UserDefaults.standard.double(forKey: "ibw.manual_uptime_start_iphone")
        guard fallbackTs > 0 else { return nil }
        let elapsed = Int(Date().timeIntervalSince1970 - fallbackTs)
        return max(0, elapsed)
    }

    private func restartManualUptime() {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: storageKey)
        UserDefaults.standard.set(now, forKey: "ibw.manual_uptime_start_iphone")
        manualUptimeTimestamp = now
    }

    var body: some View {
        let right = quietStampText(info)
        let directUptime = info.uptimeSeconds
        let effectiveUptime: Int? = {
            if let directUptime {
                if isMac { return directUptime }
                if info.isConnected { return directUptime }
            }
            if !isMac {
                return currentManualUptime()
            }
            return nil
        }()

        HStack(spacing: 8) {
            if isMac {
                if let u = directUptime {
                    Text(formatUptime(u))
                }
            } else {
                if let u = effectiveUptime {
                    Button(action: {
                        restartManualUptime()
                    }) {
                        HStack(spacing: 3) {
                            Text(formatUptime(u))
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 6.5))
                                .opacity(hoverUptime ? 0.9 : 0.4)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { h in hoverUptime = h }
                    .help("Click to restart uptime timer from now")
                } else {
                    Button(action: {
                        restartManualUptime()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 7))
                            Text("Restart Uptime")
                        }
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.45))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Set iPhone uptime restart to now")
                }
            }

            Spacer(minLength: 4)

            if let right {
                Text(right)
            }
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundColor(Color.white.opacity(0.32))
        .onAppear {
            let ts = UserDefaults.standard.double(forKey: storageKey)
            if ts > 0 {
                manualUptimeTimestamp = ts
            }
        }
    }
}

enum MacChargeLabel {
    static func status(_ info: DeviceBatteryData) -> (label: String, icon: String, color: Color) {
        let amps = info.amperageMa ?? 0
        let watts = info.chargingWatts ?? 0
        let actuallyCharging = info.isCharging || amps > 30 || watts > 0.3
        if actuallyCharging {
            return ("Charging", "bolt.fill", Color(hex: "#30D158"))
        }
        if info.isFullyCharged || info.capacityExact >= 99.5 {
            return ("Fully Charged", "bolt.fill", Color(hex: "#30D158"))
        }
        if info.isACConnected == true {
            // Real pause = 80% Optimized Battery Charging / charge limit, not "plugged in below 98%"
            let hold = info.capacityExact >= 78 && info.capacityExact < 99 && abs(amps) < 50 && abs(watts) < 0.4
            if hold {
                return ("Charging Paused", "pause.circle.fill", Color(hex: "#FFD60A"))
            }
            return ("On AC", "bolt.fill", Color(hex: "#30D158"))
        }
        return ("Discharging", "arrow.down.circle", Color(hex: "#FF9F0A"))
    }
}

func temperatureColor(_ temp: Double) -> Color {
    if temp >= 38.0 {
        return Color(hex: "#FF453A") // Base Red
    } else if temp >= 35.0 {
        return Color(hex: "#FF9F0A") // Base Orange
    } else if temp < 30.0 {
        return Color(hex: "#0A84FF") // Base Blue
    } else {
        return .white.opacity(0.92) // Natural White (30.0 - 34.9 °C)
    }
}

func temperatureTextColor(_ temp: Double) -> Color {
    if temp >= 38.0 {
        return Color(hex: "#FF6961") // Lighter Red / Coral Red
    } else if temp >= 35.0 {
        return Color(hex: "#FFB340") // Lighter Orange / Warm Amber
    } else if temp < 30.0 {
        return Color(hex: "#5AC8FA") // Lighter Blue / Sky Blue
    } else {
        return .white.opacity(0.92) // Natural White (30.0 - 34.9 °C)
    }
}

// MARK: - Battery Capacity & Blue Target Range Helper
// iPhone: 80% charged -> Blue gradient bar
// Mac: 65% - 70% charged -> Blue gradient bar

func isTargetBlueBattery(val: Double, isMac: Bool) -> Bool {
    if isMac {
        return val >= 65.0 && val <= 70.0
    } else {
        return (val >= 79.5 && val <= 80.5) || Int(val.rounded()) == 80
    }
}

func capacityColor(_ val: Double, isCharging: Bool, isMac: Bool = false) -> Color {
    if isTargetBlueBattery(val: val, isMac: isMac) {
        return Color(hex: "#64D2FF")
    }
    if isCharging { return Color(hex: "#30D158") }
    if val <= 20 { return Color(hex: "#FF453A") }
    if val <= 40 { return Color(hex: "#FF9F0A") }
    return .white.opacity(0.82)
}

func batteryFillGradient(val: Double, isCharging: Bool, isMac: Bool) -> [Color] {
    if isTargetBlueBattery(val: val, isMac: isMac) {
        return [Color(hex: "#0A84FF").opacity(0.65), Color(hex: "#64D2FF")]
    }
    let col = capacityColor(val, isCharging: isCharging, isMac: isMac)
    return [col.opacity(0.8), col]
}

// MARK: - Mini Progress Bar (Health / Battery)

struct CompactProgressBar: View {
    let value: Double // 0 to 100
    let fillGradient: [Color]
    let height: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(0.08))
                
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(LinearGradient(colors: fillGradient, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(value / 100.0))))
                    .animation(.easeInOut(duration: 0.4), value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Stat Row Component

struct BatteryStatRow: View {
    let icon: String?
    let label: String
    let value: String
    var highlight: Color? = nil
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 12)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(highlight ?? .white.opacity(0.85))
        }
    }
}

// MARK: - Interactive 7-Day History & 100% Charge Chart View

struct SevenDayLineGraphCanvas: View {
    let points: [BatteryHistoryPoint]
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            if points.count >= 2 {
                let minDate = points.first!.date.timeIntervalSince1970
                let maxDate = max(minDate + 1, points.last!.date.timeIntervalSince1970)
                
                let xVals = points.map { pt -> CGFloat in
                    let t = pt.date.timeIntervalSince1970
                    return CGFloat((t - minDate) / (maxDate - minDate)) * w
                }
                
                let yVals = points.map { pt -> CGFloat in
                    let clamped = max(0, min(100, pt.batteryPct))
                    return h - (CGFloat(clamped / 100.0) * (h - 14) + 7)
                }
                
                let y100 = h - (CGFloat(1.0) * (h - 14) + 7)
                let y50 = h - (CGFloat(0.5) * (h - 14) + 7)
                
                ZStack {
                    // 100% Reference Dotted Line
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y100))
                        p.addLine(to: CGPoint(x: w, y: y100))
                    }
                    .stroke(Color(hex: "#30D158").opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    
                    // 50% Reference Dotted Line
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y50))
                        p.addLine(to: CGPoint(x: w, y: y50))
                    }
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    
                    // Gradient Fill Path
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: CGPoint(x: xVals[0], y: yVals[0]))
                        for i in 0..<points.count {
                            p.addLine(to: CGPoint(x: xVals[i], y: yVals[i]))
                        }
                        p.addLine(to: CGPoint(x: xVals.last!, y: h))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#30D158").opacity(0.28), Color(hex: "#64D2FF").opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    // Stroke Line
                    Path { p in
                        p.move(to: CGPoint(x: xVals[0], y: yVals[0]))
                        for i in 1..<points.count {
                            p.addLine(to: CGPoint(x: xVals[i], y: yVals[i]))
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "#30D158"), Color(hex: "#64D2FF")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    
                    // 100% Charge Highlight Points
                    ForEach(0..<points.count, id: \.self) { i in
                        if points[i].batteryPct >= 99.0 {
                            Circle()
                                .fill(Color(hex: "#30D158"))
                                .frame(width: 8, height: 8)
                                .shadow(color: Color(hex: "#30D158").opacity(0.8), radius: 4)
                                .position(x: xVals[i], y: yVals[i])
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Interactive Health, Cycles & Capacity Degradation Canvas with Hover Details

struct BatteryDegradationGraphCanvas: View {
    let points: [BatteryHistoryPoint]
    let showHealth: Bool
    let showCycles: Bool
    let showCapacity: Bool
    let designCapacity: Double?
    var comparisonPoints: [BatteryHistoryPoint] = []
    var comparisonLabel: String = "iPhone 15"
    
    @State private var hoveredPoint: BatteryHistoryPoint? = nil
    @State private var hoverXLocation: CGFloat? = nil
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padL: CGFloat = 40
            let padR: CGFloat = 16
            let padT: CGFloat = 16
            let padB: CGFloat = 24
            let plotW = max(10, w - padL - padR)
            let plotH = max(10, h - padT - padB)

            let validPoints = points.sorted(by: { $0.date < $1.date })

            if !validPoints.isEmpty {
                let firstT = validPoints.first!.date.timeIntervalSince1970
                let lastT = validPoints.last!.date.timeIntervalSince1970
                let span = lastT - firstT
                let minT = span < 3600 ? (firstT - 3600) : firstT
                let maxT = span < 3600 ? (lastT + 3600) : (firstT == lastT ? firstT + 86400 : lastT)

                // Computed ranges
                let healthPoints = validPoints.compactMap { pt -> (t: Double, val: Double)? in
                    guard let val = pt.healthPct else { return nil }
                    return (pt.date.timeIntervalSince1970, val)
                }
                
                let cyclePoints = validPoints.compactMap { pt -> (t: Double, val: Double)? in
                    guard let val = pt.cycleCount else { return nil }
                    return (pt.date.timeIntervalSince1970, Double(val))
                }

                let capPoints = validPoints.compactMap { pt -> (t: Double, val: Double)? in
                    guard let val = pt.fullChargeMah ?? pt.capacityMah else { return nil }
                    return (pt.date.timeIntervalSince1970, Double(val))
                }

                let maxCycleVal = max(10, cyclePoints.map { $0.val }.max() ?? 500)
                let designCapVal = designCapacity ?? (capPoints.map { $0.val }.max() ?? 4000)
                let minCapVal = max(0, (capPoints.map { $0.val }.min() ?? 3000) * 0.8)
                let maxCapVal = max(designCapVal, (capPoints.map { $0.val }.max() ?? 4000) * 1.05)

                ZStack(alignment: .topLeading) {
                    // Background grid (aligned to 100%, 90%, 80% health levels with headroom for 102+%)
                    Path { p in
                        // 100% line
                        let y100 = padT + plotH * (1.0 - 25.0 / 30.0)
                        p.move(to: CGPoint(x: padL, y: y100))
                        p.addLine(to: CGPoint(x: padL + plotW, y: y100))
                        // 90% line
                        let y90 = padT + plotH * 0.5
                        p.move(to: CGPoint(x: padL, y: y90))
                        p.addLine(to: CGPoint(x: padL + plotW, y: y90))
                        // 80% line
                        let y80 = padT + plotH * (1.0 - 5.0 / 30.0)
                        p.move(to: CGPoint(x: padL, y: y80))
                        p.addLine(to: CGPoint(x: padL + plotW, y: y80))
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // Y-Axis Labels
                    ZStack(alignment: .trailing) {
                        Text("100%")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(hex: "#30D158"))
                            .position(x: (padL - 10) / 2, y: padT + plotH * (1.0 - 25.0 / 30.0))

                        Text("90%")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .position(x: (padL - 10) / 2, y: padT + plotH * 0.5)

                        Text("80%")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(hex: "#FF453A"))
                            .position(x: (padL - 10) / 2, y: padT + plotH * (1.0 - 5.0 / 30.0))
                    }
                    .frame(width: padL - 6, height: plotH)

                    // 1. Capacity Line (Cyan)
                    if showCapacity && !capPoints.isEmpty {
                        let capCurve = Path { p in
                            for (i, pt) in capPoints.enumerated() {
                                let x = padL + CGFloat((pt.t - minT) / (maxT - minT)) * plotW
                                let norm = (pt.val - minCapVal) / max(1, (maxCapVal - minCapVal))
                                let y = padT + plotH - CGFloat(norm) * plotH
                                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                else { p.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        capCurve.stroke(Color(hex: "#64D2FF").opacity(0.85), lineWidth: 2)
                    }

                    // 2. Cycles Curve (Amber / Yellow)
                    if showCycles && !cyclePoints.isEmpty {
                        let cycleCurve = Path { p in
                            for (i, pt) in cyclePoints.enumerated() {
                                let x = padL + CGFloat((pt.t - minT) / (maxT - minT)) * plotW
                                let norm = pt.val / maxCycleVal
                                let y = padT + plotH - CGFloat(norm) * plotH
                                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                else { p.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        cycleCurve.stroke(Color(hex: "#FFD60A").opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }

                    // 3. Health Degradation Line & Gradient Fill (Green -> Orange)
                    if showHealth && !healthPoints.isEmpty {
                        // Area fill
                        Path { p in
                            let firstX = padL + CGFloat((healthPoints[0].t - minT) / (maxT - minT)) * plotW
                            p.move(to: CGPoint(x: firstX, y: padT + plotH))
                            for pt in healthPoints {
                                let x = padL + CGFloat((pt.t - minT) / (maxT - minT)) * plotW
                                let norm = (pt.val - 75.0) / 30.0
                                let y = padT + plotH - CGFloat(max(0, min(1, norm))) * plotH
                                p.addLine(to: CGPoint(x: x, y: y))
                            }
                            let lastX = padL + CGFloat((healthPoints.last!.t - minT) / (maxT - minT)) * plotW
                            p.addLine(to: CGPoint(x: lastX, y: padT + plotH))
                            p.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#30D158").opacity(0.35), Color(hex: "#30D158").opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Health Stroke
                        Path { p in
                            for (i, pt) in healthPoints.enumerated() {
                                let x = padL + CGFloat((pt.t - minT) / (maxT - minT)) * plotW
                                let norm = (pt.val - 75.0) / 30.0
                                let y = padT + plotH - CGFloat(max(0, min(1, norm))) * plotH
                                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                else { p.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "#30D158"), Color(hex: "#FFD60A"), Color(hex: "#FF453A")],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 2.5
                        )

                        if healthPoints.count == 1 {
                            let pt = healthPoints[0]
                            let x = padL + CGFloat((pt.t - minT) / (maxT - minT)) * plotW
                            let norm = (pt.val - 75.0) / 30.0
                            let y = padT + plotH - CGFloat(max(0, min(1, norm))) * plotH
                            Circle()
                                .fill(Color(hex: "#30D158"))
                                .frame(width: 8, height: 8)
                                .position(x: x, y: y)
                        }
                    }

                    // 3b. Comparison Degradation Line (Dashed Lilac / Purple)
                    if showHealth && !comparisonPoints.isEmpty {
                        let compHealth = comparisonPoints.sorted(by: { $0.date < $1.date }).compactMap { pt -> (t: Double, val: Double, cyc: Int?)? in
                            guard let val = pt.healthPct else { return nil }
                            return (pt.date.timeIntervalSince1970, val, pt.cycleCount)
                        }
                        if !compHealth.isEmpty {
                            let compMinT = compHealth.first!.t
                            let compMaxT = compHealth.last!.t
                            let compSpan = max(1.0, compMaxT - compMinT)
                            
                            Path { p in
                                for (i, pt) in compHealth.enumerated() {
                                    let rel = (pt.t - compMinT) / compSpan
                                    let x = padL + CGFloat(rel) * plotW
                                    let norm = (pt.val - 75.0) / 30.0
                                    let y = padT + plotH - CGFloat(max(0, min(1, norm))) * plotH
                                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                                }
                            }
                            .stroke(Color(hex: "#CB64F4"), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                    }

                    // 4. Interactive Hover Indicator Line & Details Tooltip
                    if let hp = hoveredPoint, let hx = hoverXLocation {
                        // Vertical indicator line
                        Path { p in
                            p.move(to: CGPoint(x: hx, y: padT))
                            p.addLine(to: CGPoint(x: hx, y: padT + plotH))
                        }
                        .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                        // Selected point highlight dot
                        if let hval = hp.healthPct {
                            let norm = (hval - 75.0) / 30.0
                            let hy = padT + plotH - CGFloat(max(0, min(1, norm))) * plotH
                            Circle()
                                .fill(Color(hex: "#30D158"))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(color: Color(hex: "#30D158").opacity(0.8), radius: 4)
                                .position(x: hx, y: hy)
                        }

                        // Floating Tooltip Card at the Base of the Graph
                        let tooltipX = min(max(padL + 110, hx), padL + plotW - 110)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(formatTooltipDate(hp.date))
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Divider().frame(height: 10).background(Color.white.opacity(0.2))

                                if let h = hp.healthPct {
                                    HStack(spacing: 3) {
                                        Circle().fill(Color(hex: "#30D158")).frame(width: 5, height: 5)
                                        Text(String(format: "%.1f%%", h))
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundColor(Color(hex: "#30D158"))
                                    }
                                }

                                if let c = hp.cycleCount {
                                    HStack(spacing: 3) {
                                        Circle().fill(Color(hex: "#FFD60A")).frame(width: 5, height: 5)
                                        Text("\(c) cyc")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundColor(Color(hex: "#FFD60A"))
                                    }
                                }

                                if let cap = hp.fullChargeMah ?? hp.capacityMah {
                                    HStack(spacing: 3) {
                                        Circle().fill(Color(hex: "#64D2FF")).frame(width: 5, height: 5)
                                        Text("\(cap) mAh")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundColor(Color(hex: "#64D2FF"))
                                    }
                                }

                                if !comparisonPoints.isEmpty, let cyc = hp.cycleCount {
                                    if let compClosest = comparisonPoints.min(by: { abs(($0.cycleCount ?? 0) - cyc) < abs(($1.cycleCount ?? 0) - cyc) }),
                                       let compH = compClosest.healthPct {
                                        HStack(spacing: 3) {
                                            Circle().fill(Color(hex: "#CB64F4")).frame(width: 5, height: 5)
                                            Text("Old: \(String(format: "%.1f%%", compH))")
                                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                                .foregroundColor(Color(hex: "#CB64F4"))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: "#18181A").opacity(0.96))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(hex: "#0A84FF").opacity(0.5), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 3)
                        )
                        .position(x: tooltipX, y: padT + plotH - 22)
                    }

                    // X-Axis Timeline Dates
                    HStack {
                        Text(formatXDate(validPoints.first!.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        if !comparisonPoints.isEmpty {
                            HStack(spacing: 6) {
                                HStack(spacing: 3) {
                                    Circle().fill(Color(hex: "#30D158")).frame(width: 5, height: 5)
                                    Text("17 Pro").font(.system(size: 8.5, weight: .bold)).foregroundColor(Color(hex: "#30D158"))
                                }
                                HStack(spacing: 3) {
                                    Circle().fill(Color(hex: "#CB64F4")).frame(width: 5, height: 5)
                                    Text("15 (Old)").font(.system(size: 8.5, weight: .bold)).foregroundColor(Color(hex: "#CB64F4"))
                                }
                            }
                        } else {
                            Text("Timeline Degradation Trajectory (Hover for Details)")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        Spacer()
                        Text(formatXDate(validPoints.last!.date))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: "#0A84FF"))
                    }
                    .padding(.horizontal, padL)
                    .position(x: padL + plotW / 2, y: padT + plotH + 12)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let locX = location.x
                        guard locX >= padL && locX <= padL + plotW else {
                            self.hoveredPoint = nil
                            self.hoverXLocation = nil
                            return
                        }
                        let ratio = Double((locX - padL) / plotW)
                        let targetT = minT + ratio * (maxT - minT)
                        
                        if let closest = validPoints.min(by: { abs($0.date.timeIntervalSince1970 - targetT) < abs($1.date.timeIntervalSince1970 - targetT) }) {
                            let closestX = padL + CGFloat((closest.date.timeIntervalSince1970 - minT) / (maxT - minT)) * plotW
                            withAnimation(.easeOut(duration: 0.08)) {
                                self.hoveredPoint = closest
                                self.hoverXLocation = closestX
                            }
                        }
                    case .ended:
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.hoveredPoint = nil
                            self.hoverXLocation = nil
                        }
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Insufficient snapshots for degradation curve.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func formatXDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    private func formatTooltipDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Interactive Daily Battery Temperature Graph Canvas with Hover & 35°C Alerts

struct DailyTemperatureGraphCanvas: View {
    let points: [BatteryHistoryPoint]
    var fixedMinTime: Double? = nil
    var fixedMaxTime: Double? = nil
    var isSingleDay: Bool = false
    @State private var hoveredPoint: BatteryHistoryPoint? = nil
    @State private var hoverXLocation: CGFloat? = nil

    private func yForTemp(_ t: Double, padT: CGFloat, plotH: CGFloat) -> CGFloat {
        let minScaleTemp: Double = 15.0
        let maxScaleTemp: Double = 45.0
        let tempRange = maxScaleTemp - minScaleTemp
        let clamped = max(minScaleTemp, min(maxScaleTemp, t))
        let norm = (clamped - minScaleTemp) / tempRange
        return padT + plotH * CGFloat(1.0 - norm)
    }

    private func xForTime(_ t: Double, minT: Double, maxT: Double, padL: CGFloat, plotW: CGFloat) -> CGFloat {
        let span = maxT - minT
        if span <= 0 { return padL + plotW / 2 }
        return padL + CGFloat((t - minT) / span) * plotW
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padL: CGFloat = 38
            let padR: CGFloat = 16
            let padT: CGFloat = 18
            let padB: CGFloat = 24
            let plotW = max(10, w - padL - padR)
            let plotH = max(10, h - padT - padB)

            let validPoints = points.filter { $0.temperatureC != nil }.sorted(by: { $0.date < $1.date })

            let minT: Double = {
                if let fMin = fixedMinTime { return fMin }
                if let first = validPoints.first?.date.timeIntervalSince1970 {
                    let last = validPoints.last?.date.timeIntervalSince1970 ?? first
                    return (last - first < 3600) ? (first - 3600) : first
                }
                return Date().timeIntervalSince1970 - 86400
            }()

            let maxT: Double = {
                if let fMax = fixedMaxTime { return fMax }
                if let last = validPoints.last?.date.timeIntervalSince1970 {
                    let first = validPoints.first?.date.timeIntervalSince1970 ?? last
                    return (last - first < 3600) ? (last + 3600) : (first == last ? first + 86400 : last)
                }
                return Date().timeIntervalSince1970
            }()

            let y35 = yForTemp(35.0, padT: padT, plotH: plotH)
            let y30 = yForTemp(30.0, padT: padT, plotH: plotH)
            let y25 = yForTemp(25.0, padT: padT, plotH: plotH)

            ZStack(alignment: .topLeading) {
                // Reference Grid Lines
                Path { p in
                    // 35°C Hot Alert Line
                    p.move(to: CGPoint(x: padL, y: y35))
                    p.addLine(to: CGPoint(x: padL + plotW, y: y35))
                }
                .stroke(Color(hex: "#FF453A").opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                Path { p in
                    // 30°C Line
                    p.move(to: CGPoint(x: padL, y: y30))
                    p.addLine(to: CGPoint(x: padL + plotW, y: y30))
                    // 25°C Line
                    p.move(to: CGPoint(x: padL, y: y25))
                    p.addLine(to: CGPoint(x: padL + plotW, y: y25))
                }
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Vertical Time Guide Grid Lines for Full Day
                if isSingleDay {
                    ForEach([4, 8, 12, 16, 20], id: \.self) { hour in
                        let hourTime = minT + Double(hour * 3600)
                        let gridX = xForTime(hourTime, minT: minT, maxT: maxT, padL: padL, plotW: plotW)
                        Path { p in
                            p.move(to: CGPoint(x: gridX, y: padT))
                            p.addLine(to: CGPoint(x: gridX, y: padT + plotH))
                        }
                        .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }
                }

                // Y-Axis Labels & Alert Badges
                ZStack(alignment: .trailing) {
                    HStack(spacing: 2) {
                        Text("35°C")
                            .font(.system(size: 8.5, weight: .bold))
                        Image(systemName: "flame.fill")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundColor(Color(hex: "#FF453A"))
                    .position(x: (padL - 6) / 2, y: y35)

                    Text("30°C")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .position(x: (padL - 6) / 2, y: y30)

                    Text("25°C")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .position(x: (padL - 6) / 2, y: y25)
                }
                .frame(width: padL - 4, height: plotH)

                if !validPoints.isEmpty {
                    // Temperature Area Gradient Fill
                    Path { p in
                        p.move(to: CGPoint(x: padL, y: padT + plotH))
                        for (i, pt) in validPoints.enumerated() {
                            guard let tempVal = pt.temperatureC else { continue }
                            let x = xForTime(pt.date.timeIntervalSince1970, minT: minT, maxT: maxT, padL: padL, plotW: plotW)
                            let y = yForTemp(tempVal, padT: padT, plotH: plotH)
                            if i == 0 {
                                p.addLine(to: CGPoint(x: x, y: padT + plotH))
                                p.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                p.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        let lastX = xForTime(validPoints.last!.date.timeIntervalSince1970, minT: minT, maxT: maxT, padL: padL, plotW: plotW)
                        p.addLine(to: CGPoint(x: lastX, y: padT + plotH))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#FF453A").opacity(0.25),
                                Color(hex: "#FF9F0A").opacity(0.18),
                                Color(hex: "#30D158").opacity(0.10),
                                Color(hex: "#64D2FF").opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Temperature Stroke Curve
                    Path { p in
                        for (i, pt) in validPoints.enumerated() {
                            guard let tempVal = pt.temperatureC else { continue }
                            let x = xForTime(pt.date.timeIntervalSince1970, minT: minT, maxT: maxT, padL: padL, plotW: plotW)
                            let y = yForTemp(tempVal, padT: padT, plotH: plotH)
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "#30D158"), Color(hex: "#FFD60A"), Color(hex: "#FF453A")],
                            startPoint: .bottom,
                            endPoint: .top
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )

                    // Data Points / Temperature Dots
                    ForEach(validPoints) { pt in
                        if let temp = pt.temperatureC {
                            let dotCol = temperatureColor(temp)
                            let isHot = temp >= 38.0
                            let x = xForTime(pt.date.timeIntervalSince1970, minT: minT, maxT: maxT, padL: padL, plotW: plotW)
                            let y = yForTemp(temp, padT: padT, plotH: plotH)
                            Circle()
                                .fill(dotCol)
                                .frame(width: isHot ? 7 : (temp >= 35.0 ? 6 : 4), height: isHot ? 7 : (temp >= 35.0 ? 6 : 4))
                                .shadow(color: temp >= 35.0 ? dotCol.opacity(0.8) : Color.clear, radius: 3)
                                .position(x: x, y: y)
                        }
                    }

                    // Hover Guide Line & Pulsing Indicator
                    if let hX = hoverXLocation, let hPt = hoveredPoint, let tempVal = hPt.temperatureC {
                        let hY = yForTemp(tempVal, padT: padT, plotH: plotH)
                        let tipCol = temperatureColor(tempVal)

                        // Vertical dashed indicator
                        Path { p in
                            p.move(to: CGPoint(x: hX, y: padT))
                            p.addLine(to: CGPoint(x: hX, y: padT + plotH))
                        }
                        .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        // Pulsing Ring
                        Circle()
                            .stroke(tipCol, lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .position(x: hX, y: hY)

                        Circle()
                            .fill(tipCol)
                            .frame(width: 6, height: 6)
                            .position(x: hX, y: hY)

                        // Tooltip
                        let tipX = min(max(padL + 75, hX), padL + plotW - 75)
                        let tipY = max(padT + 28, hY - 36)

                        VStack(spacing: 2) {
                            Text(formatTooltipDate(hPt.date))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            HStack(spacing: 4) {
                                Image(systemName: tempVal >= 35.0 ? "flame.fill" : "thermometer.medium")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(tipCol)
                                Text(String(format: "%.1f°C", tempVal))
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                Text(tempVal >= 38.0 ? "HOT" : (tempVal >= 35.0 ? "WARM" : (tempVal < 30.0 ? "COOL" : "NORMAL")))
                                    .font(.system(size: 7.5, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 1)
                                    .background(tipCol.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            if let bPct = hPt.batteryPct as Double? {
                                Text(String(format: "Battery: %.0f%% • %@", bPct, (hPt.isCharging == true ? "Charging" : "Discharging")))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.88))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(tempVal >= 35.0 ? tipCol.opacity(0.5) : Color.white.opacity(0.18), lineWidth: 1)
                                 )
                                .shadow(color: Color.black.opacity(0.6), radius: 6, y: 3)
                        )
                        .position(x: tipX, y: tipY)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.25))
                        Text(isSingleDay ? "No temperature logs recorded for this day." : "No temperature logs in this timeframe.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Real readings are recorded automatically when device is connected.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .position(x: padL + plotW / 2, y: padT + plotH / 2)
                }

                // X-Axis Time / Date Labels
                if isSingleDay {
                    HStack {
                        Text("00:00").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                        Spacer()
                        Text("06:00").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                        Spacer()
                        Text("12:00").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                        Spacer()
                        Text("18:00").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                        Spacer()
                        Text("24:00").font(.system(size: 8.5, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, padL)
                    .position(x: padL + plotW / 2, y: padT + plotH + 12)
                } else if !validPoints.isEmpty {
                    HStack {
                        Text(formatXDate(Date(timeIntervalSince1970: minT)))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                        Spacer()
                        Text(formatXDate(Date(timeIntervalSince1970: maxT)))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, padL)
                    .position(x: padL + plotW / 2, y: padT + plotH + 12)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !validPoints.isEmpty else { return }
                switch phase {
                case .active(let location):
                    let locX = location.x
                    guard locX >= padL && locX <= padL + plotW else {
                        self.hoveredPoint = nil
                        self.hoverXLocation = nil
                        return
                    }
                    let ratio = Double((locX - padL) / plotW)
                    let targetT = minT + ratio * (maxT - minT)
                    if let closest = validPoints.min(by: { abs($0.date.timeIntervalSince1970 - targetT) < abs($1.date.timeIntervalSince1970 - targetT) }) {
                        let closestX = padL + CGFloat((closest.date.timeIntervalSince1970 - minT) / (maxT - minT)) * plotW
                        withAnimation(.easeOut(duration: 0.08)) {
                            self.hoveredPoint = closest
                            self.hoverXLocation = closestX
                        }
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.hoveredPoint = nil
                        self.hoverXLocation = nil
                    }
                }
            }
        }
    }

    private func formatXDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    private func formatTooltipDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - Extracted Component: Modern Data Table Row
struct ModernDataTableRowView: View {
    let index: Int
    let pt: BatteryHistoryPoint
    let isHovered: Bool
    let activeDeviceModel: String?
    let activeDeviceName: String?
    let onHover: (Bool) -> Void

    private func healthColor(_ h: Double) -> Color {
        h >= 90 ? Color(hex: "#30D158") : (h >= 80 ? Color(hex: "#FFD60A") : Color(hex: "#FF453A"))
    }

    private func formatDateCoconut(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f.string(from: d)
    }

    private var capacityText: String {
        if let fcc = pt.fullChargeMah { return "\(fcc) mAh" }
        if let cap = pt.capacityMah { return "\(cap) mAh" }
        return "–"
    }

    private var modelText: String {
        if let m = pt.deviceModel { return m }
        if pt.deviceId == "local_mac" || pt.deviceType == .mac { return "MacBookAir10,1" }
        return activeDeviceModel ?? "iPhone 17 Pro"
    }

    private var nameText: String {
        if let n = pt.deviceName { return n }
        if pt.deviceId == "local_mac" || pt.deviceType == .mac { return "MacBook Air M1" }
        return activeDeviceName ?? "iPhone"
    }

    private var serialText: String {
        if let s = pt.deviceSerial {
            return s.count > 10 ? "\(s.prefix(10))…" : s
        }
        if let b = pt.batterySerial {
            return "\(b.prefix(8))…"
        }
        return "–"
    }

    var body: some View {
        HStack(spacing: 0) {
            // 1. Date & Time (135pt)
            HStack(spacing: 5) {
                Circle()
                    .fill(pt.healthPct.map { healthColor($0) } ?? Color(hex: "#0A84FF"))
                    .frame(width: 5, height: 5)
                Text(formatDateCoconut(pt.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
            }
            .frame(width: 135, alignment: .leading)
            .padding(.leading, 14)

            // 2. Temp (65pt, centered pill)
            tempPill

            // 3. Cycles (50pt, centered)
            Text(pt.cycleCount.map { "\($0)" } ?? "–")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 50, alignment: .center)

            // 4. Health (65pt, centered pill)
            healthPill

            // 5. Max Capacity (100pt)
            Text(capacityText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 100, alignment: .leading)

            // 6. Model (115pt)
            Text(modelText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 115, alignment: .leading)

            // 7. Device Name (130pt)
            Text(nameText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            // 8. OS Version (55pt)
            Text(pt.osVersion ?? "–")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 55, alignment: .leading)

            // 9. Serial Number (110pt)
            Text(serialText)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 110, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .background(
            isHovered ? Color.white.opacity(0.08) :
            (index % 2 == 0 ? Color.white.opacity(0.015) : Color.clear)
        )
        .onHover { hover in
            onHover(hover)
        }
    }

    @ViewBuilder
    private var tempPill: some View {
        if let t = pt.temperatureC {
            let col = temperatureColor(t)
            HStack(spacing: 2.5) {
                Image(systemName: t >= 35.0 ? "flame.fill" : "thermometer.medium")
                    .font(.system(size: 7.5, weight: .bold))
                Text(String(format: "%.1f°", t))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(col)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(col.opacity(0.15))
            .clipShape(Capsule())
            .frame(width: 65, alignment: .center)
        } else {
            Text("–").font(.system(size: 10.5)).foregroundColor(.white.opacity(0.3)).frame(width: 65, alignment: .center)
        }
    }

    @ViewBuilder
    private var healthPill: some View {
        if let h = pt.healthPct {
            let col = healthColor(h)
            Text(String(format: "%.1f%%", h))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(col)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(col.opacity(0.12))
                .clipShape(Capsule())
                .frame(width: 65, alignment: .center)
        } else {
            Text("–").font(.system(size: 11)).foregroundColor(.white.opacity(0.3)).frame(width: 65, alignment: .center)
        }
    }
}

// MARK: - Extracted Component: Daily Temperature Table Row
struct DailyTempTableRowView: View {
    let index: Int
    let item: BatteryHistoryChartView.DailyTemperatureEntry
    let isRowSelected: Bool
    let onSelect: () -> Void

    private func formatDayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM yyyy"
        return f.string(from: d)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Day & Date
                HStack(spacing: 5) {
                    Circle()
                        .fill(temperatureColor(item.avgTemp))
                        .frame(width: 5, height: 5)
                    Text(formatDayLabel(item.date))
                        .font(.system(size: 11, weight: isRowSelected ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isRowSelected ? Color(hex: "#64D2FF") : .white.opacity(0.95))
                }
                .frame(width: 140, alignment: .leading)
                .padding(.leading, 14)

                // Readings
                Text("\(item.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 80, alignment: .center)

                // Min Temp
                Text(String(format: "%.1f°C", item.minTemp))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(temperatureColor(item.minTemp))
                    .frame(width: 85, alignment: .center)

                // Avg Temp
                Text(String(format: "%.1f°C", item.avgTemp))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(temperatureColor(item.avgTemp))
                    .frame(width: 85, alignment: .center)

                // Max Temp
                Text(String(format: "%.1f°C", item.maxTemp))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(temperatureColor(item.maxTemp))
                    .frame(width: 85, alignment: .center)

                // Thermal Range Bar
                thermalRangeBar
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 10)

                // Status Badge
                statusBadge
                    .frame(width: 95, alignment: .center)
            }
            .padding(.vertical, 5.5)
            .background(
                isRowSelected ?
                    Color(hex: "#64D2FF").opacity(0.12) :
                    (index % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)
            )
            .overlay(
                Rectangle()
                    .stroke(isRowSelected ? Color(hex: "#64D2FF").opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var thermalRangeBar: some View {
        GeometryReader { rangeGeo in
            let barW = rangeGeo.size.width
            let minNorm = CGFloat(max(0, min(1, (item.minTemp - 15.0) / 30.0)))
            let maxNorm = CGFloat(max(0, min(1, (item.maxTemp - 15.0) / 30.0)))
            let leftX = minNorm * barW
            let width = max(4, (maxNorm - minNorm) * barW)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#30D158"), item.hasOverheat ? Color(hex: "#FF453A") : Color(hex: "#FFD60A")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width, height: 6)
                    .offset(x: leftX)
            }
            .frame(height: rangeGeo.size.height)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.hasOverheat {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").font(.system(size: 7.5))
                Text("HOT >35°C").font(.system(size: 8.5, weight: .heavy))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(hex: "#FF453A"))
            .clipShape(Capsule())
        } else {
            Text("NORMAL")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Color(hex: "#30D158"))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(hex: "#30D158").opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

struct BatteryHistoryChartView: View {
    @ObservedObject var vm: BatteryWidgetViewModel
    var onClose: (() -> Void)? = nil
    @State private var selectedDevId: String
    @State private var activeTab: HistTab = .graph
    @State private var importError: String? = nil
    @State private var exportSuccess: Bool = false
    @State private var hoveredRowIndex: Int? = nil
    @State private var showHealthGraph: Bool = true
    @State private var showCyclesGraph: Bool = true
    @State private var showCapacityGraph: Bool = true
    @State private var aggregateDaily: Bool = true
    @State private var sortAscending: Bool = false
    @State private var compareWithOldiPhone: Bool = false
    @Environment(\.dismiss) var dismiss

    enum HistTab: String, CaseIterable {
        case graph     = "Charts & Health"
        case tempChart = "Daily Temperature"
        case lidSessions = "Lid Sessions"
        case monthly   = "Monthly Evolution"
        case allRows   = "Snapshot Database"
        case settings  = "Settings"
    }

    enum TempChartSection: String, CaseIterable {
        case today     = "Today"
        case yesterday = "Yesterday"
        case last7     = "Last 7 Days"
        case last30    = "Last 30 Days"
        case all       = "All History"
    }

    @State private var selectedTempSection: TempChartSection = .today
    @State private var selectedCustomDateKey: String? = nil

    init(vm: BatteryWidgetViewModel, onClose: (() -> Void)? = nil) {
        self.vm = vm
        self.onClose = onClose
        let initialId: String
        if vm.selectedDeviceId == "all" {
            initialId = vm.devices.first(where: { $0.deviceType == .mac })?.id ?? (vm.devices.first?.id ?? "local_mac")
        } else {
            initialId = vm.selectedDeviceId
        }
        _selectedDevId = State(initialValue: initialId)
    }

    private var historyDevices: [DeviceBatteryData] {
        var list: [DeviceBatteryData] = []
        
        // 1. All live / online devices (strictly 1 Mac and 1 iPhone 17 Pro)
        for dev in vm.devices {
            let isPhone17 = dev.deviceType != .mac && !dev.deviceId.contains("26cc71869") && !dev.deviceName.contains("15")
            let isMac = dev.deviceType == .mac || dev.deviceId == "local_mac"
            
            if isMac {
                if !list.contains(where: { $0.deviceType == .mac || $0.deviceId == "local_mac" }) {
                    list.append(dev)
                }
            } else if isPhone17 {
                if !list.contains(where: { $0.deviceType != .mac && !$0.deviceId.contains("26cc71869") && !$0.deviceName.contains("15") }) {
                    list.append(dev)
                }
            } else if !list.contains(where: { $0.id == dev.id || $0.deviceId == dev.deviceId }) {
                list.append(dev)
            }
        }
        
        // 2. Discover any additional offline devices (e.g. Old iPhone 15) from real history snapshots
        let hasPhone17 = list.contains(where: { $0.deviceType != .mac && !$0.deviceId.contains("26cc71869") && !$0.deviceName.contains("15") })
        let distinctHistoryIds = Set(vm.historyPoints.map { $0.deviceId })
        
        for devId in distinctHistoryIds {
            let pts = vm.historyPoints.filter { $0.deviceId == devId }.sorted(by: { $0.date < $1.date })
            guard let lastPt = pts.last else { continue }
            let devType = lastPt.deviceType ?? (lastPt.deviceId == "local_mac" ? .mac : .iphone)
            let isPhone17 = devType != .mac && !lastPt.deviceId.contains("26cc71869") && !(lastPt.deviceName?.contains("15") ?? false)
            let isMac = devType == .mac || lastPt.deviceId == "local_mac"
            
            if isMac && list.contains(where: { $0.deviceType == .mac || $0.deviceId == "local_mac" }) {
                continue
            }
            if isPhone17 && hasPhone17 {
                continue
            }
            if list.contains(where: { $0.deviceId == devId }) {
                continue
            }
            
            let cap = lastPt.batteryPct
            let fcc = lastPt.fullChargeMah
            let remMah = (fcc != nil) ? Int((cap / 100.0) * Double(fcc!)) : lastPt.capacityMah
            
            list.append(DeviceBatteryData(
                deviceId: lastPt.deviceId,
                deviceName: cleanDeviceDisplayName(lastPt.deviceName, fallback: devType == .mac ? "MacBook Air M1" : "iPhone"),
                deviceType: devType,
                isConnected: false,
                isWirelesslyConnected: false,
                capacityInt: Int(cap),
                capacityExact: cap,
                isCharging: lastPt.isCharging ?? false,
                isFullyCharged: cap >= 100.0,
                isACConnected: lastPt.isACConnected ?? (devType == .mac),
                cycleCount: lastPt.cycleCount,
                batteryHealthPct: lastPt.healthPct,
                voltageMv: nil,
                amperageMa: 0,
                chargingWatts: lastPt.chargingWatts,
                ratePctPerHour: nil,
                temperatureC: lastPt.temperatureC,
                timeRemainingMins: nil,
                remainingMah: remMah,
                fullChargeMah: fcc,
                designCapacityMah: lastPt.designCapacityMah,
                totalDiskBytes: nil,
                freeDiskBytes: nil,
                batteryManufactureDate: lastPt.batteryManufactureDate,
                deviceManufactureDate: lastPt.deviceManufactureDate,
                firstUseDate: lastPt.firstUseDate,
                modelReleaseDate: nil,
                lastSeenAt: lastPt.date,
                processor: nil,
                hardwareModel: lastPt.deviceModel,
                serialNumber: lastPt.deviceSerial ?? lastPt.deviceId,
                fetchedAt: lastPt.date
            ))
        }
        return list
    }

    private var activeDevice: DeviceBatteryData? {
        historyDevices.first(where: { $0.id == selectedDevId }) ?? historyDevices.first
    }

    private var sevenDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-7*86400)
    }

    private func pointsFor(_ dev: DeviceBatteryData) -> [BatteryHistoryPoint] {
        if dev.deviceType == .mac || dev.deviceId == "local_mac" {
            return vm.historyPoints.filter { pt in
                pt.deviceId == "local_mac" || pt.deviceType == .mac || (pt.deviceModel?.lowercased().contains("mac") ?? false)
            }
        } else if dev.deviceId.contains("26cc71869") || dev.deviceName.contains("15") {
            // iPhone 15 (Old)
            return vm.historyPoints.filter { pt in
                pt.deviceId.contains("26cc71869") || (pt.deviceName?.contains("15") ?? false)
            }
        } else {
            // iPhone 17 Pro
            return vm.historyPoints.filter { pt in
                if pt.deviceType == .mac || pt.deviceId == "local_mac" { return false }
                if pt.deviceId.contains("26cc71869") || (pt.deviceName?.contains("15") ?? false) { return false }
                return true
            }
        }
    }

    private var matchedPoints: [BatteryHistoryPoint] {
        guard let dev = activeDevice else { return vm.historyPoints }
        return pointsFor(dev)
    }

    private var dailyAveragedPoints: [BatteryHistoryPoint] {
        let cal = Calendar.current
        var groups: [String: [BatteryHistoryPoint]] = [:]
        
        for pt in matchedPoints {
            let key = String(format: "%04d-%02d-%02d",
                             cal.component(.year, from: pt.date),
                             cal.component(.month, from: pt.date),
                             cal.component(.day, from: pt.date))
            groups[key, default: []].append(pt)
        }

        var result: [BatteryHistoryPoint] = []
        for (_, pts) in groups {
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                result.append(first)
                continue
            }

            // Average health %
            let healths = pts.compactMap { $0.healthPct }
            let avgHealth = healths.isEmpty ? first.healthPct : (healths.reduce(0, +) / Double(healths.count))

            // Max cycles recorded on that day
            let cycles = pts.compactMap { $0.cycleCount }
            let maxCycles = cycles.max() ?? first.cycleCount

            // Average or latest capacity
            let caps = pts.compactMap { $0.fullChargeMah }
            let avgCap = caps.isEmpty ? first.fullChargeMah : Int(Double(caps.reduce(0, +)) / Double(caps.count))

            let temps = pts.compactMap { $0.temperatureC }
            let avgTemp = temps.isEmpty ? first.temperatureC : (temps.reduce(0, +) / Double(temps.count))

            let latest = pts.max(by: { $0.date < $1.date }) ?? first

            result.append(BatteryHistoryPoint(
                deviceId: first.deviceId,
                deviceName: first.deviceName,
                deviceType: first.deviceType,
                date: latest.date,
                batteryPct: latest.batteryPct,
                healthPct: avgHealth,
                cycleCount: maxCycles,
                capacityMah: avgCap,
                fullChargeMah: avgCap,
                designCapacityMah: first.designCapacityMah,
                temperatureC: avgTemp,
                batteryManufactureDate: first.batteryManufactureDate,
                deviceManufactureDate: first.deviceManufactureDate,
                firstUseDate: first.firstUseDate,
                isCharging: latest.isCharging,
                isACConnected: latest.isACConnected,
                chargingWatts: latest.chargingWatts,
                deviceModel: first.deviceModel,
                osVersion: latest.osVersion,
                appVersion: latest.appVersion,
                batterySerial: first.batterySerial,
                deviceSerial: first.deviceSerial
            ))
        }

        return result
    }

    private var allMatchedSorted: [BatteryHistoryPoint] {
        sortAscending
            ? matchedPoints.sorted(by: { $0.date < $1.date })
            : matchedPoints.sorted(by: { $0.date > $1.date })
    }

    private var displayedPoints: [BatteryHistoryPoint] {
        let base = aggregateDaily ? dailyAveragedPoints : matchedPoints
        return sortAscending
            ? base.sorted(by: { $0.date < $1.date })
            : base.sorted(by: { $0.date > $1.date })
    }

    private var graphPoints: [BatteryHistoryPoint] {
        allMatchedSorted
    }

    private var deviceHistoryPoints: [BatteryHistoryPoint] {
        matchedPoints.filter { $0.date >= sevenDaysAgo }.sorted(by: { $0.date < $1.date })
    }

    struct DailyTemperatureEntry: Identifiable {
        var id: String { dateKey }
        let dateKey: String
        let date: Date
        let minTemp: Double
        let avgTemp: Double
        let maxTemp: Double
        let count: Int
        let hasOverheat: Bool
    }

    private var dailyTemperatureArchives: [DailyTemperatureEntry] {
        let cal = Calendar.current
        var groups: [String: [BatteryHistoryPoint]] = [:]
        for pt in matchedPoints.filter({ $0.temperatureC != nil }) {
            let key = String(format: "%04d-%02d-%02d",
                             cal.component(.year, from: pt.date),
                             cal.component(.month, from: pt.date),
                             cal.component(.day, from: pt.date))
            groups[key, default: []].append(pt)
        }

        var list: [DailyTemperatureEntry] = []
        for (key, pts) in groups {
            let temps = pts.compactMap { $0.temperatureC }
            guard !temps.isEmpty,
                  let latest = pts.max(by: { $0.date < $1.date }),
                  let minT = temps.min(),
                  let maxT = temps.max() else { continue }
            let avgT = temps.reduce(0, +) / Double(temps.count)
            let isHot = maxT >= 35.0
            list.append(DailyTemperatureEntry(
                dateKey: key,
                date: latest.date,
                minTemp: minT,
                avgTemp: avgT,
                maxTemp: maxT,
                count: temps.count,
                hasOverheat: isHot
            ))
        }
        return list.sorted(by: { $0.date > $1.date })
    }

    struct MonthlyArchiveEntry: Identifiable {
        var id: String { period }
        let period: String
        let healthPct: Double
        let cycles: Int
        let isReal: Bool
    }

    private var monthlyArchives: [MonthlyArchiveEntry] {
        guard let dev = activeDevice else { return [] }
        let cal = Calendar.current
        var realByMonth: [String: (healths: [Double], cycles: [Int])] = [:]
        for pt in matchedPoints {
            let pStr = String(format: "%04d-%02d", cal.component(.year, from: pt.date), cal.component(.month, from: pt.date))
            if realByMonth[pStr] == nil { realByMonth[pStr] = (healths: [], cycles: []) }
            if let h = pt.healthPct { realByMonth[pStr]?.healths.append(h) }
            if let c = pt.cycleCount { realByMonth[pStr]?.cycles.append(c) }
        }
        var result: [MonthlyArchiveEntry] = []
        for (p, data) in realByMonth {
            let avgH = data.healths.isEmpty ? (dev.batteryHealthPct ?? 100.0) : (data.healths.reduce(0, +) / Double(data.healths.count))
            let maxC = data.cycles.isEmpty ? (dev.cycleCount ?? 0) : (data.cycles.max() ?? 0)
            result.append(MonthlyArchiveEntry(period: p, healthPct: avgH, cycles: maxC, isReal: true))
        }
        return result.sorted(by: { $0.period > $1.period })
    }

    private var fullChargeEvents: [BatteryHistoryPoint] {
        deviceHistoryPoints.filter { $0.batteryPct >= 99.0 }.sorted(by: { $0.date > $1.date })
    }

    // MARK: - Main Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Modern Floating Title Bar ──
            HStack(spacing: 12) {
                // Device Icon & Badge
                if let dev = activeDevice {
                    Image(systemName: dev.deviceType.iconName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(hex: "#0A84FF"))
                        .frame(width: 32, height: 32)
                        .background(Color(hex: "#0A84FF").opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Settings & Battery Archive")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        if let dev = activeDevice {
                            Text("• \(dev.deviceName)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    Text("\(allMatchedSorted.count) snapshots indexed • Auto-synced across logs")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }
                
                Spacer()

                // Modern Pill Actions
                HStack(spacing: 8) {
                    Button(action: importBackup) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Import")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: exportCSV) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Export CSV")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(Color(hex: "#30D158"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#30D158").opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: { onClose?(); dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Notifications Banner
            if let err = importError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(Color(hex: "#FF453A"))
                    Text(err).font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "#FF453A"))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            if exportSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: "#30D158"))
                    Text("Exported CSV successfully to ~/Documents!").font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "#30D158"))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }

            // ── Device Switcher & Segments ──
            HStack {
                // Device Segments
                HStack(spacing: 8) {
                    ForEach(historyDevices) { dev in
                        let count = pointsFor(dev).count

                        Button(action: { selectedDevId = dev.id }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Image(systemName: dev.deviceType.iconName)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(selectedDevId == dev.id ? .white : .white.opacity(0.75))
                                    Text(dev.deviceName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(selectedDevId == dev.id ? .white : .white.opacity(0.85))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                
                                Text("\(count) points")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(selectedDevId == dev.id ? .white.opacity(0.85) : .white.opacity(0.45))
                                    .padding(.leading, 15)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedDevId == dev.id ? Color(hex: "#0A84FF") : Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedDevId == dev.id ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
                            )
                            .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Tab Switcher
                HStack(spacing: 2) {
                    ForEach(HistTab.allCases, id: \.self) { tab in
                        Button(action: { activeTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: activeTab == tab ? .bold : .medium))
                                .foregroundColor(activeTab == tab ? .white : .white.opacity(0.55))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(activeTab == tab ? Color.white.opacity(0.14) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            // ── Content Area ──
            Group {
                switch activeTab {
                case .allRows:
                    modernDataTable
                case .tempChart:
                    ScrollView(.vertical, showsIndicators: true) {
                        dailyTemperatureView
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                case .lidSessions:
                    ScrollView(.vertical, showsIndicators: true) {
                        lidSessionsFullView
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                case .monthly:
                    ScrollView(.vertical, showsIndicators: true) {
                        monthlyView
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                case .graph:
                    ScrollView(.vertical, showsIndicators: true) {
                        graphView
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                case .settings:
                    ScrollView(.vertical, showsIndicators: true) {
                        settingsView
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                }
            }
        }
        .frame(width: 900, height: 640)
        .background(
            ZStack {
                // Glassmorphism deep background
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "#161618").opacity(0.96))
                
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
    }

    // MARK: - Modern Polished Data Table (Strict Grid Alignment, No Data Version Column)

    @ViewBuilder
    private var modernDataTable: some View {
        VStack(spacing: 0) {
            modernDataTableSubheader
            Divider().background(Color.white.opacity(0.06))
            modernDataTableHeader
            Divider().background(Color.white.opacity(0.08))

            if displayedPoints.isEmpty {
                modernDataTableEmpty
            } else {
                modernDataTableContent
            }
        }
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var modernDataTableSubheader: some View {
        HStack {
            Text(aggregateDaily ? "Showing \(displayedPoints.count) daily averaged snapshots (1 per day)" : "Showing all \(allMatchedSorted.count) raw snapshots")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            
            Spacer()

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { aggregateDaily.toggle() } }) {
                HStack(spacing: 5) {
                    Image(systemName: aggregateDaily ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(aggregateDaily ? Color(hex: "#0A84FF") : .white.opacity(0.4))
                    Text("1 per day (Daily Average)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(aggregateDaily ? .white : .white.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(aggregateDaily ? Color(hex: "#0A84FF").opacity(0.2) : Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
    }

    private var modernDataTableHeader: some View {
        HStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sortAscending.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Text("Date & Time")
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(Color(hex: "#0A84FF"))
                }
                .foregroundColor(Color(hex: "#0A84FF"))
                .frame(width: 135, alignment: .leading)
                .padding(.leading, 14)
            }
            .buttonStyle(.plain)

            Text("Temp")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 65, alignment: .center)

            Text("Cycles")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 50, alignment: .center)

            Text("Health")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 65, alignment: .center)

            Text("Max Capacity")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 100, alignment: .leading)

            Text("Device Model")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 115, alignment: .leading)

            Text("Device Name")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 130, alignment: .leading)

            Text("OS")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 55, alignment: .leading)

            Text("Device Serial")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                .frame(width: 110, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private var modernDataTableEmpty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "archivebox").font(.system(size: 32)).foregroundColor(.white.opacity(0.2))
            Text("No snapshots recorded yet.").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modernDataTableContent: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedPoints.enumerated()), id: \.element.id) { index, pt in
                    ModernDataTableRowView(
                        index: index,
                        pt: pt,
                        isHovered: hoveredRowIndex == index,
                        activeDeviceModel: activeDevice?.hardwareModel,
                        activeDeviceName: activeDevice?.deviceName,
                        onHover: { hover in
                            if hover { hoveredRowIndex = index }
                            else if hoveredRowIndex == index { hoveredRowIndex = nil }
                        }
                    )
                }
            }
        }
    }

    private var currentTempTimeRange: (start: Date, end: Date, isSingleDay: Bool, title: String) {
        let cal = Calendar.current
        let now = Date()

        if let customKey = selectedCustomDateKey {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: customKey) {
                let s = cal.startOfDay(for: d)
                let e = s.addingTimeInterval(86400)
                let titleFmt = DateFormatter()
                titleFmt.dateFormat = "EEEE, d MMM yyyy"
                return (s, e, true, titleFmt.string(from: d))
            }
        }

        switch selectedTempSection {
        case .today:
            let s = cal.startOfDay(for: now)
            let e = s.addingTimeInterval(86400)
            return (s, e, true, "Today (Full 24h Timeline)")
        case .yesterday:
            let yest = cal.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86400)
            let s = cal.startOfDay(for: yest)
            let e = s.addingTimeInterval(86400)
            return (s, e, true, "Yesterday (Full 24h Timeline)")
        case .last7:
            let s = cal.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7*86400)
            return (s, now, false, "Last 7 Days")
        case .last30:
            let s = cal.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30*86400)
            return (s, now, false, "Last 30 Days")
        case .all:
            let allT = matchedPoints.filter { $0.temperatureC != nil }
            let s = allT.first?.date ?? now.addingTimeInterval(-86400)
            return (s, now, false, "All Logged History")
        }
    }

    private var pointsForCurrentTempSection: [BatteryHistoryPoint] {
        let range = currentTempTimeRange
        return matchedPoints.filter { pt in
            guard pt.temperatureC != nil else { return false }
            return pt.date >= range.start && pt.date <= range.end
        }.sorted(by: { $0.date < $1.date })
    }

    // MARK: - Daily Temperature Tab

    @ViewBuilder
    private var dailyTemperatureView: some View {
        if let dev = activeDevice {
            let range = currentTempTimeRange
            let sectionPoints = pointsForCurrentTempSection
            let temps = sectionPoints.compactMap { $0.temperatureC }

            VStack(spacing: 12) {
                tempTimeframeSelectorBar
                tempChartCard(range: range, sectionPoints: sectionPoints, temps: temps, dev: dev)
                dailyTempTable
            }
        }
    }

    private var tempTimeframeSelectorBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(TempChartSection.allCases, id: \.self) { section in
                    let isSelected = (selectedCustomDateKey == nil && selectedTempSection == section)
                    tempSectionButton(section: section, isSelected: isSelected)
                }
            }

            Spacer()

            if let customKey = selectedCustomDateKey {
                HStack(spacing: 4) {
                    Text("Day: \(customKey)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "#64D2FF"))
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.selectedCustomDateKey = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(hex: "#64D2FF").opacity(0.18))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(hex: "#64D2FF").opacity(0.4), lineWidth: 1))
            }
        }
        .padding(.horizontal, 4)
    }

    private func tempSectionButton(section: TempChartSection, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                self.selectedCustomDateKey = nil
                self.selectedTempSection = section
            }
        } label: {
            Text(section.rawValue)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? Color.white : Color.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ?
                        Color(hex: "#FF9F0A").opacity(0.28) :
                        Color.white.opacity(0.04)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color(hex: "#FF9F0A").opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    typealias TempTimeRange = (start: Date, end: Date, isSingleDay: Bool, title: String)

    private func tempChartCard(range: TempTimeRange, sectionPoints: [BatteryHistoryPoint], temps: [Double], dev: DeviceBatteryData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(range.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        if range.isSingleDay {
                            Text("24H VIEW")
                                .font(.system(size: 8.5, weight: .heavy))
                                .foregroundColor(Color(hex: "#FF9F0A"))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color(hex: "#FF9F0A").opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("\(sectionPoints.count) recorded snapshot\(sectionPoints.count == 1 ? "" : "s") • 35°C thermal alert threshold")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                if !temps.isEmpty, let minTemp = temps.min(), let maxTemp = temps.max() {
                    let avgTemp = temps.reduce(0, +) / Double(temps.count)
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Avg:")
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.45))
                            Text(String(format: "%.1f°C", avgTemp))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(temperatureColor(avgTemp))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())

                        HStack(spacing: 4) {
                            Text("Max:")
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.45))
                            Text(String(format: "%.1f°C", maxTemp))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(temperatureColor(maxTemp))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(temperatureColor(maxTemp).opacity(0.15))
                        .clipShape(Capsule())

                        HStack(spacing: 4) {
                            Text("Min:")
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.45))
                            Text(String(format: "%.1f°C", minTemp))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(temperatureColor(minTemp))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                } else if let curT = dev.temperatureC {
                    HStack(spacing: 4) {
                        Text("Live:")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.45))
                        Text(String(format: "%.1f°C", curT))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(temperatureColor(curT))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
            }

            DailyTemperatureGraphCanvas(
                points: sectionPoints,
                fixedMinTime: range.isSingleDay ? range.start.timeIntervalSince1970 : nil,
                fixedMaxTime: range.isSingleDay ? range.end.timeIntervalSince1970 : nil,
                isSingleDay: range.isSingleDay
            )
            .frame(height: 180)
            .background(Color.black.opacity(0.3).cornerRadius(10))
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var dailyTempTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Day & Date")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(.white)
                    .frame(width: 140, alignment: .leading).padding(.leading, 14)
                Text("Readings")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(.white.opacity(0.7))
                    .frame(width: 80, alignment: .center)
                Text("Min Temp")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(Color(hex: "#64D2FF"))
                    .frame(width: 85, alignment: .center)
                Text("Avg Temp")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(Color(hex: "#30D158"))
                    .frame(width: 85, alignment: .center)
                Text("Max Temp")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(Color(hex: "#FFD60A"))
                    .frame(width: 85, alignment: .center)
                Text("Thermal Range")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Status")
                    .font(.system(size: 11.5, weight: .bold)).foregroundColor(.white.opacity(0.7))
                    .frame(width: 95, alignment: .center)
            }
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))

            Divider().background(Color.white.opacity(0.08))

            if dailyTemperatureArchives.isEmpty {
                VStack(spacing: 6) {
                    Text("No temperature logs found.").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                }
                .padding(20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dailyTemperatureArchives.enumerated()), id: \.element.id) { index, item in
                        DailyTempTableRowView(
                            index: index,
                            item: item,
                            isRowSelected: selectedCustomDateKey == item.dateKey,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if self.selectedCustomDateKey == item.dateKey {
                                        self.selectedCustomDateKey = nil
                                    } else {
                                        self.selectedCustomDateKey = item.dateKey
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func formatDayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM yyyy"
        return f.string(from: d)
    }

    // MARK: - Monthly Summary Tab

    @ViewBuilder
    private var monthlyView: some View {
        if let dev = activeDevice {
            let modelName: String = dev.hardwareModel ?? (dev.deviceType == .mac ? "MacBook Air" : "iPhone")
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    Text("Date Period")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                    Text("Average Health")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                        .frame(width: 120, alignment: .center)
                    Text("Cycle Count")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                        .frame(width: 100, alignment: .center)
                }
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.06))

                // Subheader
                HStack {
                    Text("\(dev.deviceName) • \(modelName)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text("\(monthlyArchives.count) months documented")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Color.white.opacity(0.02))

                Divider().background(Color.white.opacity(0.08))

                VStack(spacing: 0) {
                    ForEach(Array(monthlyArchives.enumerated()), id: \.element.id) { index, item in
                        monthlyTableRow(index: index, item: item)
                    }
                }
            }
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))

            // Hardware profile card
            archiveProfileCard(dev: dev)
        }
    }

    private func monthlyTableRow(index: Int, item: MonthlyArchiveEntry) -> some View {
        HStack(spacing: 0) {
            Text(item.period)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(item.isReal ? .white.opacity(0.95) : .white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18)

            Text(String(format: "%.0f%%", item.healthPct))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(item.isReal ? healthColor(item.healthPct) : .white.opacity(0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(item.isReal ? healthColor(item.healthPct).opacity(0.12) : Color.clear)
                .clipShape(Capsule())
                .frame(width: 120, alignment: .center)

            Text("\(item.cycles)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(item.isReal ? .white.opacity(0.95) : .white.opacity(0.35))
                .frame(width: 100, alignment: .center)
        }
        .padding(.vertical, 6)
        .background(index % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)
    }

    // MARK: - Graph View (Multi-Year Degradation Curve with Interactive Toggles)

    @ViewBuilder
    private var graphView: some View {
        VStack(spacing: 12) {
            // Interactive Degradation Chart Card
            VStack(alignment: .leading, spacing: 10) {
                graphCardHeader

                // Degradation Canvas (Uses all matched snapshots + baseline for rich continuous trajectory)
                let comparisonList: [BatteryHistoryPoint] = (compareWithOldiPhone && (activeDevice?.deviceName.contains("17") == true || activeDevice?.hardwareModel?.contains("17") == true)) ? vm.historyPoints.filter { $0.deviceId.contains("26cc71869") || ($0.deviceName?.contains("15") ?? false) } : []
                BatteryDegradationGraphCanvas(
                    points: graphPoints,
                    showHealth: showHealthGraph,
                    showCycles: showCyclesGraph,
                    showCapacity: showCapacityGraph,
                    designCapacity: activeDevice?.designCapacityMah.map { Double($0) },
                    comparisonPoints: comparisonList,
                    comparisonLabel: "iPhone 15"
                )
                .frame(height: 170)
                .background(Color.black.opacity(0.3).cornerRadius(10))
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))

            // Hardware Chemistry Card
            if let dev = activeDevice {
                archiveProfileCard(dev: dev)
            }
        }
    }

    private var graphCardHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery Health Degradation Over Time")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                if let dev = activeDevice {
                    Text("Complete trajectory for \(dev.deviceName) from \(graphPoints.count) data points")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer()

            graphTogglePills
        }
    }

    private var graphTogglePills: some View {
        HStack(spacing: 6) {
            Button(action: { showHealthGraph.toggle() }) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "#30D158")).frame(width: 6, height: 6)
                    Text("Health %")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(showHealthGraph ? Color(hex: "#30D158").opacity(0.2) : Color.white.opacity(0.05))
                .foregroundColor(showHealthGraph ? Color(hex: "#30D158") : .white.opacity(0.4))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: { showCyclesGraph.toggle() }) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "#FFD60A")).frame(width: 6, height: 6)
                    Text("Cycles")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(showCyclesGraph ? Color(hex: "#FFD60A").opacity(0.2) : Color.white.opacity(0.05))
                .foregroundColor(showCyclesGraph ? Color(hex: "#FFD60A") : .white.opacity(0.4))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: { showCapacityGraph.toggle() }) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "#64D2FF")).frame(width: 6, height: 6)
                    Text("Capacity mAh")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(showCapacityGraph ? Color(hex: "#64D2FF").opacity(0.2) : Color.white.opacity(0.05))
                .foregroundColor(showCapacityGraph ? Color(hex: "#64D2FF") : .white.opacity(0.4))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if activeDevice?.deviceName.contains("17") == true || activeDevice?.hardwareModel?.contains("17") == true {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { compareWithOldiPhone.toggle() } }) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: "#CB64F4")).frame(width: 6, height: 6)
                        Text("Overlay iPhone 15")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(compareWithOldiPhone ? Color(hex: "#CB64F4").opacity(0.25) : Color.white.opacity(0.05))
                    .foregroundColor(compareWithOldiPhone ? Color(hex: "#CB64F4") : .white.opacity(0.5))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Profile Card

    @ViewBuilder
    private func archiveProfileCard(dev: DeviceBatteryData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: "#0A84FF"))
                Text("Hardware & Chemistry Health")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.95))
                Spacer()
                if let t = dev.temperatureC {
                    let col = temperatureColor(t)
                    HStack(spacing: 4) {
                        Image(systemName: t >= 35.0 ? "flame.fill" : "thermometer.medium")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.1f°C", t))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(col)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(col.opacity(0.12).cornerRadius(5))
                }
            }

            HStack(spacing: 12) {
                if let h = dev.batteryHealthPct {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Health Index").font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                        Text(String(format: "%.1f%%", h))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(healthColor(h))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let cc = dev.cycleCount {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cycles").font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                        Text("\(cc)").font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.95))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let fcc = dev.fullChargeMah, let dcap = dev.designCapacityMah {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capacity").font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                        Text("\(dcap) / \(fcc) mAh")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Export / Import

    private func exportCSV() {
        guard let dev = activeDevice else { return }
        let pts = allMatchedSorted
        var csv = "Date,Cycles,Health,MaximumCapacity,DeviceModel,DeviceName,OSVersion,BatterySerial,DeviceSerial\n"
        let df = ISO8601DateFormatter()
        for pt in pts {
            csv += "\(df.string(from: pt.date)),"
            csv += pt.cycleCount.map { "\($0)" } ?? ""
            csv += ","
            csv += pt.healthPct.map { String(format: "%.2f", $0) } ?? ""
            csv += ","
            csv += pt.fullChargeMah.map { "\($0)" } ?? (pt.capacityMah.map { "\($0)" } ?? "")
            csv += ","
            csv += "\(pt.deviceModel ?? ""),"
            csv += "\(pt.deviceName ?? dev.deviceName),"
            csv += "\(pt.osVersion ?? ""),"
            csv += "\(pt.batterySerial ?? ""),"
            csv += "\(pt.deviceSerial ?? "")\n"
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BatteryHistory_\(dev.deviceId.prefix(8)).csv")
        try? csv.write(to: path, atomically: true, encoding: .utf8)
        withAnimation { exportSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportSuccess = false }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .data, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Battery History Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        var parsedPoints: [BatteryHistoryPoint] = []
        if url.pathExtension == "ccba" || url.pathExtension == "ccbarchive" || url.path.contains("coconut") {
            if let pts = CoconutBatteryArchiveReader.parseCCBAFile(at: url), !pts.isEmpty {
                parsedPoints = pts
            }
        }
        
        if parsedPoints.isEmpty, let rawData = try? Data(contentsOf: url) {
            if let pts = try? JSONDecoder().decode([BatteryHistoryPoint].self, from: rawData) {
                parsedPoints = pts
            } else if let rawRecs = try? JSONDecoder().decode([CoconutBatteryArchiveReader.RawRecord].self, from: rawData) {
                parsedPoints = rawRecs.map { r in
                    let dtype: DeviceType = (r.deviceType == "mac") ? .mac : .iphone
                    return BatteryHistoryPoint(
                        deviceId: r.deviceId,
                        deviceName: r.deviceName,
                        deviceType: dtype,
                        date: Date(timeIntervalSince1970: r.timestamp),
                        batteryPct: r.batteryPct,
                        healthPct: r.healthPct,
                        cycleCount: r.cycleCount,
                        capacityMah: r.capacityMah,
                        fullChargeMah: r.fullChargeMah,
                        designCapacityMah: r.designCapacityMah,
                        temperatureC: r.temperatureC,
                        batteryManufactureDate: nil,
                        deviceManufactureDate: nil,
                        firstUseDate: nil,
                        isCharging: false,
                        isACConnected: dtype == .mac,
                        chargingWatts: nil,
                        deviceModel: r.deviceModel,
                        osVersion: r.osVersion,
                        appVersion: r.appVersion,
                        batterySerial: r.batterySerial,
                        deviceSerial: r.deviceSerial
                    )
                }
            }
        }
        
        if !parsedPoints.isEmpty {
            var existingKeys = Set(vm.historyPoints.map { "\($0.deviceId)_\(Int($0.date.timeIntervalSince1970))" })
            var added = 0
            for pt in parsedPoints {
                let k = "\(pt.deviceId)_\(Int(pt.date.timeIntervalSince1970))"
                if existingKeys.insert(k).inserted {
                    vm.historyPoints.append(pt)
                    added += 1
                }
            }
            vm.historyPoints.sort(by: { $0.date < $1.date })
            vm.savePersisted()
            importError = nil
            withAnimation { exportSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportSuccess = false }
            return
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Could not read file."; return
        }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else { importError = "File is empty."; return }
        let df = ISO8601DateFormatter()
        var imported: [BatteryHistoryPoint] = []
        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 3, let date = df.date(from: cols[0]) else { continue }
            let cycles = Int(cols[1])
            let health = Double(cols[2])
            let maxCap = cols.count > 3 ? Int(cols[3]) : nil
            let devModel = cols.count > 4 ? cols[4] : nil
            let devName = cols.count > 5 ? cols[5] : nil
            let osVer = cols.count > 6 ? cols[6] : nil
            let batSer = cols.count > 7 ? cols[7] : nil
            let devSer = cols.count > 8 ? cols[8] : nil

            imported.append(BatteryHistoryPoint(
                deviceId: activeDevice?.deviceId ?? "imported",
                deviceName: devName,
                deviceType: activeDevice?.deviceType ?? .mac,
                date: date,
                batteryPct: 100.0,
                healthPct: health,
                cycleCount: cycles,
                capacityMah: maxCap,
                fullChargeMah: maxCap,
                designCapacityMah: activeDevice?.designCapacityMah,
                temperatureC: nil,
                batteryManufactureDate: nil,
                deviceManufactureDate: nil,
                firstUseDate: nil,
                isCharging: false,
                isACConnected: true,
                chargingWatts: nil,
                deviceModel: devModel,
                osVersion: osVer,
                appVersion: nil,
                batterySerial: batSer,
                deviceSerial: devSer
            ))
        }
        guard !imported.isEmpty else { importError = "No valid rows found."; return }
        var existingKeys = Set(vm.historyPoints.map { "\($0.deviceId)_\(Int($0.date.timeIntervalSince1970))" })
        var added = 0
        for pt in imported {
            let k = "\(pt.deviceId)_\(Int(pt.date.timeIntervalSince1970))"
            if existingKeys.insert(k).inserted {
                vm.historyPoints.append(pt)
                added += 1
            }
        }
        vm.historyPoints.sort(by: { $0.date < $1.date })
        vm.savePersisted()
        importError = nil
        withAnimation { exportSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportSuccess = false }
    }

    // MARK: - Lid Sessions History Tab

    @ViewBuilder
    private var lidSessionsFullView: some View {
        VStack(spacing: 12) {
            lidSessionsSummaryCards
            lidSessionsTable
        }
    }

    private var lidSessionsSummaryCards: some View {
        HStack(spacing: 12) {
            // Card 1: First Lid Open
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#FF9F0A"))
                    Text("First Lid Open Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                Text(vm.firstLidOpenToday != nil ? formatTimeFull(vm.firstLidOpenToday!) : "--:--:--")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))

            // Card 2: Total Active Lid Time
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#30D158"))
                    Text("Total Screen / Lid Time")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                let sec = Int(vm.todayLidSessions.reduce(0) { $0 + $1.durationSeconds })
                let h = sec / 3600
                let m = (sec % 3600) / 60
                Text(h > 0 ? "\(h)h \(m)m" : "\(m)m")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#30D158"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))

            // Card 3: Session Count
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#0A84FF"))
                    Text("Today's Sessions")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                Text("\(vm.todayLidSessions.count) sessions")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private var lidSessionsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Session")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 80, alignment: .leading).padding(.leading, 14)
                Text("Lid Opened")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 140, alignment: .leading)
                Text("Lid Closed")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 140, alignment: .leading)
                Text("Duration")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 110, alignment: .leading)
                Text("Status")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 90, alignment: .center)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.08))

            if vm.todayLidSessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.2))
                    Text("No lid sessions logged for today yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.todayLidSessions.enumerated()), id: \.element.id) { idx, session in
                        lidSessionRow(idx: idx, session: session)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func lidSessionRow(idx: Int, session: LidSession) -> some View {
        HStack(spacing: 0) {
            Text("#\(idx + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 80, alignment: .leading)
                .padding(.leading, 14)

            Text(formatTimeFull(session.openDate))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 140, alignment: .leading)

            Text(session.closeDate != nil ? formatTimeFull(session.closeDate!) : "Currently Active")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(session.isActive ? Color(hex: "#30D158") : .white.opacity(0.7))
                .frame(width: 140, alignment: .leading)

            Text(session.durationString)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(session.isActive ? Color(hex: "#30D158") : .white.opacity(0.95))
                .frame(width: 110, alignment: .leading)

            HStack(spacing: 4) {
                Circle()
                    .fill(session.isActive ? Color(hex: "#30D158") : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(session.isActive ? "Active" : "Closed")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(session.isActive ? Color(hex: "#30D158") : .white.opacity(0.55))
            }
            .frame(width: 90, alignment: .center)

            Spacer()
        }
        .padding(.vertical, 7)
        .background(
            session.isActive ?
                Color(hex: "#30D158").opacity(0.06) :
                (idx % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)
        )
    }

    // MARK: - Consolidated Settings Tab

    @ViewBuilder
    private var settingsView: some View {
        VStack(spacing: 16) {
            settingsAppearanceCard
            settingsAudioCard
            settingsDatabaseCard
        }
    }

    private var settingsAppearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#0A84FF"))
                Text("Widget Appearance & Glass Transparency")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                let clearPct = (1.0 - vm.backgroundOpacity) * 100
                Text(clearPct >= 99.5 ? "100% (Ghost)" : String(format: "%.0f%% Clear", clearPct))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#30D158"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "#30D158").opacity(0.12))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Background Opacity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Slider(value: $vm.backgroundOpacity, in: 0.02...0.95)
                    .accentColor(Color(hex: "#30D158"))
            }

            HStack(spacing: 6) {
                Text("Quick Presets:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                presetButton(name: "Ghost (10%)", val: 0.10)
                presetButton(name: "Clear (28%)", val: 0.28)
                presetButton(name: "BigU (48%)", val: 0.48)
                presetButton(name: "Dark (75%)", val: 0.75)
                presetButton(name: "Solid (95%)", val: 0.95)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func presetButton(name: String, val: Double) -> some View {
        let isSelected = abs(vm.backgroundOpacity - val) < 0.06
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.backgroundOpacity = val
            }
        }) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color(hex: "#30D158").opacity(0.3) : Color.white.opacity(0.06))
                )
                .foregroundColor(isSelected ? Color.white : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private var settingsAudioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#30D158"))
                Text("Audio & Notification Feedback")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            // 1. 80% Charge Limit Ding (iPhone Only)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("80% Charge Limit Ding")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("Plays exclusively when connected iPhone or iPad reaches 80% charge")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    testAudioButton {
                        vm.play80PercentDingSound()
                    }
                    Toggle("", isOn: $vm.eightyPercentAlertEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#30D158")))
                        .labelsHidden()
                }

                if vm.eightyPercentAlertEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            Text("Chime:")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            audioOptionPill(title: "Glass", id: "glass", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "glass"
                                vm.play80PercentDingSound(theme: "glass")
                            }
                            audioOptionPill(title: "Hero", id: "hero", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "hero"
                                vm.play80PercentDingSound(theme: "hero")
                            }
                            audioOptionPill(title: "Tink", id: "tink", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "tink"
                                vm.play80PercentDingSound(theme: "tink")
                            }
                            audioOptionPill(title: "Bottle", id: "bottle", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "bottle"
                                vm.play80PercentDingSound(theme: "bottle")
                            }
                            audioOptionPill(title: "Pop", id: "pop", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "pop"
                                vm.play80PercentDingSound(theme: "pop")
                            }
                            audioOptionPill(title: "Submarine", id: "submarine", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "submarine"
                                vm.play80PercentDingSound(theme: "submarine")
                            }
                            audioOptionPill(title: "Purr", id: "purr", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "purr"
                                vm.play80PercentDingSound(theme: "purr")
                            }
                            audioOptionPill(title: "Funk", id: "funk", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "funk"
                                vm.play80PercentDingSound(theme: "funk")
                            }
                            audioOptionPill(title: "Sosumi", id: "sosumi", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "sosumi"
                                vm.play80PercentDingSound(theme: "sosumi")
                            }
                            audioOptionPill(title: "Ping", id: "ping", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "ping"
                                vm.play80PercentDingSound(theme: "ping")
                            }
                            audioOptionPill(title: "Basso", id: "basso", current: vm.eightyPercentSoundTheme) {
                                vm.eightyPercentSoundTheme = "basso"
                                vm.play80PercentDingSound(theme: "basso")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // 2. iPhone Connected Sound
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhone Connected Sound")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("Plays when iPhone is plugged in via USB-C or Lightning cable")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    testAudioButton {
                        vm.playIPhoneSound()
                    }
                    Toggle("", isOn: $vm.iphoneSoundEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#30D158")))
                        .labelsHidden()
                }

                if vm.iphoneSoundEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            Text("Sound:")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            audioOptionPill(title: "Pop", id: "pop", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "pop"
                                vm.playIPhoneSound(named: "Pop")
                            }
                            audioOptionPill(title: "Tink", id: "tink", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "tink"
                                vm.playIPhoneSound(named: "Tink")
                            }
                            audioOptionPill(title: "Bottle", id: "bottle", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "bottle"
                                vm.playIPhoneSound(named: "Bottle")
                            }
                            audioOptionPill(title: "Glass", id: "glass", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "glass"
                                vm.playIPhoneSound(named: "Glass")
                            }
                            audioOptionPill(title: "Hero", id: "hero", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "hero"
                                vm.playIPhoneSound(named: "Hero")
                            }
                            audioOptionPill(title: "Funk", id: "funk", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "funk"
                                vm.playIPhoneSound(named: "Funk")
                            }
                            audioOptionPill(title: "Morse", id: "morse", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "morse"
                                vm.playIPhoneSound(named: "Morse")
                            }
                            audioOptionPill(title: "Purr", id: "purr", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "purr"
                                vm.playIPhoneSound(named: "Purr")
                            }
                            audioOptionPill(title: "Ping", id: "ping", current: vm.iphoneConnectSoundTheme) {
                                vm.iphoneConnectSoundTheme = "ping"
                                vm.playIPhoneSound(named: "Ping")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // 3. iPhone Disconnected Sound
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhone Disconnected Sound")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("Plays when iPhone is unplugged or disconnected from cable")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    testAudioButton {
                        vm.playIPhoneDisconnectSound()
                    }
                    Toggle("", isOn: $vm.iphoneDisconnectSoundEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#30D158")))
                        .labelsHidden()
                }

                if vm.iphoneDisconnectSoundEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            Text("Sound:")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            audioOptionPill(title: "Blow", id: "blow", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "blow"
                                vm.playIPhoneDisconnectSound(named: "Blow")
                            }
                            audioOptionPill(title: "Bottle", id: "bottle", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "bottle"
                                vm.playIPhoneDisconnectSound(named: "Bottle")
                            }
                            audioOptionPill(title: "Basso", id: "basso", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "basso"
                                vm.playIPhoneDisconnectSound(named: "Basso")
                            }
                            audioOptionPill(title: "Pop", id: "pop", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "pop"
                                vm.playIPhoneDisconnectSound(named: "Pop")
                            }
                            audioOptionPill(title: "Tink", id: "tink", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "tink"
                                vm.playIPhoneDisconnectSound(named: "Tink")
                            }
                            audioOptionPill(title: "Sosumi", id: "sosumi", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "sosumi"
                                vm.playIPhoneDisconnectSound(named: "Sosumi")
                            }
                            audioOptionPill(title: "Purr", id: "purr", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "purr"
                                vm.playIPhoneDisconnectSound(named: "Purr")
                            }
                            audioOptionPill(title: "Frog", id: "frog", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "frog"
                                vm.playIPhoneDisconnectSound(named: "Frog")
                            }
                            audioOptionPill(title: "Submarine", id: "submarine", current: vm.iphoneDisconnectSoundTheme) {
                                vm.iphoneDisconnectSoundTheme = "submarine"
                                vm.playIPhoneDisconnectSound(named: "Submarine")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // 4. USB-PD Disconnect Chime
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("USB-PD Disconnect Chime")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text("Stereo left-to-right panning audio when high-speed charger unplugged")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    testAudioButton {
                        vm.playPDSound()
                    }
                    Toggle("", isOn: $vm.pdSoundEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#30D158")))
                        .labelsHidden()
                }

                if vm.pdSoundEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            Text("Tone:")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            audioOptionPill(title: "Blow (Sweep)", id: "blow", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "blow"
                                vm.playPDSound(named: "Blow")
                            }
                            audioOptionPill(title: "Bottle", id: "bottle", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "bottle"
                                vm.playPDSound(named: "Bottle")
                            }
                            audioOptionPill(title: "Basso", id: "basso", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "basso"
                                vm.playPDSound(named: "Basso")
                            }
                            audioOptionPill(title: "Sosumi", id: "sosumi", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "sosumi"
                                vm.playPDSound(named: "Sosumi")
                            }
                            audioOptionPill(title: "Submarine", id: "submarine", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "submarine"
                                vm.playPDSound(named: "Submarine")
                            }
                            audioOptionPill(title: "Frog", id: "frog", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "frog"
                                vm.playPDSound(named: "Frog")
                            }
                            audioOptionPill(title: "Funk", id: "funk", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "funk"
                                vm.playPDSound(named: "Funk")
                            }
                            audioOptionPill(title: "Glass", id: "glass", current: vm.pdSoundTheme) {
                                vm.pdSoundTheme = "glass"
                                vm.playPDSound(named: "Glass")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func audioOptionPill(title: String, id: String, current: String, onSelect: @escaping () -> Void) -> some View {
        let isSelected = current.lowercased() == id.lowercased()
        return Button(action: onSelect) {
            HStack(spacing: 3) {
                if isSelected {
                    Image(systemName: "speaker.wave.1.fill")
                        .font(.system(size: 8))
                }
                Text(title)
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(hex: "#30D158").opacity(0.3) : Color.white.opacity(0.06))
            )
            .foregroundColor(isSelected ? Color.white : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func testAudioButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 7.5))
                Text("Test")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color.white.opacity(0.10))
            .foregroundColor(Color(hex: "#30D158"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var settingsDatabaseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#FF9F0A"))
                Text("Database & Archival Management")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(vm.historyPoints.count) Battery Snapshots Indexed")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Snapshots auto-synced across coconutBattery and widget sessions")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Button(action: importBackup) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text("Import History")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: exportCSV) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up.fill")
                        Text("Export CSV")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#30D158"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "#30D158").opacity(0.14))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Helpers

    private func healthColor(_ h: Double) -> Color {
        h >= 90 ? Color(hex: "#30D158") : (h >= 80 ? Color(hex: "#FFD60A") : Color(hex: "#FF453A"))
    }

    private func formatDateCoconut(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f.string(from: d)
    }
}
final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct VisualEffectBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> DraggableVisualEffectView {
        let view = DraggableVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: DraggableVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct WindowDragModifier: ViewModifier {
    @State private var startMouse: NSPoint = .zero
    @State private var startOrigin: NSPoint = .zero

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) else { return }
                        if startMouse == .zero {
                            startMouse = NSEvent.mouseLocation
                            startOrigin = window.frame.origin
                        }
                        let cur = NSEvent.mouseLocation
                        let dx = cur.x - startMouse.x
                        let dy = cur.y - startMouse.y
                        
                        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
                        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                        let w = window.frame.width
                        let h = window.frame.height
                        
                        let targetX = startOrigin.x + dx
                        let targetY = startOrigin.y + dy
                        
                        // Prevent dragging window below bottom of screen / dock or beyond screen bounds
                        let clampedX = max(vis.minX + 4, min(vis.maxX - w - 4, targetX))
                        let clampedY = max(vis.minY + 4, min(vis.maxY - h - 4, targetY))
                        
                        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
                    }
                    .onEnded { _ in
                        startMouse = .zero
                        startOrigin = .zero
                        if let window = NSApp.windows.first(where: { $0 is FloatingPanel }) {
                            UserDefaults.standard.set(window.frame.origin.x, forKey: kFrameOriginX)
                            UserDefaults.standard.set(window.frame.maxY, forKey: kFrameTopY)
                        }
                    }
            )
    }
}

// MARK: - Lid Sessions Popover View

struct LidSessionsPopoverView: View {
    @ObservedObject var vm: BatteryWidgetViewModel

    private var totalActiveSeconds: TimeInterval {
        vm.todayLidSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    private var totalActiveFormatted: String {
        let sec = Int(totalActiveSeconds)
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(max(1, m))m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "#0A84FF"))
                    Text("Today's Lid Sessions")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
                Text(totalActiveFormatted)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#30D158"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#30D158").opacity(0.14))
                    .clipShape(Capsule())
            }

            Divider().background(Color.white.opacity(0.1))

            if vm.todayLidSessions.isEmpty {
                VStack(spacing: 4) {
                    Text("No lid sessions recorded today")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(vm.todayLidSessions.enumerated()), id: \.element.id) { idx, session in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.isActive ? Color(hex: "#30D158") : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)

                            Text("Session \(idx + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 58, alignment: .leading)

                            Text("\(formatTimeShort(session.openDate)) → \(session.closeDate != nil ? formatTimeShort(session.closeDate!) : "Active")")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(session.isActive ? Color(hex: "#30D158") : .white.opacity(0.65))

                            Spacer()

                            Text(session.durationString)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(session.isActive ? Color(hex: "#30D158") : .white.opacity(0.9))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(session.isActive ? Color(hex: "#30D158").opacity(0.08) : Color.white.opacity(0.03))
                        )
                    }
                }
            }

            if let first = vm.firstLidOpenToday {
                HStack {
                    Text("First Lid Open: \(formatTimeFull(first))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(Color(hex: "#1C1C1E"))
    }
}

// MARK: - Device Grid Card View for Overview

struct DeviceGridCardView: View {
    var vm: BatteryWidgetViewModel? = nil
    let dev: DeviceBatteryData
    let onSelect: () -> Void
    @State private var showingLidSessions: Bool = false

    private func healthColor(_ val: Double) -> Color {
        if val >= 90 { return Color(hex: "#30D158") }
        if val >= 80 { return Color(hex: "#FFD60A") }
        return Color(hex: "#FF453A")
    }

    private func trendColor(_ trend: TemperatureTrend, isOverheated: Bool) -> Color {
        if isOverheated { return Color(hex: "#FF453A") }
        switch trend {
        case .rising: return Color(hex: "#FF9F0A")
        case .falling: return Color(hex: "#30D158")
        case .stable: return .white.opacity(0.55)
        }
    }

    private func batteryStateInfo() -> (label: String, icon: String, color: Color) {
        MacChargeLabel.status(dev)
    }

    private func formatRemainingTime() -> String? {
        // Don't show time remaining or time left for Mac
        if dev.deviceType == .mac || dev.deviceId == "local_mac" {
            return nil
        }
        
        if dev.isCharging {
            if dev.capacityExact >= 80.0 {
                return "Reached 80%"
            }
            // Estimate time left to charge to 80%
            let rate = abs(dev.ratePctPerHour ?? 32.0)
            let effectiveRate = max(5.0, rate)
            let pctTo80 = max(0.0, 80.0 - dev.capacityExact)
            let minsTo80 = max(1, Int((pctTo80 / effectiveRate) * 60.0))
            let h = minsTo80 / 60
            let m = minsTo80 % 60
            let timeStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return "\(timeStr) to 80%"
        } else {
            // Do not show discharging time left
            return nil
        }
    }

    private func formatDateShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    private func formatUsageDate(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        let comps = cal.dateComponents([.day, .hour, .minute], from: d)
        if (comps.day ?? 1) != 1 {
            f.dateFormat = "d MMM yyyy"
        } else {
            f.dateFormat = "MMM yyyy"
        }
        return f.string(from: d)
    }

    private func releaseAgeString(from startDate: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: startDate, to: Date())
        let y = max(0, comps.year ?? 0)
        let m = max(0, comps.month ?? 0)
        return "\(y)y \(m)m"
    }

    private var rateAndPowerString: (text: String, isDischarge: Bool)? {
        let isDischarge = !dev.isCharging && dev.isACConnected != true
        let prefix = isDischarge ? "-" : "+"
        
        if let w = dev.chargingWatts, abs(w) > 0.05 {
            return (String(format: "%@%.1f W", prefix, abs(w)), isDischarge)
        }
        return nil
    }

    var body: some View {
        let isMac = dev.deviceType == .mac || dev.deviceId == "local_mac"
        VStack(alignment: .leading, spacing: 5) {
            deviceNameRow
            batteryPercentageRow(isMac: isMac)
            CompactProgressBar(
                value: dev.capacityExact,
                fillGradient: batteryFillGradient(val: dev.capacityExact, isCharging: dev.isCharging, isMac: isMac),
                height: 4
            )
            temperatureRow
            if let health = dev.batteryHealthPct {
                healthRow(health: health)
            }
            capacityRow
            if let cycles = dev.cycleCount {
                cycleCountRow(cycles: cycles)
            }
            chargingStatusRow
            powerSourceRow
            systemPowerRow
            lidOpenRow
            processorRow
            releaseAndAgeRows
            QuietStamp(info: dev).padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .onTapGesture {
            onSelect()
        }
    }

    private var deviceNameRow: some View {
        HStack(spacing: 4.5) {
            Image(systemName: dev.deviceType.iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Text(dev.deviceName)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
            if dev.isWirelesslyConnected && dev.deviceType != .iphone && !dev.deviceName.lowercased().contains("iphone") {
                Image(systemName: "wifi")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
        }
    }

    private func batteryPercentageRow(isMac: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Spacer()
            if dev.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#30D158"))
            }
            Text(String(format: "%.1f%%", dev.capacityExact))
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(capacityColor(dev.capacityExact, isCharging: dev.isCharging, isMac: isMac))
        }
    }

    private var temperatureRow: some View {
        HStack {
            HStack(spacing: 3.5) {
                Image(systemName: (dev.temperatureC ?? 0) >= 35.0 ? "flame.fill" : "thermometer.medium")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(dev.temperatureC.map { temperatureColor($0) } ?? .white.opacity(0.55))
                Text("Temperature")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Spacer()
            
            if let t = dev.temperatureC {
                let col = temperatureColor(t)
                let textCol = temperatureTextColor(t)
                let trend = dev.tempTrend ?? .stable
                HStack(spacing: 2.5) {
                    Image(systemName: t >= 35.0 ? "flame.fill" : "thermometer.medium")
                        .font(.system(size: 8, weight: .bold))
                    Text(String(format: "%.1f°C", t))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    Image(systemName: trend.iconName)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(textCol)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(col.opacity(0.18))
                )
                .foregroundColor(textCol)
            } else {
                Text("–")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 1)
    }

    private func healthRow(health: Double) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text("Battery Health")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text(String(format: "%.1f%%", health))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            CompactProgressBar(
                value: health,
                fillGradient: [Color.white.opacity(0.55), Color.white.opacity(0.80)],
                height: 3
            )
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var capacityRow: some View {
        if let fcc = dev.fullChargeMah, let dcap = dev.designCapacityMah {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "battery.100")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Capacity")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text("\(dcap) / \(fcc) mAh")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        } else if let dcap = dev.designCapacityMah {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "battery.100")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Capacity")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text("\(dcap) mAh")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        } else if let fcc = dev.fullChargeMah {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "battery.100")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Capacity")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text("\(fcc) mAh")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func cycleCountRow(cycles: Int) -> some View {
        HStack {
            HStack(spacing: 3.5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.45))
                Text("Cycle Count")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            Text("\(cycles)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var chargingStatusRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 3.5) {
                let state = batteryStateInfo()
                Image(systemName: state.icon)
                    .font(.system(size: 8))
                    .foregroundColor(state.color)
                Text(state.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.70))
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                if let (powerText, isDischarge) = rateAndPowerString {
                    Text(powerText)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(isDischarge ? Color(hex: "#FF9F0A") : Color(hex: "#30D158"))
                }
                if let timeStr = formatRemainingTime() {
                    Text(timeStr)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(dev.isCharging ? Color(hex: "#30D158") : .white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private var powerSourceRow: some View {
        if dev.deviceType != .mac && dev.deviceId != "local_mac", let ac = dev.isACConnected {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: ac ? "powerplug.fill" : "battery.100")
                        .font(.system(size: 8))
                        .foregroundColor(ac ? Color(hex: "#30D158") : .white.opacity(0.45))
                    Text("Power Source")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(ac ? "On AC" : "Battery")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(ac ? Color(hex: "#30D158") : .white.opacity(0.85))
            }
        }

        if (dev.deviceType == .mac || dev.deviceId == "local_mac"), let pdOn = dev.pdHandshakeOn {
            HStack {
                HStack(spacing: 3.5) {
                    Circle()
                        .fill(pdOn ? Color(hex: "#30D158") : Color(hex: "#FF453A"))
                        .frame(width: 6, height: 6)
                    Text("USB-PD")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(pdOn ? "ON" : "OFF")
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(pdOn ? Color(hex: "#30D158") : Color(hex: "#FF453A"))
                    if pdOn, let w = dev.pdPowerLabel {
                        Text(w)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var systemPowerRow: some View {
        if (dev.deviceType == .mac || dev.deviceId == "local_mac"), let load = dev.systemLoadWatts, load > 0.05 {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 8))
                        .foregroundColor(systemPowerColor(load))
                    Text("System Power")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(formatWatts(load, prefix: "−"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(systemPowerColor(load))
            }
        }
    }

    @ViewBuilder
    private var lidOpenRow: some View {
        if (dev.deviceType == .mac || dev.deviceId == "local_mac"), let firstOpen = vm?.firstLidOpenToday {
            Button(action: {
                showingLidSessions = true
            }) {
                HStack {
                    HStack(spacing: 3.5) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.45))
                        Text("Today Lid Open")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        Text(formatTimeShort(firstOpen))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingLidSessions, arrowEdge: .trailing) {
                if let v = vm {
                    LidSessionsPopoverView(vm: v)
                }
            }
        }
    }

    @ViewBuilder
    private var processorRow: some View {
        if let chip = dev.processor ?? AppleModelDatabase.lookupProcessor(model: dev.hardwareModel, deviceName: dev.deviceName, deviceType: dev.deviceType) {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Processor")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(chip)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private var releaseAndAgeRows: some View {
        if let relDate = dev.modelReleaseDate {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Released \(formatDateShort(relDate))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(releaseAgeString(from: relDate))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }

        if let firstUse = dev.firstUseDate ?? dev.deviceManufactureDate {
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text(dev.firstUseDate != nil ? "First Used" : "Manufactured")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(formatUsageDate(firstUse))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            
            HStack {
                HStack(spacing: 3.5) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Device Age")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                Text(AppleModelDatabase.ageString(from: firstUse))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Main Battery Widget View

struct BatteryWidgetView: View {
    @ObservedObject var vm: BatteryWidgetViewModel
    var onOpenHistory: (() -> Void)? = nil
    @State private var showingHistory: Bool = false

    private var device: DeviceBatteryData? {
        vm.selectedDevice
    }

    private func healthColor(_ val: Double) -> Color {
        if val >= 90 { return Color(hex: "#30D158") }
        if val >= 80 { return Color(hex: "#FFD60A") }
        return Color(hex: "#FF453A")
    }

    private func trendColor(_ trend: TemperatureTrend, isOverheated: Bool) -> Color {
        if isOverheated { return Color(hex: "#FF453A") }
        switch trend {
        case .rising: return Color(hex: "#FF9F0A")
        case .falling: return Color(hex: "#30D158")
        case .stable: return .white.opacity(0.55)
        }
    }

    private func formatDisk(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1000 {
            return String(format: "%.1f TB", gb / 1000.0)
        }
        return String(format: "%.0f GB", gb)
    }

    private func formatDateShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    private func formatRemainingTime(_ mins: Int, isCharging: Bool) -> String {
        let h = mins / 60
        let m = mins % 60
        let timeStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return isCharging ? "\(timeStr) to full" : "\(timeStr) left"
    }

    private func formatPowerDetailValue(watts: Double, amperageMa: Int?, prefix: String) -> String {
        let base = String(format: "%@%.1f W", prefix, abs(watts))
        if let a = amperageMa, abs(a) > 0 {
            return base + String(format: " (%@%d mA)", prefix, abs(a))
        }
        return base
    }

    private func batteryStateInfo(_ info: DeviceBatteryData) -> (label: String, icon: String, color: Color) {
        MacChargeLabel.status(info)
    }

    var body: some View {
        ZStack {
            // BigUwidget Iconic Translucent Dark Glass Plate
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#1C1C1E").opacity(vm.backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 8, y: 3)

            VStack(spacing: 0) {
                // ── Device Tabs (All, iPhone, iPad, Mac) - Icons Only ──
                HStack(spacing: 4) {
                    // "All" Overview Tab
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.selectTab("all")
                        }
                    }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(vm.selectedDeviceId == "all" ? Color.white.opacity(0.18) : Color.clear)
                            )
                            .foregroundColor(vm.selectedDeviceId == "all" ? .white : .white.opacity(0.45))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(vm.devices) { dev in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.selectTab(dev.id)
                            }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: dev.deviceType.iconName)
                                    .font(.system(size: 10, weight: .bold))
                                if !dev.isConnected {
                                    Circle()
                                        .fill(Color.orange.opacity(0.8))
                                        .frame(width: 4, height: 4)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(vm.selectedDeviceId == dev.id ? Color.white.opacity(0.14) : Color.clear)
                            )
                            .foregroundColor(vm.selectedDeviceId == dev.id ? .white : .white.opacity(0.45))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    
                    // Settings & Battery Archive button
                    Button(action: {
                        if let openHist = onOpenHistory {
                            openHist()
                        } else {
                            showingHistory = true
                        }
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Settings & Battery Archive")
                    .padding(.trailing, 2)

                    // Minimize button
                    Button(action: {
                        NSApp.hide(nil)
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Minimize Widget")
                    .padding(.trailing, 2)

                    // Close button
                    Button(action: {
                        NSApp.terminate(nil)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Close App")
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                    .padding(.horizontal, 10).padding(.vertical, 8)

                if vm.selectedDeviceId == "all" {
                    VStack(spacing: 8) {
                        ForEach(vm.devices) { dev in
                            DeviceGridCardView(vm: vm, dev: dev, onSelect: {
                                vm.selectTab(dev.id)
                            })
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                } else if let info = device {
                    DeviceGridCardView(vm: vm, dev: info, onSelect: {})
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Reading battery info…")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(30)
                }
            }
        }
        .frame(width: 212)
        .modifier(WindowDragModifier())
    }
}

// MARK: - Auto-Fit Hosting View

final class AutoFitHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSize: ((NSSize) -> Void)?
    private var lastFitting: NSSize = .zero
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let s = fittingSize
        guard s.width > 0 && s.height > 0 else { return }
        lastFitting = s
        onFittingSize?(s)
    }
}

// MARK: - Floating Panel

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isMovable: Bool {
        get { true }
        set { }
    }
    override var isMovableByWindowBackground: Bool {
        get { true }
        set { }
    }
}

// MARK: - AppDelegate

@objc final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var historyPanel: FloatingPanel?
    private var hosting: AutoFitHostingView<BatteryWidgetView>!
    private var vm: BatteryWidgetViewModel!

    func applicationDidFinishLaunching(_ note: Notification) {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: kAppBundleID)
            .filter { $0.processIdentifier != selfPid }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        vm = BatteryWidgetViewModel()
        buildPanel()
    }

    func toggleHistoryWindow() {
        if let hp = historyPanel, hp.isVisible {
            hp.orderOut(nil)
            historyPanel = nil
            return
        }
        openHistoryWindow()
    }

    func openHistoryWindow() {
        if let existing = historyPanel {
            existing.orderOut(nil)
            historyPanel = nil
        }
        
        guard let p = self.panel else { return }
        let screen = p.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        let historyW: CGFloat = 900
        let historyH: CGFloat = min(640, max(460, vis.height - 24))
        let historySize = NSSize(width: historyW, height: historyH)
        
        let historyView = BatteryHistoryChartView(
            vm: vm,
            onClose: { [weak self] in
                self?.historyPanel?.orderOut(nil)
                self?.historyPanel = nil
            }
        )
        
        let host = NSHostingView(rootView: historyView)
        host.frame = NSRect(origin: .zero, size: historySize)
        
        let win = FloatingPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.managed, .fullScreenNone]
        win.isMovableByWindowBackground = true
        win.hidesOnDeactivate = false
        win.contentView = host
        win.setContentSize(historySize)
        
        // Exact Bottom Alignment:
        // The bottom of the history window is at the exact same height as the bottom of the widget itself
        var historyY = p.frame.origin.y
        if historyY < vis.minY + 8 {
            historyY = vis.minY + 8
        }
        if historyY + historyH > vis.maxY - 8 {
            historyY = max(vis.minY + 8, vis.maxY - 8 - historyH)
        }
        
        // Position horizontally next to the widget (prefer left side, fallback to right)
        var historyX = p.frame.minX - historyW - 10
        if historyX < vis.minX + 8 {
            historyX = p.frame.maxX + 10
            if historyX + historyW > vis.maxX - 8 {
                historyX = max(vis.minX + 8, min(vis.maxX - historyW - 8, p.frame.minX - historyW - 10))
            }
        }
        
        win.setFrameOrigin(NSPoint(x: historyX, y: historyY))
        historyPanel = win
        win.orderFrontRegardless()
    }

    private func buildPanel() {
        let w: CGFloat = 212
        let content = BatteryWidgetView(
            vm: vm,
            onOpenHistory: { [weak self] in
                self?.toggleHistoryWindow()
            }
        )
        hosting = AutoFitHostingView(rootView: content)
        hosting.onFittingSize = { [weak self] s in
            guard let self, let p = self.panel else { return }
            let frame = p.frame
            let screen = p.screen ?? NSScreen.main ?? NSScreen.screens.first
            let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            let maxAvailableH = max(240, vis.height - 16)
            let h = min(max(240, s.height), maxAvailableH)
            
            var newY = frame.maxY - h
            // When widget is near the bottom edge of the screen, keep it above Dock / bottom border
            if newY < vis.minY + 8 {
                newY = vis.minY + 8
            }
            if newY + h > vis.maxY - 8 {
                newY = max(vis.minY + 8, vis.maxY - 8 - h)
            }
            
            var newX = frame.origin.x
            if newX < vis.minX + 8 { newX = vis.minX + 8 }
            if newX + w > vis.maxX - 8 { newX = vis.maxX - 8 - w }
            
            let newFrame = NSRect(x: newX, y: newY, width: w, height: h)
            if abs(frame.height - h) < 1 && abs(frame.origin.x - newX) < 1 && abs(frame.origin.y - newY) < 1 {
                return
            }
            p.setFrame(newFrame, display: true)
        }

        let defaultSize = NSSize(width: w, height: 380)
        let p = FloatingPanel(
            contentRect: NSRect(origin: NSPoint(x: 1200, y: 300), size: defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.managed, .fullScreenNone]
        p.sharingType = .readOnly
        p.isMovableByWindowBackground = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        p.setContentSize(defaultSize)

        panel = p
        restoreFrame(w: w)
        p.orderFrontRegardless()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) {
                if event.characters == "q" { NSApp.terminate(nil); return nil }
                if event.characters == "r" { Task { @MainActor in self?.vm.refresh(manual: true) }; return nil }
            }
            return event
        }

        NotificationCenter.default.addObserver(self,
            selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification,
            object: p)
    }

    @objc private func windowMoved() { persistFrame() }

    private func restoreFrame(w: CGFloat) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxAvailableH = max(240, vis.height - 16)
        let rawH = hosting.fittingSize.height > 0 ? hosting.fittingSize.height : 380
        let h = min(max(240, rawH), maxAvailableH)
        
        let d = UserDefaults.standard
        var origin: NSPoint
        if d.object(forKey: kFrameTopY) != nil {
            let savedX = d.double(forKey: kFrameOriginX)
            let savedTopY = d.double(forKey: kFrameTopY)
            var y = savedTopY - h
            // Prevent being hidden below bottom edge of screen / dock
            if y < vis.minY + 8 {
                y = vis.minY + 8
            }
            if y + h > vis.maxY - 8 {
                y = max(vis.minY + 8, vis.maxY - 8 - h)
            }
            let x = max(vis.minX + 8, min(vis.maxX - w - 8, savedX))
            origin = NSPoint(x: x, y: y)
        } else {
            let defaultTopY: CGFloat = 522
            let y = defaultTopY - h
            origin = NSPoint(x: 29, y: max(vis.minY + 8, min(vis.maxY - 8 - h, y)))
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }

    private func persistFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: kFrameOriginX)
        UserDefaults.standard.set(panel.frame.maxY,     forKey: kFrameTopY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel?.orderFrontRegardless(); return true
    }

    func applicationWillTerminate(_ note: Notification) {
        persistFrame()
        vm?.savePersisted()
    }
}

// MARK: - Entry

@main
enum iPhoneBatteryWidgetMain {
    static func main() {
        let app = NSApplication.shared
        let del = AppDelegate()
        app.delegate = del
        _ = Unmanaged.passRetained(del)
        app.run()
    }
}
