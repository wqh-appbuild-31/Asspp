//
//  SettingView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct SettingView: View {
    @Environment(\.openURL) private var openURL
    @State private var vm = AppStore.this

    @State private var showDeviceIdWarning = false
    @State private var editingDeviceId = false
    @State private var deviceIdDraft = ""
    @State private var showResetConfirmation = false

    // [Asspp-ent] kbsync blob import state.
    @State private var kbsyncDSIDDraft = ""
    @State private var kbsyncBlobDraft = ""
    @State private var kbsyncBindingDSID: UInt64?
    @State private var kbsyncMessage: String?

    var body: some View {
        NavigationStack {
            formContent
        }
    }

    private var normalizedDeviceID: String? {
        AppStore.normalizedDeviceIdentifier(deviceIdDraft)
    }

    private func saveDeviceID() {
        guard let identifier = normalizedDeviceID else { return }
        // The AppStore setter also propagates this to ApplePackage.Configuration.
        vm.deviceIdentifier = identifier
        editingDeviceId = false
    }

    // MARK: - [Asspp-ent] kbsync blob import

    private func refreshKBSyncBinding() async {
        kbsyncBindingDSID = await KBSyncProvider.shared.storedBinding()?.dsid
        if kbsyncDSIDDraft.isEmpty, let dsid = vm.accounts.first?.account.directoryServicesIdentifier {
            kbsyncDSIDDraft = dsid
        }
    }

    private func importKBSyncBlob() {
        guard let dsid = UInt64(kbsyncDSIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)), dsid != 0 else {
            kbsyncMessage = String(localized: "Enter the numeric DSID of the account the blob was generated for.")
            return
        }
        let blob = kbsyncBlobDraft
        let guid = vm.deviceIdentifier
        Task {
            do {
                try await KBSyncProvider.shared.importBlob(blob, guid: guid, dsid: dsid)
                kbsyncBlobDraft = ""
                kbsyncMessage = nil
                await refreshKBSyncBinding()
            } catch {
                kbsyncMessage = error.localizedDescription
            }
        }
    }

    private func removeKBSyncBlob() {
        Task {
            await KBSyncProvider.shared.removeBlob()
            await refreshKBSyncBinding()
        }
    }

    private var formContent: some View {
        Form {
            Section {
                Toggle("Demo Mode", isOn: $vm.demoMode)
                Button("Delete All Downloads", role: .destructive) {
                    Downloads.this.removeAll()
                }
            } header: {
                Text("General")
            } footer: {
                Text("Demo mode redacts all accounts and sensitive information.")
            }

            Section {
                Text(ProcessInfo.processInfo.hostName)
                    .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                if editingDeviceId {
                    TextField("Device GUID", text: $deviceIdDraft)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .onSubmit(saveDeviceID)
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                    #endif
                    if normalizedDeviceID == nil {
                        Text("Enter a valid 12-character hexadecimal device GUID.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    #if os(macOS)
                        HStack {
                            Button("Save") { saveDeviceID() }
                                .disabled(normalizedDeviceID == nil)
                            Button("Cancel", role: .cancel) {
                                editingDeviceId = false
                            }
                            Button("Generate Device GUID") {
                                deviceIdDraft = DeviceIdentifier.random()
                            }
                            Spacer()
                        }
                    #else
                        Button("Save") { saveDeviceID() }
                            .disabled(normalizedDeviceID == nil)
                        Button("Cancel", role: .cancel) {
                            editingDeviceId = false
                        }
                        Button("Generate Device GUID") {
                            deviceIdDraft = DeviceIdentifier.random()
                        }
                    #endif
                } else {
                    HStack {
                        Text(vm.deviceIdentifier)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                        Spacer()
                        Button("Edit Device GUID") {
                            showDeviceIdWarning = true
                        }
                    }
                    #if os(macOS)
                        HStack {
                            Button("Open Settings") {
                                openURL(URL(string: "x-apple.systempreferences:")!)
                            }
                            Button("Show Certificate in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Installer.ca])
                            }
                            Spacer()
                        }
                    #else
                        Button("Open Settings") {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        Button("Install Certificate") {
                            openURL(Installer.caURL)
                        }
                    #endif
                }
            } header: {
                Text("Device")
            } footer: {
                #if canImport(UIKit)
                    Text("Grant local network permission to install apps. Install and trust the SSL certificate for on-device installation.")
                #else
                    Text("Grant local network permission to install apps. Install the SSL certificate through System Keychain.")
                #endif
            }
            .alert("Edit Device GUID", isPresented: $showDeviceIdWarning) {
                Button("Edit", role: .destructive) {
                    deviceIdDraft = vm.deviceIdentifier
                    editingDeviceId = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Changing the device GUID may cause all existing accounts to stop working. Apple limits the number of devices you can sign in with at once.")
            }

            // [Asspp-ent] Imported kbsync blob for the attested download path.
            Section {
                if let kbsyncBindingDSID {
                    HStack {
                        Text("Imported Blob")
                        Spacer()
                        Text("DSID \(String(kbsyncBindingDSID))")
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove Imported Blob", role: .destructive) {
                        removeKBSyncBlob()
                    }
                }
                TextField("Account DSID", text: $kbsyncDSIDDraft)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                    #endif
                TextField("Base64 kbsync Blob", text: $kbsyncBlobDraft, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .lineLimit(3 ... 6)
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                    #endif
                Button("Import Blob") {
                    importKBSyncBlob()
                }
                .disabled(kbsyncBlobDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || UInt64(kbsyncDSIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                if let kbsyncMessage {
                    Text(kbsyncMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Attested Download")
            } footer: {
                Text("Downloads try the attested path first when a kbsync blob is available for the device GUID and an account DSID. Generate a blob with ipatool, then import it here. On-device generation is not supported yet.")
            }

            Section {
                Button("Reset", role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This will reset all your settings.")
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshKBSyncBinding()
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                NavigationLink {
                    LogView()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        .alert("Reset Application", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                try? FileManager.default.removeItem(at: documentsDirectory)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                #if canImport(UIKit)
                    UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                #endif
                #if canImport(AppKit) && !canImport(UIKit)
                    NSApp.terminate(nil)
                #endif
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    exit(0)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all your settings and data. The app will close afterwards.")
        }
    }
}
