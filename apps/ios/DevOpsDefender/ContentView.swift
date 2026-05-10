import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Pairing") {
                    LabeledContent("Device key", value: "Not generated")
                    Button("Generate enrollment URL") {}
                }

                Section("Agents") {
                    ContentUnavailableView("No agents", systemImage: "server.rack")
                }
            }
            .navigationTitle("DevOps Defender")
        }
    }
}

#Preview {
    ContentView()
}

