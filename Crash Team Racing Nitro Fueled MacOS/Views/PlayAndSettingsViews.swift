import SwiftUI

// MARK: - Play Tab

struct PlaySectionView: View {
    @Bindable var store: LauncherStore
    @Namespace private var heroNamespace
    @State private var showMergeDrawer: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard

                readinessGrid

                gameFolderSection

                quickLaunchOptionsSection
            }
            .padding(24)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "flag.checkered.2.crossed")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.orange.gradient)
                    .frame(width: 64, height: 64)
                    .background(.orange.opacity(0.15), in: .rect(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("CTR Nitro-Fueled")
                            .font(.title.bold())
                        Text("macOS Apple Silicon")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }

                    Text("Rosetta 2 x86_64 PS4 Guest Runtime • Mesa KosmicKrisp Vulkan 1.4 on Metal 4")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(store.gameCheckMessage.isEmpty ? store.gameInfo.statusSummary : store.gameCheckMessage)
                        .font(.callout)
                        .foregroundStyle(store.gameInfo.kind == .complete ? .primary : .secondary)
                        .padding(.top, 2)
                }

                Spacer()
            }

            Divider()

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 12) {
                    if store.isGameRunning {
                        Button {
                            store.stopRunningProcess()
                        } label: {
                            Label("Stop Game", systemImage: "stop.fill")
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .glassEffectID("primaryAction", in: heroNamespace)
                    } else {
                        Button {
                            store.launchGame()
                        } label: {
                            Label("Play CTR Nitro-Fueled", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                        .disabled(!store.canLaunchGame)
                        .glassEffectID("primaryAction", in: heroNamespace)
                    }

                    if store.envStatus.sacredfireBinaryPath == nil {
                        Button {
                            store.selectedSection = .engine
                        } label: {
                            Label("Build Runtime", systemImage: "hammer.fill")
                        }
                        .buttonStyle(.glass)
                    }

                    Button {
                        store.selectedSection = .logs
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Text(store.lastStatusLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private var readinessGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            StatusBadgeCard(
                title: "Rosetta 2 + AVX",
                detail: store.envStatus.rosettaInstalled
                    ? "Active (macOS \(store.envStatus.macOSVersionString))"
                    : "Not installed",
                icon: "cpu",
                isReady: store.envStatus.rosettaInstalled && store.envStatus.supportsAVXUnderRosetta
            )

            StatusBadgeCard(
                title: "Vulkan on Metal",
                detail: store.envStatus.kosmicKrispICDPath != nil
                    ? "KosmicKrisp Ready (Metal 4)"
                    : (store.envStatus.moltenVKICDPath != nil ? "MoltenVK Fallback Found" : "ICD Not Installed Yet"),
                icon: "sparkles.tv",
                isReady: store.envStatus.kosmicKrispICDPath != nil || store.envStatus.moltenVKICDPath != nil
            )

            StatusBadgeCard(
                title: "SacredFire Runtime",
                detail: store.envStatus.sacredfireBinaryPath != nil
                    ? URL(fileURLWithPath: store.envStatus.sacredfireBinaryPath ?? "").lastPathComponent
                    : "Needs x86_64 Compile",
                icon: "gearshape.2.fill",
                isReady: store.envStatus.sacredfireBinaryPath != nil
            )

            StatusBadgeCard(
                title: "CTR v01.21 Dump",
                detail: store.gameInfo.kind == .complete
                    ? "\(store.activeTitleID) (\(store.gameInfo.formattedSize))"
                    : "Select Game Folder",
                icon: "opticaldisc.fill",
                isReady: store.gameInfo.kind == .complete && !store.gameInfo.isSplitPkgLayout
            )
        }
    }

    private var gameFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Merged Game Folder (CTR v01.21)")
                            .font(.headline)
                        Text(store.gameDirPath.isEmpty ? "Choose your decrypted CUSA13795 or CUSA14876 1.21 dump." : store.gameDirPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choose Folder…") {
                        store.selectGameFolder(slot: .merged)
                    }
                    if !store.gameDirPath.isEmpty {
                        Button {
                            store.revealInFinder(URL(fileURLWithPath: store.gameDirPath))
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal in Finder")
                    }
                }

                Divider()

                DisclosureGroup(
                    isExpanded: Binding(
                        get: { showMergeDrawer || store.baseInfo.kind == .base || store.updateInfo.kind == .update || store.isMerging },
                        set: { showMergeDrawer = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Have separate Base Game (1.00) and Update (01.21) folders? Select both below to merge them instantaneously using APFS hard links without duplicating disk space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        folderPickerRow(
                            label: "Base Game (gd)",
                            path: store.baseDirPath,
                            summary: store.baseInfo.statusSummary
                        ) {
                            store.selectGameFolder(slot: .base)
                        }

                        folderPickerRow(
                            label: "Update 01.21 (gp)",
                            path: store.updateDirPath,
                            summary: store.updateInfo.statusSummary
                        ) {
                            store.selectGameFolder(slot: .update)
                        }

                        if store.isMerging {
                            ProgressView(
                                value: Double(store.mergeCompletedFiles),
                                total: Double(max(1, store.mergeTotalFiles))
                            ) {
                                Text("Merging files (\(store.mergeCompletedFiles) / \(store.mergeTotalFiles))…")
                                    .font(.caption)
                            }
                        } else {
                            HStack {
                                Button("Merge Base + Update 01.21") {
                                    store.mergeBaseAndUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.canMergeBaseAndUpdate)

                                if store.baseInfo.kind == .base && store.updateInfo.kind == .update && store.baseInfo.titleID != store.updateInfo.titleID {
                                    Text("Title ID mismatch (\(store.baseInfo.titleID) vs \(store.updateInfo.titleID))")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Merge Base Game + Update 01.21 Utility", systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(8)
        } label: {
            Label("Game Files", systemImage: "externaldrive.fill")
        }
    }

    private func folderPickerRow(label: String, path: String, summary: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(path.isEmpty ? summary : "\(path) — \(summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Select…", action: action)
                .controlSize(.small)
        }
    }

    private var quickLaunchOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Toggle("60 FPS Unlock Patch", isOn: Binding(
                        get: { store.gameIni.bool("patch_60fps", default: false) },
                        set: { newValue in
                            store.gameIni.setBool("patch_60fps", newValue)
                            store.saveGameIni()
                            store.reloadPatches()
                        }
                    ))

                    Toggle("Fullscreen", isOn: Binding(
                        get: { store.gameIni.bool("fullscreen", default: false) },
                        set: { newValue in
                            store.gameIni.setBool("fullscreen", newValue)
                            store.saveGameIni()
                        }
                    ))

                    Toggle("Show FPS Overlay", isOn: Binding(
                        get: { store.gameIni.bool("show_fps", default: false) },
                        set: { newValue in
                            store.gameIni.setBool("show_fps", newValue)
                            store.saveGameIni()
                        }
                    ))

                    Spacer()

                    Button("Clear Shader Cache") {
                        store.clearShaderCacheNow()
                    }
                    .controlSize(.small)
                }

                Text("Tip: Press Shift + W, F1, or L3 + R3 in-game to open the live SacredFire overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label("Quick Settings", systemImage: "bolt.fill")
        }
    }
}

private struct StatusBadgeCard: View {
    let title: String
    let detail: String
    let icon: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(isReady ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Display & Graphics Tab

struct GraphicsSectionView: View {
    @Bindable var store: LauncherStore

    private let renderResChoices: [SettingChoice] = [
        .init(label: "480p (854×480 — Performance)", value: "480"),
        .init(label: "720p (1280×720 — HD)", value: "720"),
        .init(label: "1080p (1920×1080 — Base PS4 Native)", value: "1080"),
        .init(label: "1440p (2560×1440 — PS4 Pro Path)", value: "1440"),
        .init(label: "1620p (2880×1620 — PS4 Pro High)", value: "1620"),
        .init(label: "2160p (3840×2160 — 4K UHD, 7 GiB Heap)", value: "2160"),
    ]

    private let outputResChoices: [SettingChoice] = [
        .init(label: "1280×720 (16:9)", value: "1280x720"),
        .init(label: "1920×1080 (16:9)", value: "1920x1080"),
        .init(label: "2560×1440 (16:9)", value: "2560x1440"),
        .init(label: "3840×2160 (16:9 4K)", value: "3840x2160"),
        .init(label: "2560×1080 (21:9 UltraWide)", value: "2560x1080"),
        .init(label: "3440×1440 (21:9 UltraWide)", value: "3440x1440"),
        .init(label: "5120×1440 (32:9 Super UltraWide)", value: "5120x1440"),
    ]

    private let aspectChoices: [SettingChoice] = [
        .init(label: "16:9 (Standard Widescreen)", value: "16:9"),
        .init(label: "21:9 (UltraWide)", value: "21:9"),
        .init(label: "32:9 (Super UltraWide)", value: "32:9"),
    ]

    private let upscalerChoices: [SettingChoice] = [
        .init(label: "AMD FSR 3.1 (Temporal AA + Upscaling — Recommended)", value: "fsr3"),
        .init(label: "AMD FSR 1.0 (Spatial EASU + RCAS)", value: "fsr1"),
        .init(label: "Off (Native Stretch)", value: "off"),
    ]

    private let presentModes: [SettingChoice] = [
        .init(label: "Mailbox (Low-Latency Triple Buffered — Recommended)", value: "Mailbox"),
        .init(label: "FIFO (Strict VSync)", value: "Fifo"),
        .init(label: "FIFO Relaxed", value: "FifoRelaxed"),
        .init(label: "Immediate (Uncapped Tear)", value: "Immediate"),
    ]

    private let fpsLimits: [SettingChoice] = [
        .init(label: "30 FPS (Console Default)", value: "30"),
        .init(label: "60 FPS (Recommended with 60 FPS Patch)", value: "60"),
        .init(label: "90 FPS", value: "90"),
        .init(label: "120 FPS (ProMotion Display)", value: "120"),
        .init(label: "144 FPS", value: "144"),
        .init(label: "240 FPS", value: "240"),
        .init(label: "Uncapped (0)", value: "0"),
    ]

    var body: some View {
        Form {
            Section("Apple Silicon Vulkan Backend") {
                Picker("Graphics Driver", selection: Binding(
                    get: { store.launcherIni.string("graphics_driver", default: "auto") },
                    set: {
                        store.launcherIni.set("graphics_driver", $0)
                        store.saveLauncherIni()
                    }
                )) {
                    ForEach(GraphicsDriverChoice.allCases) { driver in
                        Text(driver.title).tag(driver.rawValue)
                    }
                }

                Text("Mesa KosmicKrisp translates Vulkan 1.4 directly onto Metal 4 on macOS 26+, providing native geometry-shader execution for CTR's character fur without CPU fallbacks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Resolution & Display") {
                Picker("Internal Scene Resolution", selection: Binding(
                    get: { store.gameIni.string("render_res", default: "1080") },
                    set: {
                        store.gameIni.set("render_res", $0)
                        store.saveGameIni()
                    }
                )) {
                    ForEach(renderResChoices) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                Picker("Output Resolution", selection: Binding(
                    get: { store.gameIni.string("output_res", default: "1920x1080") },
                    set: {
                        store.gameIni.set("output_res", $0)
                        store.saveGameIni()
                    }
                )) {
                    ForEach(outputResChoices) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                Picker("Aspect Ratio", selection: Binding(
                    get: { store.gameIni.string("aspect_ratio", default: "16:9") },
                    set: {
                        store.gameIni.set("aspect_ratio", $0)
                        store.saveGameIni()
                    }
                )) {
                    ForEach(aspectChoices) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                Toggle("Start in Fullscreen", isOn: Binding(
                    get: { store.gameIni.bool("fullscreen", default: false) },
                    set: {
                        store.gameIni.setBool("fullscreen", $0)
                        store.saveGameIni()
                    }
                ))
            }

            Section("Upscaling & Frame Pacing") {
                Picker("Upscaler / Anti-Aliasing", selection: Binding(
                    get: { store.gameIni.string("temporal", default: "fsr3") },
                    set: {
                        store.gameIni.set("temporal", $0)
                        store.saveGameIni()
                    }
                )) {
                    ForEach(upscalerChoices) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                HStack {
                    Text("FSR Sharpness")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { store.gameIni.double("fsr3_sharpness", default: 0.3) },
                            set: {
                                store.gameIni.set("fsr3_sharpness", String(format: "%.2f", $0))
                                store.saveGameIni()
                            }
                        ),
                        in: 0.0...1.0,
                        step: 0.05
                    )
                    .frame(width: 200)
                    Text(String(format: "%.2f", store.gameIni.double("fsr3_sharpness", default: 0.3)))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle("AMD FSR 3.1 Frame Generation (2× Output Rate)", isOn: Binding(
                    get: { store.gameIni.string("framegen", default: "off") == "fsr3" },
                    set: {
                        store.gameIni.set("framegen", $0 ? "fsr3" : "off")
                        store.saveGameIni()
                    }
                ))

                Picker("Frame Rate Limit", selection: Binding(
                    get: { store.gameIni.string("fps_limit", default: "60") },
                    set: {
                        store.gameIni.set("fps_limit", $0)
                        store.saveGameIni()
                    }
                )) {
                    ForEach(fpsLimits) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                Picker("Vulkan Present Mode", selection: Binding(
                    get: { store.launcherIni.string("present_mode", default: "Mailbox") },
                    set: {
                        store.launcherIni.set("present_mode", $0)
                        store.saveLauncherIni()
                    }
                )) {
                    ForEach(presentModes) { item in
                        Text(item.label).tag(item.value)
                    }
                }

                Toggle("Asynchronous Shader Pipeline Compilation", isOn: Binding(
                    get: { store.gameIni.bool("async_pipelines", default: false) },
                    set: {
                        store.gameIni.setBool("async_pipelines", $0)
                        store.saveGameIni()
                    }
                ))
            }

            Section("Language & Private Online Server") {
                Picker("Game Audio & Text Language", selection: Binding(
                    get: { store.effectiveGameLanguageCode() },
                    set: {
                        store.launcherIni.set("language", $0)
                        store.saveLauncherIni()
                    }
                )) {
                    ForEach(store.availableGameLanguages) { lang in
                        Text(lang.label).tag(lang.value)
                    }
                }

                TextField("Private Online Server Host (optional)", text: Binding(
                    get: { store.gameIni.string("online_server") },
                    set: {
                        if $0.trimmingCharacters(in: .whitespaces).isEmpty {
                            store.gameIni.erase("online_server")
                        } else {
                            store.gameIni.set("online_server", $0.trimmingCharacters(in: .whitespaces))
                        }
                        store.saveGameIni()
                    }
                ))

                TextField("Online Player Nickname (online_id)", text: Binding(
                    get: { store.gameIni.string("online_id") },
                    set: {
                        if $0.trimmingCharacters(in: .whitespaces).isEmpty {
                            store.gameIni.erase("online_id")
                        } else {
                            store.gameIni.set("online_id", $0.trimmingCharacters(in: .whitespaces))
                        }
                        store.saveGameIni()
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Effects & Patches Tab

struct PatchesAndEffectsView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        Form {
            Section("Executable Patches (\(store.activeTitleID) v01.21)") {
                if store.patches.isEmpty {
                    Text("No XML patches found in \(store.engineRootURL.appendingPathComponent("patches").path).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.patches) { patch in
                        Toggle(isOn: Binding(
                            get: { patch.isEnabled },
                            set: { store.setPatchEnabled(patch, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(patch.name)
                                        .font(.body.weight(.medium))
                                    if !patch.author.isEmpty {
                                        Text("by \(patch.author)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !patch.note.isEmpty {
                                    Text(patch.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Scene & Post-Processing Effects (bbport.ini)") {
                ForEach(EffectToggleDefinition.builtInEffects) { effect in
                    Toggle(isOn: Binding(
                        get: { store.gameIni.bool(effect.key, default: effect.defaultOn) },
                        set: {
                            store.gameIni.setBool(effect.key, $0)
                            store.saveGameIni()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.title)
                                .font(.body.weight(.medium))
                            Text(effect.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Character & Kart Model LOD Bias", selection: Binding(
                    get: { store.gameIni.int("model_lod", default: 0) },
                    set: {
                        store.gameIni.set("model_lod", String($0))
                        store.saveGameIni()
                    }
                )) {
                    Text("-2 (Highest Detail)").tag(-2)
                    Text("-1 (Higher Detail)").tag(-1)
                    Text("0 (Console Default)").tag(0)
                    Text("+1 (Lower Detail)").tag(1)
                    Text("+2 (Lowest Detail)").tag(2)
                }
            }
        }
        .formStyle(.grouped)
    }
}
