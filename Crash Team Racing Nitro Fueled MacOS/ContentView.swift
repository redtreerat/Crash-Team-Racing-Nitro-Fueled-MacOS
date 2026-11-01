import SwiftUI

struct ContentView: View {
    @Bindable var store: LauncherStore

    var body: some View {
        NavigationSplitView {
            List(LauncherSection.allCases, selection: $store.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            VStack(spacing: 0) {
                if let notice = store.bannerNotice {
                    bannerBar(message: notice, isError: store.bannerIsError)
                }

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(store.selectedSection.rawValue)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isGameRunning {
                        Button {
                            store.stopRunningProcess()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .tint(.red)
                    } else {
                        Button {
                            store.launchGame()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .disabled(!store.canLaunchGame)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch store.selectedSection {
        case .play:
            PlaySectionView(store: store)
        case .graphics:
            GraphicsSectionView(store: store)
        case .patches:
            PatchesAndEffectsView(store: store)
        case .controls:
            ControlsSectionView(store: store)
        case .saves:
            SavesSectionView(store: store)
        case .dlc:
            DlcSectionView(store: store)
        case .engine:
            MacEngineBuildView(store: store)
        case .logs:
            ConsoleLogView(store: store)
        }
    }

    private func bannerBar(message: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                store.clearNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isError ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isGameRunning ? Color.green : (store.canLaunchGame ? Color.orange : Color.secondary))
                    .frame(width: 8, height: 8)
                Text(store.isGameRunning ? "Running CTR" : (store.canLaunchGame ? "Ready to Race" : "Setup Required"))
                    .font(.caption.weight(.medium))
                Spacer()
                Text(store.activeTitleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    ContentView(store: LauncherStore())
        .frame(width: 980, height: 660)
}
