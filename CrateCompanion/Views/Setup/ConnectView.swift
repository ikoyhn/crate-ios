import CrateKit
import SwiftUI

/// First run (and Settings > Change server): find Crate, then optionally Navidrome for playback.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var editing = false

    @State private var c = Connection()
    @State private var token = ""
    @State private var password = ""
    @State private var needsToken = false
    @State private var crateOK = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("crate.local:8090", text: $c.crateURL)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: c.crateURL) { crateOK = false }
                    if needsToken {
                        SecureField("API token", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Crate")
                } footer: {
                    Text(needsToken ? "This server has API_TOKEN set. Paste the same value here."
                                    : "The address you open Crate's web UI on.")
                }

                if crateOK {
                    Section {
                        Toggle("Play from Navidrome", isOn: $c.useNavidrome)
                        if c.useNavidrome {
                            TextField("https://music.example.com", text: $c.navidromeURL)
                                .textContentType(.URL).keyboardType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Username", text: $c.navidromeUser)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Password", text: $password).textContentType(.password)
                            Picker("Quality", selection: $c.maxBitRate) {
                                Text("Original").tag(0)
                                Text("320 kbps").tag(320)
                                Text("192 kbps").tag(192)
                                Text("128 kbps").tag(128)
                            }
                        }
                    } header: {
                        Text("Playback")
                    } footer: {
                        Text(c.useNavidrome
                             ? "Songs stream from Navidrome at full quality and your plays count. Use the same user Crate uses, so likes line up."
                             : "Songs stream through Crate at 128 kbps, and don't count as plays in Navidrome.")
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { crateOK ? await finish() : await checkCrate() }
                    } label: {
                        HStack {
                            Text(crateOK ? "Connect" : "Continue").bold()
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || c.crateURL.isEmpty)
                }
            }
            .navigationTitle(editing ? "Server" : "Welcome to Crate")
            .toolbar {
                if editing { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard editing, let saved = model.connection else { return }
        c = saved
        token = Keychain.get("crateToken") ?? ""
        password = Keychain.get("navidromePassword") ?? ""
        needsToken = !token.isEmpty
    }

    private func checkCrate() async {
        error = nil
        guard let url = CrateAPI.normalise(c.crateURL) else { error = CrateError.badURL.localizedDescription; return }
        busy = true
        defer { busy = false }
        do {
            let ping = try await CrateAPI(baseURL: url).ping()
            if ping.authRequired && token.isEmpty {
                needsToken = true
                error = nil
                return
            }
            let info = try await CrateAPI(baseURL: url, token: token).info()
            if c.navidromeURL.isEmpty { c.navidromeURL = info.navidrome.url }
            if c.navidromeUser.isEmpty { c.navidromeUser = info.navidrome.user }
            if !info.navidrome.publicUrlSet && info.navidrome.url.contains("://navidrome") {
                // a Docker-internal name the phone can't reach
                c.navidromeURL = ""
            }
            c.crateURL = url.absoluteString
            crateOK = true
        } catch CrateError.unauthorized {
            needsToken = true
            error = token.isEmpty ? nil : CrateError.unauthorized.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish() async {
        error = nil
        if c.useNavidrome {
            guard let url = CrateAPI.normalise(c.navidromeURL) else { error = "Enter Navidrome's address"; return }
            busy = true
            defer { busy = false }
            do {
                try await Subsonic(baseURL: url, user: c.navidromeUser, password: password).ping()
                c.navidromeURL = url.absoluteString
            } catch {
                self.error = "Navidrome: \(error.localizedDescription)"
                return
            }
        }
        model.connect(c, token: token, password: password)
        if editing { dismiss() }
    }
}
