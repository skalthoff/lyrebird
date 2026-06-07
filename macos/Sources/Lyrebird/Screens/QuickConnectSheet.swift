import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
@preconcurrency import LyrebirdCore

/// Modal presented from `LoginView` for Jellyfin Quick Connect (#202).
///
/// Flow: on appear we ask the core to `quickConnectInitiate` against the
/// entered server URL, which returns a short numeric `code` (shown big + as a
/// QR) and an opaque `secret`. We then poll `quickConnectPoll` on a timer; once
/// the user approves the code in another already-signed-in Jellyfin client the
/// poll flips to approved and we `quickConnectComplete` to finish sign-in —
/// `RootView` then routes to `MainShell` because `model.session` is set.
///
/// The server URL must be filled in on the login form first (Quick Connect is a
/// *device-pairing* flow, not a *server-discovery* one), so the sheet shows a
/// gentle prompt when `serverURL` is empty rather than failing to initiate.
struct QuickConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The server URL the user entered on the login form. Quick Connect needs a
    /// concrete server to pair against.
    let serverURL: String

    private enum Phase: Equatable {
        case needsServer
        case loading
        case waiting(code: String, secret: String)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// Drives the polling loop. Reset on disappear so we don't keep hitting the
    /// server after the sheet closes.
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            header

            Group {
                switch phase {
                case .needsServer:
                    needsServerBody
                case .loading:
                    loadingBody
                case .waiting(let code, _):
                    waitingBody(code: code)
                case .failed(let message):
                    failedBody(message: message)
                }
            }
            .frame(maxWidth: .infinity)

            Button("login.quick_connect.cancel") { close() }
                .buttonStyle(.plain)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .padding(.top, 4)
                .accessibilityLabel("login.quick_connect.cancel")
        }
        .padding(28)
        .frame(width: 360)
        .background(Theme.bg)
        .task { await start() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("login.quick_connect.title")
                .font(Theme.font(20, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("login.quick_connect.subtitle")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var needsServerBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text("login.quick_connect.needs_server")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private var loadingBody: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("login.quick_connect.starting")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
        .frame(height: 200)
    }

    private func waitingBody(code: String) -> some View {
        VStack(spacing: 16) {
            if let qr = Self.qrImage(for: code) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }

            VStack(spacing: 4) {
                Text("login.quick_connect.code_label")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1.5)
                Text(spacedCode(code))
                    .font(Theme.font(30, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(verbatim: code))
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("login.quick_connect.waiting")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.teal)
            }
            .padding(.top, 2)
        }
    }

    private func failedBody(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("login.quick_connect.retry") { Task { await start() } }
                .buttonStyle(.plain)
                .font(Theme.font(13, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .padding(.vertical, 8)
    }

    // MARK: - Flow

    private func start() async {
        stopPolling()
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .needsServer
            return
        }
        phase = .loading
        guard let info = await model.quickConnectInitiate(url: trimmed) else {
            // `quickConnectInitiate` already set `model.errorMessage`; reflect a
            // concise message in the sheet too.
            phase = .failed(String(localized: "login.quick_connect.error", bundle: .main))
            return
        }
        phase = .waiting(code: info.code, secret: info.secret)
        beginPolling(url: trimmed, secret: info.secret)
    }

    /// Poll the pairing state ~every 2s until approved or the sheet closes.
    /// Jellyfin's Quick Connect codes are short-lived; the loop simply stops
    /// when the task is cancelled (sheet dismissed) — an expired code surfaces
    /// as a failed `quickConnectComplete` which we map to the failed phase.
    private func beginPolling(url: String, secret: String) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                let approved = await model.quickConnectPoll(url: url, secret: secret)
                if approved {
                    let ok = await model.quickConnectComplete(url: url, secret: secret)
                    if ok {
                        // Session is live; RootView swaps to MainShell. Close the
                        // sheet so it doesn't linger over the app.
                        close()
                    } else {
                        phase = .failed(String(localized: "login.quick_connect.error", bundle: .main))
                    }
                    return
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func close() {
        stopPolling()
        dismiss()
    }

    // MARK: - Helpers

    /// Insert a thin gap in the middle of the code so a 6-digit value reads as
    /// "639 443" rather than a run-on "639443".
    private func spacedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }

    /// Shared CoreImage context for QR rendering. Cheap to keep around and
    /// `Sendable`, so we don't spin up a Metal pipeline per render.
    private static let ciContext = CIContext()

    /// Render `string` as a crisp black-on-transparent QR `NSImage`. Returns
    /// `nil` if CoreImage can't produce an output (the code still shows as text,
    /// so the QR is a progressive enhancement).
    static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Upscale the tiny native QR so it stays sharp at display size.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// Popover (anchored on the login gear) for editing the device name Jellyfin
/// shows for this client (#202). Seeds its field from `model.deviceName`,
/// commits a trimmed value through `updateDeviceName(_:)`, and disables Save
/// when the field is blank or unchanged so it can't write an empty `Device`
/// header.
struct DeviceNamePopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("login.device_name.title")
                .font(Theme.font(14, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("login.device_name.subtitle")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            TextField("login.device_name.placeholder", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(commit)
                .accessibilityLabel("login.device_name.a11y_field")

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("login.device_name.cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                Button("login.device_name.save", action: commit)
                    .buttonStyle(.plain)
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(canSave ? Theme.ink : Theme.ink3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(canSave ? Theme.accent : Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Theme.bg)
        .onAppear {
            draft = model.deviceName
            fieldFocused = true
        }
    }

    private var canSave: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != model.deviceName
    }

    private func commit() {
        guard canSave else { return }
        model.updateDeviceName(draft)
        dismiss()
    }
}

