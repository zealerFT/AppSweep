import AppKit
import AppSweepCore
import SwiftUI
import UniformTypeIdentifiers

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: AppResources.bundle, comment: "")
}

enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppSweep_AppSweep.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()
}

func fileSize(_ size: SizeEstimate) -> String {
    (size.complete ? "" : ">= ") + ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
}

enum AppSection: String, CaseIterable { case applications, history }

extension ApplicationSortOrder {
    var title: String {
        switch self {
        case .name: "Name"
        case .identifier: "Bundle identifier"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        case .leastRecentlyUsed: "Least recently used"
        case .mostRecentlyUsed: "Most recently used"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section = AppSection.applications
    @Published var query = ""
    @Published var sortOrder: ApplicationSortOrder {
        didSet { preferences.set(sortOrder.rawValue, forKey: "applicationSortOrder") }
    }
    @Published var showsCompletionDialog: Bool {
        didSet { preferences.set(showsCompletionDialog, forKey: "showsCompletionDialog") }
    }
    @Published var apps: [InstalledApp] = []
    @Published var appMetadata: [String: ApplicationMetadata] = [:]
    @Published var isLoadingMetadata = false
    @Published var completionNotice: String?
    @Published var catalogIssues: [ScanIssue] = []
    @Published var selectedID: String?
    @Published var report: ScanReport?
    @Published var selectedCandidates: Set<String> = []
    @Published var history: [OperationRecord] = []
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var isRemoving = false
    @Published var running = false
    @Published var showPermissions = false
    @Published var showConfirmation = false
    @Published var result: OperationRecord?
    @Published var alert: AppAlert?
    let context: ScanContext
    private let scanner: AppScanner
    private let historyStore: HistoryStore
    private let removal: RemovalService
    private let preferences: UserDefaults
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration = UUID()

    init(context: ScanContext = .live(ownBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.AppSweep"),
         historyURL: URL? = nil, trash: any TrashMoving = SystemTrash(),
         preferences: UserDefaults = .standard) {
        self.context = context
        self.preferences = preferences
        sortOrder = preferences.string(forKey: "applicationSortOrder")
            .flatMap(ApplicationSortOrder.init(rawValue:)) ?? .name
        showsCompletionDialog = preferences.object(forKey: "showsCompletionDialog") as? Bool ?? true
        scanner = AppScanner(context: context)
        historyStore = HistoryStore(url: historyURL ?? context.home
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(context.ownBundleIdentifier)
            .appendingPathComponent("history.json"))
        removal = RemovalService(context: context, history: historyStore, trash: trash)
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedID } }
    var filteredApps: [InstalledApp] {
        sortOrder.sorted(apps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }, metadata: appMetadata)
    }
    var chosen: [RemovalCandidate] {
        report?.candidates.filter { selectedCandidates.contains($0.id) && $0.canSelect } ?? []
    }
    var chosenSize: SizeEstimate {
        SizeEstimate(bytes: chosen.reduce(0) { $0 + $1.size.bytes }, complete: chosen.allSatisfy(\.size.complete))
    }

    func load() async {
        await reload()
        await loadHistory()
    }

    func reload() async {
        guard !isRemoving, !isLoading else { return }
        metadataTask?.cancel()
        metadataGeneration = UUID()
        isLoadingMetadata = false
        isLoading = true
        defer { isLoading = false }
        do {
            let scanner = scanner
            let catalog = try await background { try scanner.catalog() }
            apps = catalog.applications
            catalogIssues = catalog.issues
            loadCatalogMetadata()
            if let selectedID, !apps.contains(where: { $0.id == selectedID }) { select(nil) }
            else if let selectedID { select(selectedID) }
        } catch is CancellationError {
        } catch { show(error) }
    }

    private func loadCatalogMetadata() {
        let generation = metadataGeneration
        let scanner = scanner
        let catalogApps = apps
        appMetadata = [:]
        isLoadingMetadata = !catalogApps.isEmpty
        metadataTask = Task {
            defer {
                if generation == metadataGeneration { isLoadingMetadata = false }
            }
            await withTaskGroup(of: (String, ApplicationMetadata).self) { group in
                var remaining = catalogApps.makeIterator()
                func add(_ app: InstalledApp) {
                    group.addTask {
                        let metadata = try? await background { try scanner.metadata(for: app) }
                        return (app.id, metadata ?? ApplicationMetadata())
                    }
                }
                for _ in 0..<3 {
                    if let app = remaining.next() { add(app) }
                }
                for await (id, metadata) in group {
                    guard !Task.isCancelled, generation == metadataGeneration else {
                        group.cancelAll()
                        return
                    }
                    appMetadata[id] = metadata
                    if let app = remaining.next() { add(app) }
                }
            }
        }
    }

    func select(_ id: String?) {
        guard !isRemoving else { return }
        scanTask?.cancel()
        scanGeneration = UUID()
        selectedID = id
        report = nil
        selectedCandidates = []
        isScanning = false
        refreshRunningState()
        guard let app = selectedApp else { return }
        isScanning = true
        let generation = scanGeneration
        let scanner = scanner
        scanTask = Task {
            do {
                let scan = try await background {
                    try scanner.scan(app, catalog: scanner.catalog())
                }
                guard !Task.isCancelled, generation == scanGeneration else { return }
                report = scan
                selectedCandidates = Set(scan.candidates.filter { $0.canSelect && $0.kind.selectedByDefault }.map(\.id))
            } catch is CancellationError {
            } catch {
                guard generation == scanGeneration else { return }
                show(error)
            }
            if generation == scanGeneration { isScanning = false }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanGeneration = UUID()
        isScanning = false
    }

    func selectURL(_ url: URL) async {
        guard !isRemoving else { return }
        let path = url.standardizedFileURL.path
        if !apps.contains(where: { $0.url.path == path }) { await reload() }
        guard let app = apps.first(where: { $0.url.path == path }) else {
            alert = AppAlert(title: L("Unsupported application"), message: L("Allowed application locations"))
            return
        }
        query = ""
        section = .applications
        select(app.id)
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Select")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.selectURL(url) }
        }
    }

    func refreshRunningState() {
        running = selectedApp.map(Self.isRunning) ?? false
    }

    static func processes(for app: InstalledApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.lowercased() == app.bundleIdentifier.lowercased() || $0.bundleURL?.path == app.url.path
                || $0.bundleURL?.path.hasPrefix(app.url.path + "/") == true
                || $0.executableURL?.path.hasPrefix(app.url.path + "/") == true
        }
    }

