import AppKit
import AppSweepCore
import SwiftUI

struct ScanIssuesView: View {
    let issues: [ScanIssue]
    @State private var expanded = false
    private var hasActionableIssues: Bool { issues.contains { $0.kind.isActionable } }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !hasActionableIssues {
                        Text(L("Skipped application notice"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(issue.kind.title)).font(.caption).fontWeight(.medium)
                            Text(issue.path).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            if !issue.detail.isEmpty {
                                Text(localizedIssueDetail(issue.detail)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 8)
            }.frame(maxHeight: 140)
        } label: {
            Label(L(hasActionableIssues ? "Scan limitations" : "Scan notices") + " (\(issues.count))",
                  systemImage: hasActionableIssues ? "exclamationmark.triangle" : "info.circle")
                .font(.caption).foregroundStyle(hasActionableIssues ? .orange : .secondary)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

private func localizedIssueDetail(_ detail: String) -> String {
    if detail == (SweepError.invalidApplication.errorDescription ?? "") { return L("Invalid application scan message") }
    if detail == (SweepError.unsafePath.errorDescription ?? "") { return L("Unsafe path message") }
    return detail
}

struct ConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let appName: String
    let items: [RemovalCandidate]
    let size: SizeEstimate
    let hasScanIssues: Bool
    let confirm: () -> Void
    @State private var acceptsDataLoss = false

    private var includesData: Bool { items.contains { $0.kind.containsUserData } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("Confirm removal"), systemImage: "trash").font(.title2.weight(.semibold))
            Text(appName).font(.headline).lineLimit(2)
            HStack {
                Text(String(items.count) + " " + L("selected items"))
                Spacer()
                Text(fileSize(size)).monospacedDigit()
            }.foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.kind.symbol).foregroundStyle(item.kind.containsUserData ? .orange : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            Text(L("Trash space notice")).font(.caption).foregroundStyle(.secondary)
            if items.contains(where: { $0.kind == .application }) {
                Text(L("Finder removal notice")).font(.caption).foregroundStyle(.secondary)
            }
            if hasScanIssues {
                Label(L("Incomplete scan notice"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if includesData {
                Toggle(L("Acknowledge personal data"), isOn: $acceptsDataLoss).toggleStyle(.checkbox)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button { confirm() } label: { Label(L("Move to Trash"), systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(includesData && !acceptsDataLoss)
            }
        }.padding(24).frame(width: 510)
    }
}

struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    let issues: [ScanIssue]
    let rescan: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("Permissions"), systemImage: "hand.raised").font(.title2.weight(.semibold))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Full Disk Access")).font(.headline)
                    Text(L("Managed by macOS")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openPrivacySettings("Privacy_AllFiles")
                } label: { Label(L("Open System Settings"), systemImage: "arrow.up.forward.app") }
            }
            if Bundle.main.object(forInfoDictionaryKey: "AppSweepSigningMode") as? String == "ad-hoc" {
                Text(L("Permission after update notice")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent(L("Scan scope"), value: L("Current user Library"))
            LabeledContent(L("Administrator privileges"), value: L("Confirmed by macOS when needed"))
            LabeledContent(L("Network access"), value: L("Not used"))
            Text(L("Permission scope notice")).font(.caption).foregroundStyle(.secondary)
            if !issues.isEmpty { ScanIssuesView(issues: issues) }
            Divider()
            HStack {
                Button(L("Rescan now")) { dismiss(); rescan() }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}

struct HistoryView: View {
    let records: [OperationRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("History")).font(.system(size: 23, weight: .semibold))
                Spacer()
                Text(String(records.count) + " " + L("operations")).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            if records.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: L("No operations yet"), subtitle: "")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(records) { record in
                            HistoryRecordView(record: record).padding(24)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRecordView: View {
    let record: OperationRecord
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(record.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.status == .trashed ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(entry.status == .trashed ? .teal : .orange).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.originalPath).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(L(entry.status.title)).font(.caption).foregroundStyle(.secondary)
                            if entry.status == .failed { OperationFailureView(entry: entry) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if let path = entry.trashPath {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                                Image(systemName: "folder")
                            }.help(L("Show in Trash")).disabled(!FileManager.default.fileExists(atPath: path))
                        }
                    }
                }
                if let error = record.journalError {
                    Text(L("Journal unavailable") + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(.top, 16)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.appName).font(.headline)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.finished ? "\(record.trashedCount) / \(record.entries.count) " + L("moved to Trash") : L("Interrupted operation"))
                    .font(.caption).foregroundStyle(record.succeeded ? .teal : .orange)
            }
        }
    }
}

struct ResultView: View {
    let record: OperationRecord
    @Binding var suppressSuccessDialog: Bool
    let close: () -> Void
    let viewHistory: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Label(L(record.succeeded ? "Moved to Trash" : "Removal stopped"),
                      systemImage: record.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.title2.weight(.semibold)).foregroundStyle(record.succeeded ? .teal : .orange)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Close")).accessibilityLabel(L("Close"))
                    .keyboardShortcut(.cancelAction)
            }
            Text(record.appName).font(.headline)
            Text("\(record.trashedCount) / \(record.entries.count) " + L("moved to Trash"))
            if let failed = record.entries.first(where: { $0.status == .failed }) {
                Text(URL(fileURLWithPath: failed.originalPath).lastPathComponent)
                    .font(.callout).textSelection(.enabled)
                OperationFailureView(entry: failed)
            }
            if let error = record.journalError {
                Text(L("Journal unavailable") + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                ForEach(record.entries.filter { $0.status == .trashed }) { entry in
                    Text(entry.originalPath).font(.caption).textSelection(.enabled)
                }
            }
            Text(L("Trash space notice")).font(.caption).foregroundStyle(.secondary)
            if record.succeeded {
                Toggle(L("Do not show successful cleanup again"), isOn: $suppressSuccessDialog)
                    .toggleStyle(.checkbox)
                Text(L("Completion preference explanation")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("View history"), action: viewHistory)
                Button(L("Close"), action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
}

private func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
        NSWorkspace.shared.open(url)
    }
}

private struct OperationFailureView: View {
    let entry: OperationEntry
    private var url: URL { URL(fileURLWithPath: entry.originalPath) }
    private var isApplication: Bool { url.pathExtension.lowercased() == "app" }
    private var explanation: String {
        if entry.failure?.isFinderAuthorizationDenied == true { return L("Finder permission failure") }
        switch entry.failure?.kind {
        case .cancelled: return L("Removal cancelled explanation")
        case .permissionDenied:
            return L(isApplication ? "Application permission failure" : "Data permission failure")
        default: return L("Removal failure explanation")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(explanation).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if entry.failure?.kind != .cancelled {
                HStack {
                    if entry.failure?.isFinderAuthorizationDenied == true {
                        Button(L("Open System Settings")) { openPrivacySettings("Privacy_Automation") }
                    }
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .disabled(!FileManager.default.fileExists(atPath: entry.originalPath))
                }.controlSize(.small)
            }
            if let error = entry.error {
                DisclosureGroup(L("Technical details")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).textSelection(.enabled)
                        if let failure = entry.failure {
                            Text("\(failure.domain) (\(failure.code))").textSelection(.enabled)
                            ForEach(Array((failure.underlyingErrors ?? []).enumerated()), id: \.offset) { _, error in
                                Text("↳ \(error.domain) (\(error.code))").textSelection(.enabled)
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
}

extension EntryStatus {
    var title: String {
        switch self {
        case .pending: "Unconfirmed after interruption"
        case .trashed: "Moved to Trash"
        case .failed: "Failed"
        case .skipped: "Not processed"
        }
    }
}
