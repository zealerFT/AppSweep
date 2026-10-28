import AppKit
import AppSweepCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                .background(Color(nsColor: .controlBackgroundColor))
            Group {
                if model.section == .history {
                    HistoryView(records: model.history)
                } else if let app = model.selectedApp {
                    ApplicationDetail(model: model, app: app)
                } else {
                    EmptyState(symbol: "square.grid.2x2", title: L("No application selected"),
                               subtitle: String(model.apps.count) + " " + L("applications"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseApplication() } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("Choose application"))
                    .disabled(model.isRemoving)
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Refresh applications and scan"))
                    .disabled(model.isRemoving || model.isLoading || model.isScanning)
                Button { model.showPermissions = true } label: { Image(systemName: "hand.raised") }
                    .help(L("Permissions"))
                    .disabled(model.isRemoving)
            }
        }
        .sheet(isPresented: $model.showPermissions) {
            PermissionsView(issues: model.report?.issues ?? model.catalogIssues) {
                Task { await model.reload() }
            }
        }
        .sheet(isPresented: $model.showConfirmation) {
            ConfirmationView(appName: model.selectedApp?.name ?? "", items: model.chosen,
                             size: model.chosenSize,
                             hasScanIssues: model.report?.issues.contains { $0.kind.isActionable } ?? false) {
                Task { await model.removeSelection() }
            }
        }
        .sheet(item: $model.result) { record in
            ResultView(record: record) {
                model.result = nil
                model.section = .history
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(L("OK"))))
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshRunningState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshRunningState()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard !model.isRemoving, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in await model.selectURL(url) }
            }
            return true
        }
        .onChange(of: model.isRemoving) { busy in
            for window in NSApplication.shared.windows where window.canBecomeMain {
                window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 21, weight: .medium)).foregroundStyle(.teal)
                Text("AppSweep").font(.system(size: 20, weight: .semibold))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 18)
            Picker("", selection: $model.section) {
                Label(L("Applications"), systemImage: "square.grid.2x2").tag(AppSection.applications)
                Label(L("History"), systemImage: "clock.arrow.circlepath").tag(AppSection.history)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 16)
            if model.section == .applications {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Search applications"), text: $model.query).textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Clear search"))
                    }
                }
                .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
                HStack {
                    Text(String(model.filteredApps.count) + " " + L("applications")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker(L("Sort"), selection: $model.sortOrder) {
                            Text(L("Name")).tag(SortOrder.name)
                            Text(L("Bundle identifier")).tag(SortOrder.identifier)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help(L("Sort"))
                }
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.filteredApps) { app in
                        HStack(spacing: 10) {
                            AppIcon(url: app.url, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(app.version.isEmpty ? app.bundleIdentifier : app.version)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if model.context.protects(app.bundleIdentifier) {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                    .help(L("Protected application"))
                            }
                        }
                        .padding(.vertical, 5).tag(app.id)
                        .help(app.url.path)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if model.filteredApps.isEmpty && !model.isLoading { Text(L("No matching applications")).foregroundStyle(.secondary) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L("Local records"), systemImage: "internaldrive").font(.subheadline)
                    Text(String(model.history.count) + " " + L("operations")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Spacer()
            }
            if model.catalogIssues.contains(where: { $0.kind.isActionable }) {
                Divider()
                HStack {
                    Spacer()
                    Button { model.showPermissions = true } label: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }.buttonStyle(.plain).help(L("Scan limitations"))
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .disabled(model.isRemoving)
    }
}

struct ApplicationDetail: View {
    @ObservedObject var model: AppModel
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AppIcon(url: app.url, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.name).font(.system(size: 25, weight: .semibold)).lineLimit(2)
                    Text(app.bundleIdentifier).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 12) {
                        if !app.version.isEmpty { Text("v" + app.version) }
                        if model.running { Label(L("Running"), systemImage: "circle.fill").foregroundStyle(.orange) }
                        if model.context.protects(app.bundleIdentifier) {
                            Label(L("Protected application"), systemImage: "lock").foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
                Spacer(minLength: 4)
                Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "folder") }
                    .help(L("Show in Finder")).disabled(model.isRemoving)
            }.padding(24)
            HStack {
                Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text(L("Scanning")).font(.caption).foregroundStyle(.secondary)
                    Button { model.cancelScan() } label: { Image(systemName: "xmark") }.help(L("Cancel scan"))
                } else {
                    Button { model.select(app.id) } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("Scan again")).disabled(model.isRemoving)
                }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if model.running && !model.context.protects(app.bundleIdentifier) {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.orange)
                    Text(L("Running application message")).font(.callout)
                    Spacer()
                    Button(L("Request quit")) { model.requestQuit() }.disabled(model.isRemoving)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
            }
            if let report = model.report {
                HStack {
                    Text(L("Associated files")).font(.system(size: 13, weight: .semibold))
                    Text(String(report.candidates.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Default selection")) {
                        model.selectedCandidates = Set(report.candidates.filter { $0.canSelect && $0.kind.selectedByDefault }.map(\.id))
                    }.buttonStyle(.link).font(.caption).disabled(model.isRemoving)
                }.padding(.horizontal, 24).padding(.vertical, 14)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(report.candidates) { item in
                            CandidateRow(item: item, selected: Binding(get: {
                                model.selectedCandidates.contains(item.id)
                            }, set: { selected in
                                if selected { model.selectedCandidates.insert(item.id) }
                                else { model.selectedCandidates.remove(item.id) }
                            }))
                            Divider().padding(.leading, 58)
                        }
                    }.padding(.horizontal, 24)
                }.disabled(model.isRemoving)
                if report.issues.contains(where: { $0.kind.isActionable }) {
                    ScanIssuesView(issues: report.issues)
                }
            } else {
                EmptyState(symbol: model.isScanning ? "doc.text.magnifyingglass" : "doc.text",
                           title: L(model.isScanning ? "Scanning associated files" : "No scan results"), subtitle: "")
            }
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(model.chosen.count) + " " + L("selected items")).font(.caption).foregroundStyle(.secondary)
                    Text(fileSize(model.chosenSize)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                    Text(L("Removal in progress")).font(.callout)
                } else {
                    Button {
                        model.refreshRunningState()
                        if !model.running { model.showConfirmation = true }
                    } label: { Label(L("Move to Trash"), systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .disabled(model.chosen.isEmpty || model.isScanning || model.running)
                }
            }.padding(20).background(.bar)
        }
    }
}

