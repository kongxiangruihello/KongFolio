import Foundation

/// Library display settings must never change the reader/file editor the user
/// already configured. No document text or exported formatting is stored here.
enum LibraryWritingPreferences {
    static let key = "KongFolio.libraryWritingDisplay051"
    static func load(_ defaults:UserDefaults = .standard)->EditorDisplayOptions {
        guard let data = defaults.data(forKey:key),let value = try? JSONDecoder().decode(EditorDisplayOptions.self,from:data),value.valid else { return EditorDisplayOptions() }
        return value
    }
    static func save(_ value:EditorDisplayOptions,to defaults:UserDefaults = .standard) {
        guard value.valid,let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data,forKey:key)
    }
}
