import SwiftUI
import UIKit

/// Keep the volume interaction paired even when UIKit cancels a touch.
struct VolumeSlider: UIViewRepresentable {
    @Binding var value: Double
    var tint: Color = .accentColor
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider()
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.trackingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.editingChanged(editing)
        }
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: TrackingSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = isEnabled
        slider.minimumTrackTintColor = UIColor(tint)
        if !slider.isTracking { slider.value = Float(value) }
    }

    final class Coordinator: NSObject {
        var parent: VolumeSlider
        private var editing = false

        init(_ parent: VolumeSlider) { self.parent = parent }

        func editingChanged(_ active: Bool) {
            guard editing != active else { return }
            editing = active
            parent.onEditingChanged(active)
        }

        @objc func valueChanged(_ slider: UISlider) {
            parent.value = Double(slider.value.rounded())
            // VoiceOver and keyboard changes do not have a touch lifecycle.
            if !editing { parent.onEditingChanged(false) }
        }
    }

    final class TrackingSlider: UISlider {
        var trackingChanged: ((Bool) -> Void)?

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            // UISlider may emit valueChanged inside beginTracking (track taps).
            trackingChanged?(true)
            let began = super.beginTracking(touch, with: event)
            if !began { trackingChanged?(false) }
            return began
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            trackingChanged?(false)
        }

        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            trackingChanged?(false)
        }
    }
}