struct CandidateRow: View {
    let item: RemovalCandidate
    @Binding var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(item.url.lastPathComponent, isOn: $selected).labelsHidden().toggleStyle(.checkbox)
                .disabled(!item.canSelect).frame(width: 18)
            Image(systemName: item.kind.symbol).font(.system(size: 20)).foregroundStyle(item.kind.containsUserData ? .orange : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let reason = item.blockReason {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).help(L(reason.title))
                    }
                }
                Text(item.url.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading).help(item.url.path)
            VStack(alignment: .trailing, spacing: 5) {
                Text(fileSize(item.size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(L(item.blockReason?.title ?? item.kind.title)).font(.system(size: 10))
                    .foregroundStyle(item.kind.containsUserData && item.canSelect ? .orange : .secondary)
            }.frame(width: 110, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(L("Show in Finder")).frame(width: 22)
        }.frame(minHeight: 66)
    }
}

struct AppIcon: View {
    let url: URL
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 17, weight: .medium))
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

extension CandidateKind {
    var title: String {
        switch self {
        case .application: "Application bundle"
        case .cache: "Cache"
        case .logs: "Logs"
        case .preferences: "Preferences"
        case .savedState: "Saved state"
        case .applicationData: "Personal data"
        case .container: "Container data"
        case .webData: "Web data"
        }
    }
    var symbol: String {
        switch self {
        case .application: "app"
        case .cache: "externaldrive"
        case .logs: "doc.text"
        case .preferences: "slider.horizontal.3"
        case .savedState: "macwindow"
        case .applicationData: "folder"
        case .container: "shippingbox"
        case .webData: "globe"
        }
    }
}

extension BlockReason {
    var title: String {
        switch self {
        case .protectedApplication: "Protected application"
        case .unsafePath: "Unsafe path"
        case .sharedIdentifier: "Shared data"
        case .officialUninstaller: "Official uninstaller required"
        }
    }
}

extension ScanIssueKind {
    var title: String {
        switch self {
        case .inaccessible: "Could not inspect"
        case .invalidApplication: "Skipped application bundle"
        case .incompleteSize: "Partial size estimate"
        case .sharedIdentifier: "Multiple copies share this identifier"
        case .officialUninstaller: "Service or extension detected"
        case .unsafePath: "Symbolic link or unsafe path skipped"
        }
    }
}
