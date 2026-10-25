import Foundation
import Security
import SwiftUI

/// The Gemini and TypeSafe keys for on-phone pricing, kept in the iPhone's Keychain.
/// Never in code, git or the app bundle; you paste them in the settings screen.
struct Keys {
    let gemini: String
    let typesafe: String
    let model: String

    private static let service = "com.lensthrift.mobile.keys"
    static let modelKey = "geminiModel"

    static func load() -> Keys? {
        guard let g = read("gemini"), !g.isEmpty, let t = read("typesafe"), !t.isEmpty else { return nil }
        let model = UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 }
            ?? OnDevicePipeline.defaultModel
        return Keys(gemini: g, typesafe: t, model: model)
    }

    static var isSet: Bool { load() != nil }

    static func save(gemini: String, typesafe: String, model: String) {
        if !gemini.isEmpty { write("gemini", gemini) }
        if !typesafe.isEmpty { write("typesafe", typesafe) }
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: modelKey)
    }

    static func clear() {
        for account in ["gemini", "typesafe"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        }
    }

    private static func read(_ account: String) -> String? {
        var out: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Settings: where pricing runs, the keys for on-phone pricing, and the Mac backend URL.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CameraModel.engineKey) private var engine = CameraModel.Engine.phone.rawValue
    @State private var gemini = ""
    @State private var typesafe = ""
    @State private var model = UserDefaults.standard.string(forKey: Keys.modelKey) ?? OnDevicePipeline.defaultModel
    @State private var backendURL = BackendClient.savedURL
    @State private var keysSet = Keys.isSet
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Run on", selection: $engine) {
                        Text("This iPhone").tag(CameraModel.Engine.phone.rawValue)
                        Text("Mac backend").tag(CameraModel.Engine.backend.rawValue)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(engine == CameraModel.Engine.phone.rawValue
                         ? "YOLO runs on the phone; the phone calls Jev and Gemini itself. Works on any Wi-Fi or cellular, no Mac."
                         : "Everything runs on the Mac's backend (`make run`). The phone must be able to reach the Mac.")
                }

                if engine == CameraModel.Engine.phone.rawValue {
                    Section {
                        SecureField(keysSet ? "Gemini key (saved)" : "Gemini API key", text: $gemini)
                        SecureField(keysSet ? "TypeSafe key (saved)" : "TypeSafe API key", text: $typesafe)
                        TextField("Gemini model", text: $model)
                    } header: {
                        Text("API keys")
                    } footer: {
                        Text("Stored in this iPhone's Keychain only. Leave a key field empty to keep the saved one.")
                    }
                    if keysSet {
                        Button("Remove saved keys", role: .destructive) {
                            Keys.clear()
                            keysSet = false
                        }
                    }
                } else {
                    Section("Backend URL") {
                        TextField("http://192.168.1.10:8080", text: $backendURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Keys.save(gemini: gemini, typesafe: typesafe, model: model)
                        BackendClient.savedURL = backendURL
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}
