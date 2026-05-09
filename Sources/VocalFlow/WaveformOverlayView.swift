import SwiftUI

struct WaveformOverlayView: View {
    @ObservedObject var appState: AppState

    @State private var bar1 = false
    @State private var bar2 = false
    @State private var bar3 = false
    @State private var bar4 = false

    private let minH: CGFloat = 6
    private let maxH: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                bar(animated: bar1)
                bar(animated: bar2)
                bar(animated: bar3)
                bar(animated: bar4)
            }
            if !appState.liveTranscript.isEmpty {
                Text(appState.liveTranscript)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.00) { bar1 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { bar2 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { bar3 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { bar4 = true }
        }
    }

    @ViewBuilder
    private func bar(animated: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 4, height: animated ? maxH : minH)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: animated
            )
    }
}
