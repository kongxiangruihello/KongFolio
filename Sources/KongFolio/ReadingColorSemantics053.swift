import AppKit

enum ReadingColorSemantics053 {
    static let key="KongFolio.colorMeanings053"
    static func code(_ color:NSColor)->String? {
        guard let c=color.usingColorSpace(.sRGB) else { return nil }
        return String(format:"#%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
    }
    static func meanings(_ defaults:UserDefaults = .standard)->[String:String] { defaults.dictionary(forKey:key) as? [String:String] ?? [:] }
    static func set(_ code:String,meaning:String,defaults:UserDefaults = .standard) {
        var values=meanings(defaults);values[code.uppercased()]=meaning.isEmpty ? nil:meaning;defaults.set(values,forKey:key)
    }
    static func meaning(_ color:NSColor,defaults:UserDefaults = .standard)->String? { code(color).flatMap{meanings(defaults)[$0]} }
}
