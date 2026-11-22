import Foundation

// MARK: - Sidebar Navigation

enum LauncherSection: String, CaseIterable, Identifiable {
    case play = "Play"
    case graphics = "Display & Graphics"
    case patches = "Effects & Patches"
    case controls = "Controls"
    case saves = "Save Data"
    case dlc = "DLC & Add-Ons"
    case engine = "Mac Port & Build"
    case logs = "Console Log"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .play: return "flag.checkered.2.crossed"
        case .graphics: return "sparkles.tv"
        case .patches: return "slider.horizontal.3"
        case .controls: return "gamecontroller.fill"
        case .saves: return "externaldrive.fill.badge.timemachine"
        case .dlc: return "shippingbox.fill"
        case .engine: return "cpu.fill"
        case .logs: return "terminal.fill"
        }
    }
}

// MARK: - Supported CTR Title IDs & Choices

nonisolated enum CTRConstants {
    static let americasTitleID = "CUSA13795"
    static let europeTitleID = "CUSA14876"
    static let supportedTitleIDs: Set<String> = [americasTitleID, europeTitleID]
    static let requiredUpdateVersion = "01.21"
    static let completeGameMinBytes: UInt64 = 10 * 1024 * 1024 * 1024 // 10 GiB
}

nonisolated struct SettingChoice: Identifiable, Hashable, Sendable {
    let label: String
    let value: String
    var id: String { value }
}

enum GraphicsDriverChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case kosmicKrisp = "kosmickrisp"
    case moltenVK = "moltenvk"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (KosmicKrisp on macOS 26+)"
        case .kosmicKrisp: return "Mesa KosmicKrisp (Vulkan 1.4 on Metal 4)"
        case .moltenVK: return "MoltenVK (Compatibility Fallback)"
        }
    }
}

// MARK: - Lossless INI Document (bbport.ini & launcher.ini)

nonisolated struct IniDocument: Sendable {
    private(set) var lines: [String] = []
    private(set) var values: [String: String] = [:]
    private var erasedKeys: Set<String> = []

    init() {}

    init(contentsOf url: URL) {
        load(from: url)
    }

    mutating func load(from url: URL) {
        lines.removeAll()
        values.removeAll()
        erasedKeys.removeAll()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            lines.append(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let eqIndex = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            let val = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
            values[key] = val
        }
    }

    func string(_ key: String, default fallback: String = "") -> String {
        values[key] ?? fallback
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let v = values[key], !v.isEmpty else { return fallback }
        return v != "0" && v.lowercased() != "false" && v.lowercased() != "off"
    }

    func int(_ key: String, default fallback: Int) -> Int {
        guard let v = values[key], let parsed = Int(v) else { return fallback }
        return parsed
    }

    func double(_ key: String, default fallback: Double) -> Double {
        guard let v = values[key], let parsed = Double(v) else { return fallback }
        return parsed
    }

    mutating func set(_ key: String, _ value: String) {
        values[key] = value
        erasedKeys.remove(key)
    }

    mutating func setBool(_ key: String, _ enabled: Bool) {
        set(key, enabled ? "1" : "0")
    }

    mutating func erase(_ key: String) {
        values.removeValue(forKey: key)
        erasedKeys.insert(key)
    }

    @discardableResult
    mutating func save(to url: URL, headerComment: String? = nil) -> Bool {
        var output: [String] = []
        var written: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
               let eqIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
                if erasedKeys.contains(key) {
                    continue
                }
                if let updated = values[key] {
                    if !written.contains(key) {
                        output.append("\(key)=\(updated)")
                        written.insert(key)
                    }
                    continue
                }
            }
            output.append(line)
        }

        if lines.isEmpty, let headerComment {
            output.append(headerComment)
        }

        for key in values.keys.sorted() where !written.contains(key) {
            if let val = values[key] {
                output.append("\(key)=\(val)")
            }
        }

        let text = output.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            lines = output
            erasedKeys.removeAll()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - PS4 param.sfo Binary Parser

nonisolated enum SfoParser {
    static func parse(url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data: data)
    }

    static func parse(data: Data) -> [String: String] {
        guard data.count >= 20,
              data[0] == 0x00, data[1] == 0x50, data[2] == 0x53, data[3] == 0x46 else { // "\0PSF"
            return [:]
        }

        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= data.count else { return 0 }
            return Int(data[offset]) | (Int(data[offset + 1]) << 8)
        }

        func u32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        let keysOffset = Int(u32(8))
        let valuesOffset = Int(u32(12))
        let count = Int(u32(16))
        var result: [String: String] = [:]

        for index in 0..<count {
            let entry = 20 + index * 16
            guard entry + 16 <= data.count else { break }
            let keyOff = u16(entry)
            let fmt = u16(entry + 2)
            let len = Int(u32(entry + 4))
            let valOff = Int(u32(entry + 12))

            let keyStart = keysOffset + keyOff
            guard keyStart < data.count,
                  let keyEnd = data[keyStart...].firstIndex(of: 0) else {
                continue
            }
            let key = String(decoding: data[keyStart..<keyEnd], as: UTF8.self)

            let valStart = valuesOffset + valOff
            guard valStart >= 0, len >= 0, valStart + len <= data.count else { continue }

            if fmt == 0x0404 {
                result[key] = String(u32(valStart))
            } else {
                var slice = data[valStart..<(valStart + len)]
                while slice.last == 0 {
                    slice = slice.dropLast()
                }
                result[key] = String(decoding: slice, as: UTF8.self)
            }
        }
        return result
    }
}