    static func isRunning(_ app: InstalledApp) -> Bool { !processes(for: app).isEmpty }

    func requestQuit() {
        guard let app = selectedApp, !context.protects(app.bundleIdentifier) else { return }
        for process in Self.processes(for: app) { _ = process.terminate() }
        refreshRunningState()
    }

    func removeSelection() async {
        guard let report, !isRemoving, !isScanning else { return }
        let selection = selectedCandidates
        showConfirmation = false
        completionNotice = nil
        isRemoving = true
        do {
            let record = try await removal.remove(report: report, selectedIDs: selection) { app in
                await MainActor.run { AppModel.isRunning(app) }
            }
            presentResult(record)
        } catch { show(error) }
        isRemoving = false
        self.report = nil
        selectedCandidates = []
        await loadHistory()
        await reload()
    }

    func presentResult(_ record: OperationRecord) {
        if record.succeeded && !showsCompletionDialog {
            result = nil
            completionNotice = "\(record.trashedCount) " + L("moved to Trash")
        } else {
            completionNotice = nil
            result = record
        }
    }

    func dismissResult() { result = nil }

    func viewResultHistory() {
        dismissResult()
        section = .history
    }

    func loadHistory() async {
        do { history = try await historyStore.load() }
        catch { show(error) }
    }

    func show(_ error: Error) {
        let message: String
        if let sweep = error as? SweepError {
            switch sweep {
            case .invalidApplication: message = L("Invalid application message")
            case .unsafePath: message = L("Unsafe path message")
            case .selectionChanged: message = L("Selection changed message")
            case .runningApplication: message = L("Running application message")
            case .blockedSelection: message = L("Blocked selection message")
            case .emptySelection: message = L("Empty selection message")
            case .busy: message = L("Removal in progress")
            case .historyUnavailable(let detail): message = L("Journal unavailable") + "\n" + detail
            }
        } else { message = error.localizedDescription }
        alert = AppAlert(title: L("Unable to complete"), message: message)
    }
}

func background<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: action)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
