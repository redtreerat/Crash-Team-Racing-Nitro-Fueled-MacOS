import SwiftUI

// MARK: - Controls Tab

struct ControlsSectionView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        Form {
            Section("Split-Screen & Controller Assignment (SDL3)") {
                HStack {
                    Text(store.connectedGamepads.isEmpty
                         ? "Controllers are auto-detected via SDL3 (DualSense, DualShock 4, Xbox, Switch Pro, MFi)."
                         : "\(store.connectedGamepads.count) controller(s) detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Controllers") {
                        Task { await store.probeEnvironment() }
                    }
                    .controlSize(.small)
                }

                ForEach(1...4, id: \.self) { port in
                    let key = "port.\(port)"
                    HStack {
                        Text(port == 1 ? "Player 1 (Primary + Keyboard)" : "Player \(port) (Split-Screen)")
                        Spacer()
                        if !store.connectedGamepads.isEmpty {
                            Picker("", selection: Binding(
                                get: { store.gameIni.string(key) },
                                set: {
                                    if $0.isEmpty {
                                        store.gameIni.erase(key)
                                    } else {
                                        store.gameIni.set(key, $0)
                                    }
                                    store.saveGameIni()
                                }
                            )) {
                                Text("Automatic").tag("")
                                ForEach(store.connectedGamepads) { pad in
                                    Text(pad.label).tag(pad.value)
                                }
                            }
                            .frame(width: 240)
                        } else {
                            TextField("Automatic (or name/GUID substring)", text: Binding(
                                get: { store.gameIni.string(key) },
                                set: {
                                    if $0.trimmingCharacters(in: .whitespaces).isEmpty {
                                        store.gameIni.erase(key)
                                    } else {
                                        store.gameIni.set(key, $0.trimmingCharacters(in: .whitespaces))
                                    }
                                    store.saveGameIni()
                                }
                            ))
                            .frame(width: 260)
                        }
                    }
                }
            }

