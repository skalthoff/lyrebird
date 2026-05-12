import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSVisualEffectView` so views can opt into the
/// system's vibrancy / translucency materials (sidebar, HUD, content
/// background, etc.) without dropping to AppKit at the call site.
///
/// Used by `Sidebar` for the translucent Apple-Music-style panel on the
/// leading edge and by `PlayerBar` for the unified transport bar. The
/// default blending mode is `.behindWindow` so the material picks up the
/// desktop wallpaper / window beneath; callers can pass `.withinWindow`
/// when stacking one material in front of another inside the same window.
///
/// `state` defaults to `.followsWindowActiveState` so the material
/// desaturates when the window loses key status — matching stock macOS
/// apps (Music, Mail, Finder sidebar). See issues #9 / #10 / #28.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        // Emulate the layer-backed look SwiftUI callers expect: the material
        // should paint edge-to-edge with no insets.
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
