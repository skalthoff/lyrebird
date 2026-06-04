import AppKit
import SwiftUI

/// Recoverable failure scene shown when the Rust core fails to construct at
/// launch (audit L31). Previously this path called `fatalError`, which bricked
/// the app on a recoverable problem (e.g. a corrupt local database). Instead we
/// render the error text plus two recovery affordances — "Reset Local Data"
/// (quarantines the core's data directory so the next launch starts clean) and
/// "Export Diagnostics" (writes a sanitized bundle for a bug report) — and a
/// Quit button.
///
/// No `AppModel` is available here (its construction is exactly what failed), so
/// this view is fully self-contained: it reads version/build from the bundle and
/// uses `CoreDataLocation` / `DiagnosticBundle` directly.
struct CoreInitFailureView: View {
    /// The error thrown by `AppModel()` / `LyrebirdCore` construction.
    let error: Error

    @State private var statusMessage: String?
    @State private var didReset = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("core_failure.title")
                    .font(Theme.font(28, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)

                Text("core_failure.body")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)

                // The raw error text, selectable so it can be pasted into a bug
                // report. Monospaced + scrollable so a long underlying error
                // doesn't blow out the window.
                ScrollView {
                    Text(verbatim: errorDescription)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 120)
                .background(Theme.bgAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let statusMessage {
                    Text(verbatim: statusMessage)
                        .font(Theme.font(12))
                        .foregroundStyle(didReset ? Theme.accent : Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("core_failure.reset") { resetLocalData() }
                        .disabled(didReset)
                    Button("core_failure.export") { exportDiagnostics() }
                    Spacer()
                    Button("core_failure.quit") { NSApp.terminate(nil) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(maxWidth: 520)
        }
    }

    private var errorDescription: String {
        let localized = (error as NSError).localizedDescription
        return localized.isEmpty ? "\(error)" : localized
    }

    /// Quarantine the core's data directory so a corrupt database is moved aside
    /// and the next launch starts clean. We don't try to re-create the
    /// `AppModel` in place (the SwiftUI tree is already wedged on the failure
    /// scene); instead we confirm success and prompt the user to relaunch.
    private func resetLocalData() {
        do {
            let backup = try CoreDataLocation.quarantineDataDirectory()
            didReset = true
            if let backup {
                statusMessage = String(
                    format: NSLocalizedString("core_failure.reset.done", comment: ""),
                    backup.path
                )
            } else {
                statusMessage = NSLocalizedString("core_failure.reset.nothing", comment: "")
            }
        } catch {
            statusMessage = String(
                format: NSLocalizedString("core_failure.reset.failed", comment: ""),
                (error as NSError).localizedDescription
            )
        }
    }

    /// Write a sanitized diagnostic bundle. No live `AppModel`, so the server
    /// URL is empty — correct for a pre-login crash; `DiagnosticBundle` redacts
    /// hosts regardless. Mirrors the save-panel hop in `LyrebirdCommands`.
    private func exportDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0 (dev)"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Bundle"
        panel.nameFieldStringValue = "Lyrebird-Diagnostics-\(DiagnosticBundle.filenameStamp(Date())).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DiagnosticBundle.export(to: url, version: version, build: build, serverURL: "")
            statusMessage = NSLocalizedString("core_failure.export.done", comment: "")
        } catch {
            statusMessage = String(
                format: NSLocalizedString("core_failure.export.failed", comment: ""),
                (error as NSError).localizedDescription
            )
        }
    }
}
