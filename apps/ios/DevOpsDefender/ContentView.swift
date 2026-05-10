import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ClientViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Agent URL", text: $viewModel.agentURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    TextField("Noise key path", text: $viewModel.keyPath)
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                    Button("Use app support key path") {
                        viewModel.useAppSupportKeyPath()
                    }

                    Toggle("Dev/test: skip TDX quote verification", isOn: $viewModel.insecureSkipQuoteVerify)

                    if !viewModel.insecureSkipQuoteVerify {
                        SecureField("Intel Trust Authority API key", text: $viewModel.itaAPIKey)
                        TextField("ITA base URL", text: $viewModel.itaBaseURL)
                            .textInputAutocapitalization(.never)
                        TextField("ITA JWKS URL", text: $viewModel.itaJwksURL)
                            .textInputAutocapitalization(.never)
                        TextField("ITA issuer", text: $viewModel.itaIssuer)
                            .textInputAutocapitalization(.never)
                    }
                }

                Section("Key Content") {
                    Text("Paste a 32-byte Noise key as hex or base64 when the app cannot read your host key path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.keyContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 76)

                    Button("Import pasted key to path") {
                        viewModel.importPastedKey()
                    }
                    .disabled(viewModel.isBusy)
                }

                Section("Recipes") {
                    Button("Load recipes") {
                        viewModel.loadRecipes()
                    }
                    .disabled(viewModel.isBusy)

                    if viewModel.recipes.isEmpty {
                        Text("No recipes loaded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.recipes) { recipe in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recipe.title)
                                Text(recipe.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if !recipe.detail.isEmpty {
                                    Text(recipe.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Sessions") {
                    HStack {
                        Button("List sessions") {
                            viewModel.loadSessions()
                        }
                        .disabled(viewModel.isBusy)

                        Button("Create shell") {
                            viewModel.createShellSession()
                        }
                        .disabled(viewModel.isBusy)
                    }

                    Toggle("Notify on session changes", isOn: $viewModel.notifyOnSessionChanges)

                    TextField("Selected session id", text: $viewModel.selectedSessionID)
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                    if viewModel.sessions.isEmpty {
                        Text("No sessions loaded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sessions) { session in
                            Button {
                                viewModel.selectSession(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                    Text(session.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    if !session.detail.isEmpty {
                                        Text(session.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Transcript") {
                    HStack {
                        Button("Replay") {
                            viewModel.replaySelectedSession()
                        }
                        .disabled(viewModel.isBusy)

                        Button("Attach / refresh output") {
                            viewModel.attachSelectedSession()
                        }
                        .disabled(viewModel.isBusy)
                    }

                    Stepper(
                        "Zoom \(Int(viewModel.transcriptFontSize)) pt",
                        value: $viewModel.transcriptFontSize,
                        in: 11...30,
                        step: 1
                    )

                    ScrollView([.horizontal, .vertical]) {
                        Text(viewModel.transcript.isEmpty ? "No transcript loaded" : viewModel.transcript)
                            .font(.system(size: viewModel.transcriptFontSize, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .frame(minHeight: 240)
                }

                Section("Mobile Write Controls") {
                    TextField("Short input, e.g. 1 or y", text: $viewModel.quickInput)
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                    HStack {
                        Button("Send + Return") {
                            viewModel.sendQuickInput()
                        }
                        .disabled(viewModel.isBusy)

                        Button("1") {
                            viewModel.sendQuickInput("1\n")
                        }
                        .disabled(viewModel.isBusy)

                        Button("2") {
                            viewModel.sendQuickInput("2\n")
                        }
                        .disabled(viewModel.isBusy)

                        Button("Enter") {
                            viewModel.sendQuickInput("\n")
                        }
                        .disabled(viewModel.isBusy)
                    }

                    Text("Each send attaches, writes bytes, waits briefly for output, then detaches without closing the remote session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    if viewModel.isBusy {
                        ProgressView()
                    }
                    Text(viewModel.status)
                        .font(.callout)

                    DisclosureGroup("Last Rust response") {
                        ScrollView([.horizontal, .vertical]) {
                            Text(viewModel.rawResponse.isEmpty ? "{}" : viewModel.rawResponse)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 120)
                    }
                }
            }
            .navigationTitle("DevOps Defender")
        }
    }
}
