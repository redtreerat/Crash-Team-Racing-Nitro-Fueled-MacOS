import AppKit
import Darwin
import Foundation
import Observation

@Observable
final class LauncherStore {
    // Navigation & Notices
    var selectedSection: LauncherSection = .play
    var bannerNotice: String?
    var bannerIsError: Bool = false

    // Paths
    var engineRootURL: URL
    var dataRootURL: URL

    // INI documents
    var gameIni = IniDocument()      // bbport.ini
    var launcherIni = IniDocument()  // launcher.ini

    // Game Folders
    var gameDirPath: String = ""
    var baseDirPath: String = ""
    var updateDirPath: String = ""
    var gameInfo = GameFolderInfo()
    var baseInfo = GameFolderInfo()
    var updateInfo = GameFolderInfo()
    var gameCheckPassed: Bool = false
    var gameCheckMessage: String = ""

    // Environment & Toolchain Status
    var envStatus = MacEnvironmentStatus()
    var connectedGamepads: [SettingChoice] = []

    // Background Tasks & Console Stream
    var isGameRunning: Bool = false
    var isMerging: Bool = false
    var isBuildingEngine: Bool = false
    var mergeCompletedFiles: Int = 0
    var mergeTotalFiles: Int = 0
    var consoleLines: [String] = []
    var lastStatusLine: String = "Ready"

    // Patches, Saves & DLC
    var patches: [PatchEntry] = []
    var saveSlots: [SaveSlotEntry] = []
    var saveBackups: [SaveBackupEntry] = []
    var dlcPackages: [DlcPackageEntry] = []

    private var activeProcess: Process?
    private var activeProcessGroupID: pid_t = 0

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let defaultDataRoot = appSupport.appendingPathComponent("CTR-NitroFueled-Mac", isDirectory: true)
        self.dataRootURL = defaultDataRoot
        self.engineRootURL = Self.discoverDefaultEngineRoot()

        try? FileManager.default.createDirectory(at: defaultDataRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultDataRoot.appendingPathComponent("dlc"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultDataRoot.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultDataRoot.appendingPathComponent("user"), withIntermediateDirectories: true)

        loadConfigurations()
    }

    // MARK: - Path Discovery & Configuration Persistence

    private static func discoverDefaultEngineRoot() -> URL {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("CTR-NitroFueled-PC"),
           fm.fileExists(atPath: bundled.appendingPathComponent("run.py").path) {
            return bundled
        }

        // Walk up from compile-time source path (#filePath -> MyApp/Services/LauncherStore.swift -> workspace root)
        var sourceCursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = sourceCursor.appendingPathComponent("CTR-NitroFueled-PC", isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("run.py").path) {
                return candidate
            }
            sourceCursor.deleteLastPathComponent()
        }