// MARK: - Game Folder Inspection

nonisolated enum DumpKind: String, Sendable {
    case empty
    case missing
    case notGame
    case encryptedSelf
    case otherTitle
    case otherVersion
    case base
    case update
    case complete
}

nonisolated struct GameFolderInfo: Sendable, Equatable {
    var kind: DumpKind = .empty
    var path: String = ""
    var titleID: String = ""
    var titleName: String = ""
    var version: String = ""
    var category: String = ""
    var bytes: UInt64 = 0
    var isSplitPkgLayout: Bool = false

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var regionBadge: String {
        switch titleID {
        case CTRConstants.americasTitleID: return "Americas (CUSA13795)"
        case CTRConstants.europeTitleID: return "Europe / PAL (CUSA14876)"
        default: return titleID
        }
    }

    var statusSummary: String {
        switch kind {
        case .empty:
            return "No folder selected."
        case .missing:
            return "Folder does not exist on disk."
        case .notGame:
            return "Not recognized (missing eboot.bin or sce_sys/param.sfo)."
        case .encryptedSelf:
            return "Encrypted PS4 FSELF detected — eboot.bin must be a decrypted ELF or plaintext PS4 SELF dump."
        case .otherTitle:
            return "Different PS4 title (\(titleID)). Expected CUSA13795 or CUSA14876."
        case .otherVersion:
            return "Update \(version) found — CTR Nitro-Fueled requires update 01.21."
        case .base:
            return "Base game (\(regionBadge), v\(version)) — select Update 01.21 to merge."
        case .update:
            return "Update 01.21 (\(regionBadge), \(formattedSize)) — select Base game to merge."
        case .complete:
            if isSplitPkgLayout {
                return "Complete v01.21 in Image0/Sc0 PKG layout (\(formattedSize)) — ready to flatten."
            }
            return "Ready to play: \(regionBadge) v\(version) (\(formattedSize))."
        }
    }
}

// MARK: - Host / Apple Silicon Readiness

nonisolated struct MacEnvironmentStatus: Sendable {
    var isAppleSilicon: Bool = true
    var macOSVersionString: String = ""
    var macOSMajorVersion: Int = 27
    var rosettaInstalled: Bool = false
    var sacredfireBinaryPath: String?
    var cpuFeaturesReport: String = ""
    var kosmicKrispICDPath: String?
    var moltenVKICDPath: String?
    var pythonPath: String?
    var cmakePath: String?
    var ninjaPath: String?

    var supportsAVXUnderRosetta: Bool {
        !isAppleSilicon || macOSMajorVersion >= 15
    }

    var supportsMetal4KosmicKrisp: Bool {
        isAppleSilicon && macOSMajorVersion >= 26
    }
}

// MARK: - Patches, Effects, Saves & DLC Models

struct EffectToggleDefinition: Identifiable, Sendable {
    let key: String
    let title: String
    let subtitle: String
    let defaultOn: Bool
    var id: String { key }

    static let builtInEffects: [EffectToggleDefinition] = [
        .init(key: "effect_chromatic_aberration", title: "Chromatic Aberration", subtitle: "Lens color fringe post-processing", defaultOn: true),
        .init(key: "effect_dof", title: "Depth of Field (DoF)", subtitle: "Background blur in cutscenes and podiums", defaultOn: true),
        .init(key: "effect_motion_blur", title: "Motion Blur", subtitle: "Camera & per-object speed blur", defaultOn: true),
        .init(key: "effect_ssao", title: "Ambient Occlusion (SSAO)", subtitle: "Contact shading in crevices", defaultOn: true),
        .init(key: "effect_game_aa", title: "Built-in Anti-Aliasing", subtitle: "CTR's own post-process AA pass", defaultOn: true),
        .init(key: "effect_dynamic_shadows", title: "Dynamic Light Shadows", subtitle: "Shadows cast by dynamic track lights", defaultOn: true),
        .init(key: "effect_ssr", title: "Screen-Space Reflections (Experimental)", subtitle: "Extra reflections not enabled on console", defaultOn: false),
        .init(key: "skip_intro", title: "Skip Startup Intros", subtitle: "Boot straight to the title screen", defaultOn: false),
        .init(key: "debug_camera", title: "Free Camera (Cross + L3)", subtitle: "Developer fly-around camera toggle", defaultOn: false),
    ]
}

struct PatchEntry: Identifiable, Sendable {
    let key: String
    let name: String
    let author: String
    let note: String
    let version: String
    let defaultOn: Bool
    let iniKey: String?
    var isEnabled: Bool

    var id: String { key }
}

struct SaveSlotEntry: Identifiable, Sendable {
    let directoryName: String
    let title: String
    let subtitle: String
    let detail: String
    let modifiedDate: String
    let bytes: UInt64
    let path: URL

    var id: String { directoryName }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct SaveBackupEntry: Identifiable, Sendable {
    let name: String
    let modifiedDate: String
    let bytes: UInt64
    let path: URL

    var id: String { path.path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct DlcPackageEntry: Identifiable, Sendable {
    let fileName: String
    let contentLabel: String
    let statusNote: String
    let isValid: Bool
    let path: URL
    var isEnabled: Bool

    var id: String { fileName }
}
