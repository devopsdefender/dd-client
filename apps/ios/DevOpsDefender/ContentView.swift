import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ClientViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                Text(transcriptText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.top, 46)
                    .padding(.bottom, 24)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isBusy ? Palette.busy : Palette.ready)
                    .frame(width: 7, height: 7)

                Text(statusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.background.opacity(0.94))
        }
        .onOpenURL { url in
            viewModel.openMobileLink(url)
        }
    }

    private var transcriptText: String {
        if !viewModel.transcript.isEmpty {
            return viewModel.transcript
        }
        if viewModel.hasLinkedSession {
            return viewModel.status
        }
        return "Open a DevOps Defender session link."
    }

    private var statusText: String {
        if viewModel.hasLinkedSession {
            return "\(viewModel.linkedSessionTitle)  \(viewModel.status)"
        }
        return viewModel.status
    }
}

private enum Palette {
    static let background = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let text = Color(red: 0.16, green: 0.14, blue: 0.11)
    static let muted = Color(red: 0.42, green: 0.37, blue: 0.30)
    static let ready = Color(red: 0.20, green: 0.48, blue: 0.31)
    static let busy = Color(red: 0.70, green: 0.43, blue: 0.12)
}