            Section("Analog Stick Calibration") {
                HStack {
                    Text("Inner Deadzone")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { store.launcherIni.double("pad_deadzone", default: 0.12) },
                            set: {
                                store.launcherIni.set("pad_deadzone", String(format: "%.2f", $0))
                                store.saveLauncherIni()
                            }
                        ),
                        in: 0.0...0.40,
                        step: 0.01
                    )
                    .frame(width: 200)
                    Text(String(format: "%.0f%%", store.launcherIni.double("pad_deadzone", default: 0.12) * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Outer Deadzone")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { store.launcherIni.double("pad_deadzone_outer", default: 0.95) },
                            set: {
                                store.launcherIni.set("pad_deadzone_outer", String(format: "%.2f", $0))
                                store.saveLauncherIni()
                            }
                        ),
                        in: 0.70...1.00,
                        step: 0.01
                    )
                    .frame(width: 200)
                    Text(String(format: "%.0f%%", store.launcherIni.double("pad_deadzone_outer", default: 0.95) * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Automatic Stick Center Calibration", isOn: Binding(
                    get: { store.launcherIni.bool("pad_center_cal", default: true) },
                    set: {
                        store.launcherIni.setBool("pad_center_cal", $0)
                        store.saveLauncherIni()
                    }
                ))
            }

            Section("Keyboard & Overlay Shortcuts") {
                LabeledContent("In-Game Settings Overlay", value: "Shift + W, F1, Insert, or L3 + R3")
                LabeledContent("Toggle Fullscreen", value: "F11 or Option + Return")
                LabeledContent("Custom Key Bindings", value: "key.<action> in bbport.ini")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Save Data Tab

struct SavesSectionView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Button {
                        store.createSaveBackup()
                    } label: {
                        Label("Back Up Saves Now", systemImage: "plus.square.on.square")
                    }
                    .disabled(store.saveSlots.isEmpty)

                    Button {
                        store.importSaveFolder()
                    } label: {
                        Label("Import PS4 / PC Save…", systemImage: "square.and.arrow.down")
                    }

                    Spacer()

                    Button {
                        store.revealInFinder(store.activeSaveRootURL)
                    } label: {
                        Label("Open Save Folder", systemImage: "folder")
                    }

                    Button {
                        store.reloadSaves()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Save Actions (\(store.activeTitleID))")
            } footer: {
                Text("Supports decrypted PS4 saves exported by Apollo Save Tool / Save Wizard (containing sce_sys/param.sfo) as well as CTR-NitroFueled-PC user/savedata folders.")
            }

            Section("Active Save Slots") {
                if store.saveSlots.isEmpty {
                    Text("No save slots found yet in \(store.activeSaveRootURL.path).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.saveSlots) { slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(slot.title)
                                    .font(.body.weight(.semibold))
                                if !slot.subtitle.isEmpty {
                                    Text(slot.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(slot.directoryName) • \(slot.formattedSize) • \(slot.modifiedDate)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Reveal") {
                                store.revealInFinder(slot.path)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Local Save Backups") {
                if store.saveBackups.isEmpty {
                    Text("No backups created yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.saveBackups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.name)
                                    .font(.body.weight(.medium))
                                Text("\(backup.formattedSize) • \(backup.modifiedDate)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                store.restoreSaveBackup(backup)
                            }
                            .controlSize(.small)

                            Button(role: .destructive) {
                                store.deleteSaveBackup(backup)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - DLC Tab

struct DlcSectionView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        Form {
            Section {
                Toggle("Report Installed DLC Entitlements to Game", isOn: Binding(
                    get: { store.launcherIni.bool("dlc", default: true) },
                    set: {
                        store.launcherIni.setBool("dlc", $0)
                        store.saveLauncherIni()
                    }
                ))

                HStack {
                    Button {
                        store.addDlcPackages()
                    } label: {
                        Label("Add DLC .pkg Files…", systemImage: "plus")
                    }

                    Button {
                        store.revealInFinder(store.dlcRootURL)
                    } label: {
                        Label("Open dlc/ Folder", systemImage: "folder")
                    }

                    Spacer()

                    Button {
                        store.reloadDLC()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            } header: {
                Text("Add-On Entitlements")
            } footer: {
                Text("CTR Nitro-Fueled v01.21 already contains all add-on karts, skins, and editions in its data files; add-on .pkg files supply the 16-character entitlement labels read by scripts/content_profile.py.")
            }

            Section("Installed Add-On Packages (\(store.dlcPackages.count))") {
                if store.dlcPackages.isEmpty {
                    Text("No .pkg license files placed in \(store.dlcRootURL.path).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.dlcPackages) { pkg in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { pkg.isEnabled },
                                set: { store.setDlcPackageEnabled(pkg, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pkg.fileName)
                                        .font(.body.weight(.medium))
                                    Text(pkg.isValid ? "Entitlement: \(pkg.contentLabel) (\(pkg.statusNote))" : pkg.statusNote)
                                        .font(.caption)
                                        .foregroundStyle(pkg.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeDlcPackage(pkg)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Mac Port & Build Tab

struct MacEngineBuildView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        Form {
            Section("Port Repository & User Data Directories") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Engine Source / Runtime Root")
                            .font(.body.weight(.medium))
                        Text(store.engineRootURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Change…") {
                        store.selectEngineRoot()
                    }
                    Button("Reveal") {
                        store.revealInFinder(store.engineRootURL)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("User Data & Config Directory (BB_DATA_DIR)")
                            .font(.body.weight(.medium))
                        Text(store.dataRootURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Reveal") {
                        store.revealInFinder(store.dataRootURL)
                    }
                }
            }

            Section("Apple Silicon Runtime & Toolchain Diagnostics") {
                LabeledContent("Host OS", value: "macOS \(store.envStatus.macOSVersionString) (\(store.envStatus.isAppleSilicon ? "Apple Silicon arm64" : "Intel x86_64"))")
                LabeledContent("Rosetta 2 (x86_64 + AVX)", value: store.envStatus.rosettaInstalled ? "Installed & Ready" : "Missing")
                LabeledContent("KosmicKrisp Vulkan 1.4 ICD", value: store.envStatus.kosmicKrispICDPath ?? "Not detected yet")
                LabeledContent("MoltenVK Fallback ICD", value: store.envStatus.moltenVKICDPath ?? "Not detected")
                LabeledContent("sacredfire Binary", value: store.envStatus.sacredfireBinaryPath ?? "Not built yet")
                if !store.envStatus.cpuFeaturesReport.isEmpty {
                    LabeledContent("Guest CPU Check", value: store.envStatus.cpuFeaturesReport)
                }
                LabeledContent("Python 3", value: store.envStatus.pythonPath ?? "Not found")
                LabeledContent("CMake / Ninja", value: "\(store.envStatus.cmakePath ?? "missing") / \(store.envStatus.ninjaPath ?? "missing")")
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        store.buildMacRuntime(installDepsFirst: false)
                    } label: {
                        Label("Build sacredfire (x86_64)", systemImage: "hammer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBuildingEngine || store.isGameRunning)

                    Button {
                        store.buildMacRuntime(installDepsFirst: true)
                    } label: {
                        Label("Bootstrap x86_64 Dependencies & KosmicKrisp", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isBuildingEngine || store.isGameRunning)

                    Spacer()

                    Button("Re-Probe System") {
                        Task { await store.probeEnvironment() }
                    }
                }
            } header: {
                Text("Compile Native macOS x86_64 Runtime")
            } footer: {
                Text("Compiles src/*.c (with compat_mac.h, pthread TCB slot rewriting, SIGBUS page-fault tracking, and elevated PS4 VM base) + gpu/libbbgpu.a against x86_64 SDL3/Vulkan for execution under Rosetta 2 with Mesa KosmicKrisp.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Console Log Tab

struct ConsoleLogView: View {
    @Bindable var store: LauncherStore
    @State private var filterText: String = ""

    private var filteredLines: [String] {
        guard !filterText.isEmpty else { return store.consoleLines }
        return store.consoleLines.filter { $0.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter console output…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Toggle("Save Frame Stats & Detailed Logs", isOn: Binding(
                    get: { store.launcherIni.bool("save_log", default: false) },
                    set: {
                        store.launcherIni.setBool("save_log", $0)
                        store.saveLauncherIni()
                    }
                ))
                .toggleStyle(.checkbox)

                Spacer()

                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.consoleLines.joined(separator: "\n"), forType: .string)
                }

                Button("Reveal last_run.log") {
                    let logURL = store.dataRootURL.appendingPathComponent("last_run.log")
                    if FileManager.default.fileExists(atPath: logURL.path) {
                        store.revealInFinder(logURL)
                    } else {
                        store.revealInFinder(store.dataRootURL)
                    }
                }

                Button("Clear") {
                    store.consoleLines.removeAll()
                }
            }
            .padding(12)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if filteredLines.isEmpty {
                            Text("Console output from run.py, sacredfire, and build.sh appears here in real time.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            ForEach(Array(filteredLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(.black.opacity(0.85))
                .foregroundStyle(.white.opacity(0.92))
                .onChange(of: store.consoleLines.count) { _, _ in
                    if filterText.isEmpty, !store.consoleLines.isEmpty {
                        proxy.scrollTo(store.consoleLines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}