        return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("CTR-NitroFueled-PC")
    }

    var gameIniURL: URL { dataRootURL.appendingPathComponent("bbport.ini") }
    var launcherIniURL: URL { dataRootURL.appendingPathComponent("launcher.ini") }
    var patchesJsonURL: URL { dataRootURL.appendingPathComponent("patches.json") }

    func loadConfigurations() {
        launcherIni.load(from: launcherIniURL)

        let savedEngine = launcherIni.string("engine_root")
        if !savedEngine.isEmpty,
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: savedEngine).appendingPathComponent("run.py").path) {
            engineRootURL = URL(fileURLWithPath: savedEngine)
        }

        if !FileManager.default.fileExists(atPath: gameIniURL.path) {
            let defaultTemplate = engineRootURL.appendingPathComponent("bbport.default.ini")
            if FileManager.default.fileExists(atPath: defaultTemplate.path) {
                try? FileManager.default.copyItem(at: defaultTemplate, to: gameIniURL)
            }
        }
        gameIni.load(from: gameIniURL)

        // Apply sensible Apple Silicon defaults on first run
        if gameIni.string("fps_limit").isEmpty {
            gameIni.set("fps_limit", "60")
        }
        if gameIni.string("temporal").isEmpty {
            gameIni.set("temporal", "fsr3")
        }
        if launcherIni.string("graphics_driver").isEmpty {
            launcherIni.set("graphics_driver", GraphicsDriverChoice.automatic.rawValue)
        }
        if launcherIni.string("present_mode").isEmpty {
            launcherIni.set("present_mode", "Mailbox")
        }

        gameDirPath = launcherIni.string("game_dir")
        baseDirPath = launcherIni.string("base_dir")
        updateDirPath = launcherIni.string("update_dir")

        refreshAllState()
    }

    func saveGameIni() {
        if !gameIni.save(to: gameIniURL, headerComment: "# CTR Nitro-Fueled macOS settings (bbport.ini)") {
            postNotice("Could not save bbport.ini in \(dataRootURL.path).", isError: true)
        }
    }

    func saveLauncherIni() {
        launcherIni.set("engine_root", engineRootURL.path)
        launcherIni.set("game_dir", gameDirPath)
        launcherIni.set("base_dir", baseDirPath)
        launcherIni.set("update_dir", updateDirPath)
        _ = launcherIni.save(to: launcherIniURL, headerComment: "# CTR Nitro-Fueled macOS Launcher configuration")
    }

    func postNotice(_ message: String, isError: Bool = false) {
        bannerNotice = message
        bannerIsError = isError
    }

    func clearNotice() {
        bannerNotice = nil
    }

    // MARK: - Refresh Everything

    func refreshAllState() {
        Task {
            await probeEnvironment()
            await inspectGameFolders()
            reloadPatches()
            reloadSaves()
            reloadDLC()
        }
    }

    var activeTitleID: String {
        for info in [gameInfo, updateInfo, baseInfo] where CTRConstants.supportedTitleIDs.contains(info.titleID) {
            return info.titleID
        }
        return CTRConstants.americasTitleID
    }

    var isEuropeanEdition: Bool {
        activeTitleID == CTRConstants.europeTitleID
    }

    // MARK: - Environment & KosmicKrisp / Rosetta Probe

    func probeEnvironment() async {
        let engineRoot = engineRootURL
        let result = await Task.detached(priority: .utility) { () -> (MacEnvironmentStatus, [SettingChoice]) in
            var status = MacEnvironmentStatus()
            let osVer = ProcessInfo.processInfo.operatingSystemVersion
            status.macOSMajorVersion = osVer.majorVersion
            status.macOSVersionString = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

            #if arch(arm64)
            status.isAppleSilicon = true
            let rosettaCheck = Self.runCommandSync(
                executable: "/usr/bin/arch",
                arguments: ["-x86_64", "/usr/bin/true"]
            )
            status.rosettaInstalled = (rosettaCheck.exitCode == 0)
            #else
            status.isAppleSilicon = false
            status.rosettaInstalled = true
            #endif

            let fm = FileManager.default

            // Locate sacredfire binary
            let binaryCandidates = [
                engineRoot.appendingPathComponent("bin/sacredfire"),
                engineRoot.appendingPathComponent("out/sacredfire"),
                engineRoot.appendingPathComponent("out/gpu-mac/sacredfire"),
            ]
            for candidate in binaryCandidates where fm.isExecutableFile(atPath: candidate.path) {
                status.sacredfireBinaryPath = candidate.path
                break
            }

            if let binPath = status.sacredfireBinaryPath, status.rosettaInstalled {
                let cpuRes = Self.runCommandSync(
                    executable: "/usr/bin/arch",
                    arguments: ["-x86_64", binPath, "--cpu-features"]
                )
                status.cpuFeaturesReport = cpuRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Locate KosmicKrisp & MoltenVK ICD manifests
            let icdSearchDirs = [
                engineRoot.appendingPathComponent("bin").path,
                engineRoot.appendingPathComponent("out/icd").path,
                "/usr/local/share/vulkan/icd.d",
                "/opt/homebrew/share/vulkan/icd.d",
                "/Library/Vulkan/icd.d",
                "\(NSHomeDirectory())/.local/share/vulkan/icd.d",
            ]
            for dir in icdSearchDirs {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".json") {
                    let full = "\(dir)/\(entry)"
                    let lower = entry.lowercased()
                    if status.kosmicKrispICDPath == nil && lower.contains("kosmickrisp") {
                        status.kosmicKrispICDPath = full
                    }
                    if status.moltenVKICDPath == nil && lower.contains("moltenvk") {
                        status.moltenVKICDPath = full
                    }
                }
            }

            // Locate tools (Python 3, CMake, Ninja)
            status.pythonPath = Self.findExecutable(
                named: "python3",
                extraDirs: ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/Applications/Xcode.app/Contents/Developer/usr/bin"]
            )
            status.cmakePath = Self.findExecutable(
                named: "cmake",
                extraDirs: ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/CMake.app/Contents/bin"]
            )
            status.ninjaPath = Self.findExecutable(
                named: "ninja",
                extraDirs: ["/usr/local/bin", "/opt/homebrew/bin"]
            )

            // Probe gamepads if bb-gpu-capabilities is built
            var pads: [SettingChoice] = []
            let capCandidates = [
                engineRoot.appendingPathComponent("bin/bb-gpu-capabilities"),
                engineRoot.appendingPathComponent("out/bb-gpu-capabilities"),
                engineRoot.appendingPathComponent("out/gpu-mac/bb-gpu-capabilities"),
            ]
            if let capBin = capCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }),
               status.rosettaInstalled {
                let padOut = Self.runCommandSync(
                    executable: "/usr/bin/arch",
                    arguments: ["-x86_64", capBin.path, "--gamepads"]
                )
                for line in padOut.output.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        pads.append(SettingChoice(label: parts[1], value: parts[0]))
                    }
                }
            }

            return (status, pads)
        }.value

        self.envStatus = result.0
        self.connectedGamepads = result.1
    }

    // MARK: - Folder Pickers & Inspection

    func chooseFolder(title: String, startingAt currentPath: String = "") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !currentPath.isEmpty {
            let url = URL(fileURLWithPath: currentPath)
            if FileManager.default.fileExists(atPath: url.path) {
                panel.directoryURL = url
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFiles(title: String, allowedExtensions: [String]) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK
            ? panel.urls.filter { allowedExtensions.isEmpty || allowedExtensions.contains($0.pathExtension.lowercased()) }
            : []
    }

    func selectEngineRoot() {
        guard let url = chooseFolder(title: "Select CTR-NitroFueled-PC Port Folder", startingAt: engineRootURL.path) else {
            return
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("run.py").path) else {
            postNotice("Selected folder does not contain run.py.", isError: true)
            return
        }
        engineRootURL = url
        saveLauncherIni()
        refreshAllState()
    }

    func selectGameFolder(slot: GameSlotTarget) {
        let current: String
        let prompt: String
        switch slot {
        case .merged:
            current = gameDirPath
            prompt = "Select Merged CTR v1.21 Game Folder (or Base / Update Dump)"
        case .base:
            current = baseDirPath
            prompt = "Select CTR Base Game Dump (CUSA13795 or CUSA14876)"
        case .update:
            current = updateDirPath
            prompt = "Select CTR Update 1.21 Dump"
        }

        guard let rawPicked = chooseFolder(title: prompt, startingAt: current) else { return }
        let normalized = Self.resolveGameRoot(rawPicked)

        Task {
            let analyzed = await Task.detached(priority: .userInitiated) {
                Self.analyzeDumpFolder(normalized)
            }.value

            // Auto-route folder based on param.sfo category/version just like upstream launcher!
            switch analyzed.kind {
            case .complete:
                gameDirPath = normalized.path
                gameInfo = analyzed
                saveLauncherIni()
                if analyzed.isSplitPkgLayout {
                    await mergeFolders(sources: [normalized])
                } else {
                    await verifyCompleteGameFolder()
                }
            case .base:
                baseDirPath = normalized.path
                baseInfo = analyzed
                saveLauncherIni()
            case .update:
                updateDirPath = normalized.path
                updateInfo = analyzed
                saveLauncherIni()
            default:
                switch slot {
                case .merged:
                    gameDirPath = normalized.path
                    gameInfo = analyzed
                case .base:
                    baseDirPath = normalized.path
                    baseInfo = analyzed
                case .update:
                    updateDirPath = normalized.path
                    updateInfo = analyzed
                }
                saveLauncherIni()
            }
        }
    }

    enum GameSlotTarget {
        case merged
        case base
        case update
    }

    func inspectGameFolders() async {
        let gPath = gameDirPath
        let bPath = baseDirPath
        let uPath = updateDirPath

        let (gInfo, bInfo, uInfo) = await Task.detached(priority: .utility) {
            (
                gPath.isEmpty ? GameFolderInfo() : Self.analyzeDumpFolder(URL(fileURLWithPath: gPath)),
                bPath.isEmpty ? GameFolderInfo() : Self.analyzeDumpFolder(URL(fileURLWithPath: bPath)),
                uPath.isEmpty ? GameFolderInfo() : Self.analyzeDumpFolder(URL(fileURLWithPath: uPath))
            )
        }.value

        gameInfo = gInfo
        baseInfo = bInfo
        updateInfo = uInfo

        if gInfo.kind == .complete && !gInfo.isSplitPkgLayout {
            await verifyCompleteGameFolder()
        } else {
            gameCheckPassed = false
            gameCheckMessage = gInfo.statusSummary
        }
    }

    func verifyCompleteGameFolder() async {
        guard !gameDirPath.isEmpty else {
            gameCheckPassed = false
            gameCheckMessage = "Select your CTR Nitro-Fueled v1.21 folder to begin."
            return
        }
        guard let python = envStatus.pythonPath else {
            gameCheckPassed = (gameInfo.kind == .complete)
            gameCheckMessage = gameInfo.statusSummary
            return
        }

        let checkScript = engineRootURL.appendingPathComponent("scripts/game_check.py").path
        let folder = gameDirPath
        let result = await Task.detached(priority: .utility) {
            Self.runCommandSync(executable: python, arguments: ["-X", "utf8", checkScript, folder])
        }.value

        if result.exitCode == 0 {
            gameCheckPassed = true
            let profile = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            gameCheckMessage = "Verified \(gameInfo.regionBadge) v\(gameInfo.version) (\(profile.isEmpty ? "ctr" : profile)) — \(gameInfo.formattedSize)"
        } else {
            gameCheckPassed = false
            gameCheckMessage = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        reloadPatches()
        reloadSaves()
    }

    var canMergeBaseAndUpdate: Bool {
        baseInfo.kind == .base && updateInfo.kind == .update && baseInfo.titleID == updateInfo.titleID && !isMerging
    }

    func mergeBaseAndUpdate() {
        guard canMergeBaseAndUpdate else { return }
        let baseURL = URL(fileURLWithPath: baseDirPath)
        let updateURL = URL(fileURLWithPath: updateDirPath)
        Task {
            await mergeFolders(sources: [baseURL, updateURL])
        }
    }

    private func mergeFolders(sources: [URL]) async {
        guard let first = sources.first else { return }
        isMerging = true
        mergeCompletedFiles = 0
        mergeTotalFiles = 0
        clearNotice()

        let title = activeTitleID
        let parent = first.deletingLastPathComponent()
        var target = parent.appendingPathComponent("\(title)-1.21", isDirectory: true)
        if sources.contains(target) || target.path == gameDirPath {
            target = parent.appendingPathComponent("\(title)-1.21-merged", isDirectory: true)
        }

        appendLog("Merging \(sources.map(\.lastPathComponent).joined(separator: " + ")) -> \(target.path)...")

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(URL, Int, Int), Error> in
            let fm = FileManager.default
            var allEntries: [(source: URL, relativePath: String)] = []
            for source in sources {
                allEntries.append(contentsOf: Self.collectLayoutFiles(in: source))
            }

            let total = allEntries.count
            await MainActor.run {
                self.mergeTotalFiles = total
            }

            var copiedCount = 0
            do {
                for (index, item) in allEntries.enumerated() {
                    let dest = target.appendingPathComponent(item.relativePath)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    do {
                        try fm.linkItem(at: item.source, to: dest)
                    } catch {
                        try fm.copyItem(at: item.source, to: dest)
                        copiedCount += 1
                    }
                    if index % 25 == 0 || index + 1 == total {
                        let done = index + 1
                        await MainActor.run {
                            self.mergeCompletedFiles = done
                        }
                    }
                }
                return .success((target, total, copiedCount))
            } catch {
                return .failure(error)
            }
        }.value

        isMerging = false
        switch outcome {
        case .success(let (mergedURL, total, copied)):
            gameDirPath = mergedURL.path
            saveLauncherIni()
            appendLog("Merged \(total) files into \(mergedURL.path) (\(copied) copied across volumes).")
            postNotice("Successfully prepared \(mergedURL.lastPathComponent) (\(total) files).")
            await inspectGameFolders()
        case .failure(let error):
            postNotice("Merge failed: \(error.localizedDescription)", isError: true)
            appendLog("Merge error: \(error.localizedDescription)")
        }
    }

    // MARK: - Build Mac x86_64 Runtime (Rosetta 2 + KosmicKrisp)

    func buildMacRuntime(installDepsFirst: Bool = false) {
        guard !isBuildingEngine, !isGameRunning else { return }
        isBuildingEngine = true
        selectedSection = .logs
        consoleLines.removeAll()
        let scriptName = installDepsFirst ? "tools/setup_mac_deps.sh" : "build.sh"
        appendLog("=== Running \(scriptName) in \(engineRootURL.path) ===")

        let scriptURL = engineRootURL.appendingPathComponent(scriptName)
        let rootURL = engineRootURL

        Task {
            let code = await runStreamingProcess(
                executable: "/bin/bash",
                arguments: [scriptURL.path],
                currentDirectory: rootURL,
                environmentOverrides: [
                    "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                ]
            )
            isBuildingEngine = false
            await probeEnvironment()
            if code == 0 {
                postNotice(installDepsFirst ? "macOS x86_64 dependencies bootstrapped!" : "macOS x86_64 runtime build succeeded!")
            } else {
                postNotice("\(scriptName) exited with code \(code). Check Console Log for details.", isError: true)
            }
        }
    }

    // MARK: - Launch & Stop CTR Nitro-Fueled

    var canLaunchGame: Bool {
        !isGameRunning && !isMerging && !isBuildingEngine
            && gameInfo.kind == .complete
            && !gameInfo.isSplitPkgLayout
            && envStatus.rosettaInstalled
            && envStatus.pythonPath != nil
            && envStatus.sacredfireBinaryPath != nil
    }

    func launchGame(clearShaderCache: Bool = false) {
        guard canLaunchGame, let pythonPath = envStatus.pythonPath else {
            if envStatus.sacredfireBinaryPath == nil {
                postNotice("sacredfire binary is not built yet — open 'Mac Port & Build' to compile it.", isError: true)
            } else if !envStatus.rosettaInstalled {
                postNotice("Rosetta 2 is required. Run: softwareupdate --install-rosetta --agree-to-license", isError: true)
            }
            return
        }

        saveGameIni()
        saveLauncherIni()
        clearNotice()
        consoleLines.removeAll()
        isGameRunning = true
        lastStatusLine = "Launching CTR Nitro-Fueled..."

        let renderRes = gameIni.string("render_res", default: "1080")
        let driverChoice = GraphicsDriverChoice(rawValue: launcherIni.string("graphics_driver", default: "auto")) ?? .automatic

        var env: [String: String] = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "BB_GAME_DIR": gameDirPath,
            "BB_DATA_DIR": dataRootURL.path,
            "BB_USER_DIR": dataRootURL.appendingPathComponent("user").path,
            "BB_CONFIG": gameIniURL.path,
            "BB_PATCHES_CONFIG": patchesJsonURL.path,
            "BB_DLC_DIR": dataRootURL.appendingPathComponent("dlc").path,
            "BB_NEO": renderRes != "1080" ? "1" : "0",
            "BB_LANGUAGE": effectiveGameLanguageCode(),
            "BB_PRESENT_MODE": launcherIni.string("present_mode", default: "Mailbox"),
            "BB_MENU_LANGUAGE": "en",
            "BB_DLC": launcherIni.bool("dlc", default: true) ? "1" : "0",
            "BB_DLC_DISABLED": launcherIni.string("dlc_disabled"),
            "BB_GRAPHICS_DRIVER": driverChoice.rawValue,
            "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8",
        ]

        if let binPath = envStatus.sacredfireBinaryPath {
            env["BB_PROBE"] = binPath
        }
        let gamepad = launcherIni.string("gamepad")
        if !gamepad.isEmpty {
            env["BB_GAMEPAD"] = gamepad
        }
        if launcherIni.bool("save_log", default: false) {
            env["BB_SAVE_LOG"] = "1"
        }
        if clearShaderCache {
            env["BB_CLEAR_SHADER_CACHE"] = "1"
        }

        // Select KosmicKrisp (Metal 4 Vulkan 1.4) or MoltenVK ICD explicitly when discovered
        switch driverChoice {
        case .automatic, .kosmicKrisp:
            if envStatus.supportsMetal4KosmicKrisp, let kkICD = envStatus.kosmicKrispICDPath {
                env["VK_DRIVER_FILES"] = kkICD
                env["VK_ICD_FILENAMES"] = kkICD
            } else if let mvkICD = envStatus.moltenVKICDPath {
                env["VK_DRIVER_FILES"] = mvkICD
                env["VK_ICD_FILENAMES"] = mvkICD
                env["MVK_FORCE_RETAIN"] = "1"
            }
        case .moltenVK:
            if let mvkICD = envStatus.moltenVKICDPath {
                env["VK_DRIVER_FILES"] = mvkICD
                env["VK_ICD_FILENAMES"] = mvkICD
                env["MVK_FORCE_RETAIN"] = "1"
            }
        }

        let runPy = engineRootURL.appendingPathComponent("run.py").path
        let rootURL = engineRootURL

        Task {
            let exitCode = await runStreamingProcess(
                executable: pythonPath,
                arguments: ["-X", "utf8", runPy],
                currentDirectory: rootURL,
                environmentOverrides: env
            )
            isGameRunning = false
            if exitCode == 0 {
                lastStatusLine = "Game exited cleanly."
            } else {
                lastStatusLine = "Game exited with status \(exitCode)."
                if exitCode != 0 && exitCode != 15 && exitCode != 130 {
                    postNotice("CTR Nitro-Fueled exited with code \(exitCode). Inspect Console Log for details.", isError: true)
                }
            }
            reloadSaves()
        }
    }

    func stopRunningProcess() {
        if activeProcessGroupID > 0 {
            kill(-activeProcessGroupID, SIGTERM)
        }
        activeProcess?.terminate()
        appendLog("--- Stop requested by user ---")
    }

    func clearShaderCacheNow() {
        let cacheDir = dataRootURL
            .appendingPathComponent("user/cache")
            .appendingPathComponent(activeTitleID)
        do {
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.removeItem(at: cacheDir)
            }
            postNotice("Cleared compiled shader cache for \(activeTitleID).")
        } catch {
            postNotice("Could not clear shader cache: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Language Choices

    var availableGameLanguages: [SettingChoice] {
        if isEuropeanEdition {
            return [
                SettingChoice(label: "English (UK)", value: "18"),
                SettingChoice(label: "Spanish (Spain)", value: "3"),
                SettingChoice(label: "French", value: "2"),
                SettingChoice(label: "German", value: "4"),
                SettingChoice(label: "Italian", value: "5"),
                SettingChoice(label: "Arabic", value: "21"),
            ]
        } else {
            return [
                SettingChoice(label: "English (US)", value: "1"),
                SettingChoice(label: "Spanish (Latin America)", value: "20"),
                SettingChoice(label: "French", value: "2"),
                SettingChoice(label: "Portuguese (Brazil)", value: "17"),
            ]
        }
    }

    func effectiveGameLanguageCode() -> String {
        let saved = launcherIni.string("language")
        let valid = Set(availableGameLanguages.map(\.value))
        if valid.contains(saved) {
            return saved
        }
        return isEuropeanEdition ? "18" : "1"
    }

    // MARK: - XML Patches & patches.json

    private static let iniBackedPatches: [String: String] = [
        "CrashTeamRacing.xml/60 FPS Unlock": "patch_60fps",
        "CrashTeamRacing.xml/Disable Motion Blur": "patch_no_motion_blur",
        "CrashTeamRacing.xml/Resolution Patch (1080p for PS4 Pro)": "patch_pro_1080p",
    ]

    func reloadPatches() {
        let patchesDir = engineRootURL.appendingPathComponent("patches")
        guard let files = try? FileManager.default.contentsOfDirectory(at: patchesDir, includingPropertiesForKeys: nil) else {
            patches = []
            return
        }

        let (enabledSet, disabledSet) = readPatchesJson()
        let titleID = activeTitleID
        var loaded: [PatchEntry] = []

        for file in files.filter({ $0.pathExtension.lowercased() == "xml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let xml = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ids = Self.extractXmlTagContents(tag: "ID", in: xml)
            if !ids.isEmpty && !ids.contains(titleID) {
                continue
            }

            let fileName = file.lastPathComponent
            let canonicalFile = (fileName == "CrashTeamRacingEU.xml") ? "CrashTeamRacing.xml" : fileName

            for attrs in Self.extractMetadataAttributes(in: xml) {
                let appVer = attrs["AppVer"] ?? ""
                let appElf = attrs["AppElf"] ?? ""
                guard appVer == CTRConstants.requiredUpdateVersion,
                      appElf.isEmpty || appElf == "eboot.bin" else {
                    continue
                }
                let name = attrs["Name"] ?? "Unnamed Patch"
                let key = "\(canonicalFile)/\(name)"
                let defaultOn = (attrs["isEnabled"] ?? "").lowercased() == "true"
                let iniKey = Self.iniBackedPatches[key]

                let isEnabled: Bool
                if let iniKey {
                    isEnabled = gameIni.bool(iniKey, default: defaultOn)
                } else if enabledSet.contains(key) {
                    isEnabled = true
                } else if disabledSet.contains(key) {
                    isEnabled = false
                } else {
                    isEnabled = defaultOn
                }

                loaded.append(
                    PatchEntry(
                        key: key,
                        name: name,
                        author: attrs["Author"] ?? "",
                        note: attrs["Note"] ?? "",
                        version: attrs["PatchVer"] ?? "",
                        defaultOn: defaultOn,
                        iniKey: iniKey,
                        isEnabled: isEnabled
                    )
                )
            }
        }
        patches = loaded
    }

    func setPatchEnabled(_ patch: PatchEntry, enabled: Bool) {
        if let index = patches.firstIndex(where: { $0.key == patch.key }) {
            patches[index].isEnabled = enabled
        }
        if let iniKey = patch.iniKey {
            gameIni.setBool(iniKey, enabled)
            saveGameIni()
        } else {
            var (enabledList, disabledList) = readPatchesJson()
            enabledList.remove(patch.key)
            disabledList.remove(patch.key)
            if enabled != patch.defaultOn {
                if enabled {
                    enabledList.insert(patch.key)
                } else {
                    disabledList.insert(patch.key)
                }
            }
            writePatchesJson(enabled: enabledList, disabled: disabledList)
        }
    }

    private func readPatchesJson() -> (Set<String>, Set<String>) {
        guard let data = try? Data(contentsOf: patchesJsonURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        let enabled = Set((obj["enabled"] as? [String]) ?? [])
        let disabled = Set((obj["disabled"] as? [String]) ?? [])
        return (enabled, disabled)
    }

    private func writePatchesJson(enabled: Set<String>, disabled: Set<String>) {
        let payload: [String: [String]] = [
            "enabled": enabled.sorted(),
            "disabled": disabled.sorted(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: patchesJsonURL, options: .atomic)
        }
    }

    // MARK: - Save Data Management

    var activeSaveRootURL: URL {
        let base = dataRootURL.appendingPathComponent("user/savedata", isDirectory: true)
        if let users = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for userURL in users {
                let candidate = userURL.appendingPathComponent(activeTitleID, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return base.appendingPathComponent("1/\(activeTitleID)", isDirectory: true)
    }

    var backupsRootURL: URL {
        dataRootURL.appendingPathComponent("backups", isDirectory: true)
    }

    func reloadSaves() {
        let fm = FileManager.default
        let saveRoot = activeSaveRootURL
        var slots: [SaveSlotEntry] = []

        if let items = try? fm.contentsOfDirectory(at: saveRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) {
            for item in items {
                let name = item.lastPathComponent
                guard !name.hasSuffix(".sce_sys"), !name.hasSuffix(".memory"), !name.hasPrefix(".") else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

                let metaParam = saveRoot.appendingPathComponent("\(name).sce_sys/param.bin")
                let (title, subtitle, detail) = Self.readOrbisSaveParam(from: metaParam)
                let bytes = Self.directorySize(at: item)
                let modified = Self.formattedModificationDate(for: item)

                slots.append(
                    SaveSlotEntry(
                        directoryName: name,
                        title: title.isEmpty ? name : title,
                        subtitle: subtitle,
                        detail: detail,
                        modifiedDate: modified,
                        bytes: bytes,
                        path: item
                    )
                )
            }
        }
        saveSlots = slots.sorted { $0.directoryName < $1.directoryName }

        var backups: [SaveBackupEntry] = []
        if let items = try? fm.contentsOfDirectory(at: backupsRootURL, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("saves-") {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                backups.append(
                    SaveBackupEntry(
                        name: item.lastPathComponent,
                        modifiedDate: Self.formattedModificationDate(for: item),
                        bytes: Self.directorySize(at: item),
                        path: item
                    )
                )
            }
        }
        saveBackups = backups.sorted { $0.name > $1.name }
    }

    func createSaveBackup(label: String = "manual") {
        let fm = FileManager.default
        guard !saveSlots.isEmpty else {
            postNotice("No save data exists yet to back up.", isError: true)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dest = backupsRootURL.appendingPathComponent("saves-\(stamp)-\(label)", isDirectory: true)
        do {
            try fm.createDirectory(at: backupsRootURL, withIntermediateDirectories: true)
            try fm.copyItem(at: activeSaveRootURL, to: dest)
            reloadSaves()
            postNotice("Created save backup '\(dest.lastPathComponent)'.")
        } catch {
            postNotice("Backup failed: \(error.localizedDescription)", isError: true)
        }
    }

    func restoreSaveBackup(_ backup: SaveBackupEntry) {
        let fm = FileManager.default
        if !saveSlots.isEmpty {
            createSaveBackup(label: "pre-restore")
        }
        do {
            if fm.fileExists(atPath: activeSaveRootURL.path) {
                try fm.removeItem(at: activeSaveRootURL)
            }
            try fm.createDirectory(at: activeSaveRootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: backup.path, to: activeSaveRootURL)
            reloadSaves()
            postNotice("Restored save backup '\(backup.name)'.")
        } catch {
            postNotice("Restore failed: \(error.localizedDescription)", isError: true)
        }
    }

    func deleteSaveBackup(_ backup: SaveBackupEntry) {
        do {
            try FileManager.default.removeItem(at: backup.path)
            reloadSaves()
        } catch {
            postNotice("Could not remove backup: \(error.localizedDescription)", isError: true)
        }
    }

    func importSaveFolder() {
        guard let picked = chooseFolder(title: "Select Decrypted PS4 Save (with sce_sys/param.sfo) or Save Backup") else {
            return
        }
        let fm = FileManager.default
        let sfoURL = picked.appendingPathComponent("sce_sys/param.sfo")

        if fm.fileExists(atPath: sfoURL.path) {
            let sfo = SfoParser.parse(url: sfoURL)
            guard let slotDir = sfo["SAVEDATA_DIRECTORY"], !slotDir.isEmpty, !slotDir.contains("/") else {
                postNotice("param.sfo is missing a valid SAVEDATA_DIRECTORY.", isError: true)
                return
            }
            if !saveSlots.isEmpty {
                createSaveBackup(label: "pre-import")
            }
            let target = activeSaveRootURL.appendingPathComponent(slotDir, isDirectory: true)
            let meta = activeSaveRootURL.appendingPathComponent("\(slotDir).sce_sys", isDirectory: true)
            do {
                try? fm.removeItem(at: target)
                try? fm.removeItem(at: meta)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.createDirectory(at: meta, withIntermediateDirectories: true)
                for item in try fm.contentsOfDirectory(at: picked, includingPropertiesForKeys: nil)
                where item.lastPathComponent != "sce_sys" {
                    try fm.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
                }
                let paramBin = Self.makeOrbisSaveParam(
                    title: sfo["MAINTITLE"] ?? "",
                    subtitle: sfo["SUBTITLE"] ?? "",
                    detail: sfo["DETAIL"] ?? ""
                )
                try paramBin.write(to: meta.appendingPathComponent("param.bin"), options: .atomic)
                let iconURL = picked.appendingPathComponent("sce_sys/icon0.png")
                if fm.fileExists(atPath: iconURL.path) {
                    try? fm.copyItem(at: iconURL, to: meta.appendingPathComponent("icon0.png"))
                }
                reloadSaves()
                postNotice("Imported decrypted PS4 save slot '\(slotDir)'.")
            } catch {
                postNotice("Save import failed: \(error.localizedDescription)", isError: true)
            }
        } else {
            // Runtime layout folder (<slot> + <slot>.sce_sys)
            if !saveSlots.isEmpty {
                createSaveBackup(label: "pre-import")
            }
            do {
                try? fm.removeItem(at: activeSaveRootURL)
                try fm.createDirectory(at: activeSaveRootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: picked, to: activeSaveRootURL)
                reloadSaves()
                postNotice("Imported save folder '\(picked.lastPathComponent)'.")
            } catch {
                postNotice("Save import failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - DLC Management

    var dlcRootURL: URL {
        dataRootURL.appendingPathComponent("dlc", isDirectory: true)
    }

    func reloadDLC() {
        let fm = FileManager.default
        let disabledLabels = Set(
            launcherIni.string("dlc_disabled")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        guard let items = try? fm.contentsOfDirectory(at: dlcRootURL, includingPropertiesForKeys: nil) else {
            dlcPackages = []
            return
        }

        var entries: [DlcPackageEntry] = []
        for item in items.filter({ $0.pathExtension.lowercased() == "pkg" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let (valid, label, note) = Self.inspectPkgHeader(at: item)
            let key = label.isEmpty ? item.lastPathComponent : label
            entries.append(
                DlcPackageEntry(
                    fileName: item.lastPathComponent,
                    contentLabel: label,
                    statusNote: note,
                    isValid: valid,
                    path: item,
                    isEnabled: !disabledLabels.contains(key)
                )
            )
        }
        dlcPackages = entries
    }

    func addDlcPackages() {
        let urls = chooseFiles(title: "Select CTR Nitro-Fueled Add-On .pkg Files", allowedExtensions: ["pkg"])
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dlcRootURL, withIntermediateDirectories: true)
        var added = 0
        for src in urls {
            let dest = dlcRootURL.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: src, to: dest)) != nil {
                added += 1
            }
        }
        reloadDLC()
        postNotice("Installed \(added) DLC package(s).")
    }

    func setDlcPackageEnabled(_ pkg: DlcPackageEntry, enabled: Bool) {
        var disabled = Set(
            launcherIni.string("dlc_disabled")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        let idKey = pkg.contentLabel.isEmpty ? pkg.fileName : pkg.contentLabel
        if enabled {
            disabled.remove(idKey)
        } else {
            disabled.insert(idKey)
        }
        launcherIni.set("dlc_disabled", disabled.sorted().joined(separator: ","))
        saveLauncherIni()
        reloadDLC()
    }

    func removeDlcPackage(_ pkg: DlcPackageEntry) {
        try? FileManager.default.removeItem(at: pkg.path)
        reloadDLC()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Streaming Subprocess Runner

    func appendLog(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 2000 {
            consoleLines.removeFirst(consoleLines.count - 2000)
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            lastStatusLine = line
        }
    }

    private func runStreamingProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environmentOverrides: [String: String]
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environmentOverrides {
            if v.isEmpty {
                env.removeValue(forKey: k)
            } else {
                env[k] = v
            }
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            let lines = chunk.components(separatedBy: "\n")
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines where !line.isEmpty {
                    self.appendLog(line)
                }
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            setpgid(pid, pid)
            self.activeProcess = process
            self.activeProcessGroupID = pid
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog("Failed to start \(executable): \(error.localizedDescription)")
            return -1
        }

        let exitCode = await Task.detached(priority: .utility) { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        pipe.fileHandleForReading.readabilityHandler = nil
        self.activeProcess = nil
        self.activeProcessGroupID = 0
        return exitCode
    }

    // MARK: - Nonisolated Filesystem & Binary Helpers

    nonisolated private static func findExecutable(named name: String, extraDirs: [String]) -> String? {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for dir in extraDirs + pathDirs {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func runCommandSync(executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    nonisolated private static func findDumpLayout(in dir: URL) -> (files: URL, sys: URL, isSplit: Bool)? {
        let fm = FileManager.default
        let flatEboot = dir.appendingPathComponent("eboot.bin")
        let flatSfo = dir.appendingPathComponent("sce_sys/param.sfo")
        let image0 = dir.appendingPathComponent("Image0")
        let image0Eboot = image0.appendingPathComponent("eboot.bin")

        if fm.fileExists(atPath: flatEboot.path),
           fm.fileExists(atPath: flatSfo.path),
           (!fm.fileExists(atPath: image0Eboot.path) || fm.fileExists(atPath: dir.appendingPathComponent("sce_module").path)) {
            return (dir, dir.appendingPathComponent("sce_sys"), false)
        }

        if fm.fileExists(atPath: image0Eboot.path) {
            for sysCandidate in [
                image0.appendingPathComponent("sce_sys"),
                dir.appendingPathComponent("Sc0"),
                dir.appendingPathComponent("sce_sys"),
            ] where fm.fileExists(atPath: sysCandidate.appendingPathComponent("param.sfo").path) {
                return (image0, sysCandidate, true)
            }
        }
        return nil
    }

    nonisolated private static func resolveGameRoot(_ dir: URL) -> URL {
        if findDumpLayout(in: dir) != nil {
            return dir
        }
        if dir.lastPathComponent.lowercased() == "image0",
           findDumpLayout(in: dir.deletingLastPathComponent()) != nil {
            return dir.deletingLastPathComponent()
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return dir
        }
        var singleMatch: URL?
        for child in children {
            if findDumpLayout(in: child) != nil {
                if singleMatch != nil {
                    return dir
                }
                singleMatch = child
            }
        }
        return singleMatch ?? dir
    }

    nonisolated private static func analyzeDumpFolder(_ dir: URL) -> GameFolderInfo {
        var info = GameFolderInfo(path: dir.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            info.kind = .missing
            return info
        }
        guard let layout = findDumpLayout(in: dir) else {
            info.kind = .notGame
            return info
        }
        info.isSplitPkgLayout = layout.isSplit

        // Verify decrypted ELF vs encrypted PS4 FSELF (\x4F\x15\x3D\x1D)
        let ebootURL = layout.files.appendingPathComponent("eboot.bin")
        if let fh = try? FileHandle(forReadingFrom: ebootURL) {
            let magic = (try? fh.read(upToCount: 4)) ?? Data()
            try? fh.close()
            if magic.count == 4 && !(magic[0] == 0x7F && magic[1] == 0x45 && magic[2] == 0x4C && magic[3] == 0x46) {
                info.kind = .encryptedSelf
                return info
            }
        }

        let sfo = SfoParser.parse(url: layout.sys.appendingPathComponent("param.sfo"))
        info.titleID = sfo["TITLE_ID"] ?? ""
        info.titleName = sfo["TITLE"] ?? ""
        info.version = sfo["APP_VER"] ?? ""
        info.category = sfo["CATEGORY"] ?? ""

        guard CTRConstants.supportedTitleIDs.contains(info.titleID) else {
            info.kind = .otherTitle
            return info
        }
        if info.category == "gd" {
            info.bytes = directorySize(at: layout.isSplit ? layout.files : dir)
            info.kind = .base
        } else if info.version != CTRConstants.requiredUpdateVersion {
            info.kind = .otherVersion
        } else {
            info.bytes = directorySize(at: layout.isSplit ? layout.files : dir)
            info.kind = info.bytes >= CTRConstants.completeGameMinBytes ? .complete : .update
        }
        return info
    }

    nonisolated private static func collectLayoutFiles(in dir: URL) -> [(source: URL, relativePath: String)] {
        guard let layout = findDumpLayout(in: dir) else { return [] }
        var results: [(URL, String)] = []

        func walk(_ base: URL, prefix: String) {
            let baseComponents = base.standardizedFileURL.pathComponents
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let fileURL as URL in enumerator {
                guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                      vals.isRegularFile == true else { continue }
                let comps = fileURL.standardizedFileURL.pathComponents
                guard comps.count > baseComponents.count else { continue }
                let rel = comps.dropFirst(baseComponents.count).joined(separator: "/")
                let fullRel = prefix.isEmpty ? rel : "\(prefix)/\(rel)"
                results.append((fileURL, fullRel))
            }
        }

        walk(layout.files, prefix: "")
        if layout.isSplit && layout.sys.standardizedFileURL != layout.files.appendingPathComponent("sce_sys").standardizedFileURL {
            walk(layout.sys, prefix: "sce_sys")
        }
        return results
    }

    nonisolated private static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               vals.isRegularFile == true,
               let size = vals.fileSize {
                total += UInt64(max(0, size))
            }
        }
        return total
    }

    nonisolated private static func formattedModificationDate(for url: URL) -> String {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = vals?.contentModificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated private static func readOrbisSaveParam(from url: URL) -> (String, String, String) {
        guard let data = try? Data(contentsOf: url), data.count >= 1280 else {
            return ("", "", "")
        }
        func cString(_ range: Range<Int>) -> String {
            let slice = data[range]
            if let zero = slice.firstIndex(of: 0) {
                return String(decoding: data[range.lowerBound..<zero], as: UTF8.self)
            }
            return String(decoding: slice, as: UTF8.self)
        }
        return (cString(0..<128), cString(128..<256), cString(256..<1280))
    }

    nonisolated private static func makeOrbisSaveParam(title: String, subtitle: String, detail: String) -> Data {
        var data = Data(count: 1328)
        func writeFixed(_ str: String, offset: Int, maxLen: Int) {
            let bytes = Array(str.utf8.prefix(maxLen - 1))
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        writeFixed(title, offset: 0, maxLen: 128)
        writeFixed(subtitle, offset: 128, maxLen: 128)
        writeFixed(detail, offset: 256, maxLen: 1024)
        var mtime = Int64(Date().timeIntervalSince1970).littleEndian
        withUnsafeBytes(of: &mtime) { ptr in
            data.replaceSubrange(1288..<1296, with: ptr)
        }
        return data
    }

    nonisolated private static func inspectPkgHeader(at url: URL) -> (Bool, String, String) {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return (false, "", "Cannot read file")
        }
        let header = (try? fh.read(upToCount: 0x80)) ?? Data()
        try? fh.close()
        guard header.count >= 0x70,
              header[0] == 0x7F, header[1] == 0x43, header[2] == 0x4E, header[3] == 0x54 else { // "\x7FCNT"
            return (false, "", "Not a PS4 PKG header")
        }
        let contentIDSlice = header[0x40..<0x64]
        let endIdx = contentIDSlice.firstIndex(of: 0) ?? contentIDSlice.endIndex
        let contentID = String(decoding: header[0x40..<endIdx], as: UTF8.self)
        let parts = contentID.split(separator: "-")
        let label = parts.count >= 3 ? String(parts[2]) : contentID
        return (true, label, contentID)
    }

    // Simple XML helpers matching upstream patches/*.xml
    nonisolated private static func extractXmlTagContents(tag: String, in xml: String) -> [String] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var results: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let openRange = xml.range(of: open, range: searchRange),
              let closeRange = xml.range(of: close, range: openRange.upperBound..<xml.endIndex) {
            let val = xml[openRange.upperBound..<closeRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(val)
            searchRange = closeRange.upperBound..<xml.endIndex
        }
        return results
    }

    nonisolated private static func extractMetadataAttributes(in xml: String) -> [[String: String]] {
        var list: [[String: String]] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let start = xml.range(of: "<Metadata", range: searchRange),
              let end = xml.range(of: ">", range: start.upperBound..<xml.endIndex) {
            let body = String(xml[start.upperBound..<end.lowerBound])
            list.append(parseXmlAttributes(body))
            searchRange = end.upperBound..<xml.endIndex
        }
        return list
    }

    nonisolated private static func parseXmlAttributes(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace || (i < chars.count && chars[i] == "/") {
                i += 1
            }
            let nameStart = i
            while i < chars.count && chars[i] != "=" && !chars[i].isWhitespace {
                i += 1
            }
            let name = String(chars[nameStart..<i])
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "=" else { break }
            i += 1
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "\"" || chars[i] == "'" else { break }
            let quote = chars[i]
            i += 1
            let valStart = i
            while i < chars.count && chars[i] != quote { i += 1 }
            let rawVal = String(chars[valStart..<i])
            out[name] = rawVal
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            if i < chars.count { i += 1 }
        }
        return out
    }
}
