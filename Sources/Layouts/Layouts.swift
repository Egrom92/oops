import Carbon
import Foundation

/// A keyboard layout as macOS has it: which key (with or without Shift) types which character.
/// Read from the layout itself, so every layout works: U.S., Russian, Estonian, Latvian, Finnish…
public struct KeyboardLayout {
    public let id: String
    public let name: String
    struct Key: Hashable { let code: UInt16; let shift: Bool }
    let keyToChar: [Key: Character]
    let charToKey: [Character: Key]

    /// Types Cyrillic letters (so text in it is "the other script" for a Latin layout).
    public var isCyrillic: Bool { charToKey["ф"] != nil || charToKey["а"] != nil }

    init?(_ source: TISInputSource) {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? id
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        var k2c: [Key: Character] = [:], c2k: [Character: Key] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Main block only (letters, digits, punctuation): the keypad would map "." to itself.
            for code in UInt16(0)...50 {
                for shift in [false, true] {
                    var dead: UInt32 = 0, length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) : 0,
                                   UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                   &dead, chars.count, &length, &chars)
                    guard length == 1, let scalar = Unicode.Scalar(chars[0]), scalar.value >= 0x21, scalar.value != 0x7F
                    else { continue }
                    let key = Key(code: code, shift: shift), ch = Character(scalar)
                    k2c[key] = ch
                    if c2k[ch] == nil { c2k[ch] = key }
                }
            }
        }
        guard !k2c.isEmpty else { return nil }
        keyToChar = k2c
        charToKey = c2k
    }

    /// Letters of `text` this layout can type.
    func coverage(_ text: String) -> Int { text.reduce(0) { $0 + ($1.isLetter && charToKey[$1] != nil ? 1 : 0) } }

    /// The layouts turned on in System Settings, in their order.
    public static func enabled() -> [KeyboardLayout] { list(includeAll: false) }

    /// Any installed layout by id (also ones that are not turned on), for tests.
    public static func installed(_ id: String) -> KeyboardLayout? { list(includeAll: true).first { $0.id == id } }

    public static func currentID() -> String? {
        let s = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        return TISGetInputSourceProperty(s, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    /// Makes `id` the current input source.
    public static func select(_ id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return }
        TISSelectInputSource(source)
    }

    private static func list(includeAll: Bool) -> [KeyboardLayout] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let sources = TISCreateInputSourceList(filter, includeAll)?.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap(KeyboardLayout.init)
    }
}

public enum Converter {
    /// Retypes `text` as if the same keys had been pressed in `to`.
    public static func convert(_ text: String, from: KeyboardLayout, to: KeyboardLayout) -> String {
        String(text.map { ch in from.charToKey[ch].flatMap { to.keyToChar[$0] } ?? ch })
    }

    /// Which layout the text was typed in, and which it was meant for.
    /// - from: the layout that can type most of its letters (ties: the current one, then the recently used);
    /// - to: the most recently used layout of the other script (Latin ↔ Cyrillic), else any other one.
    public static func pick(for text: String, layouts: [KeyboardLayout], current: String?, recent: [String])
        -> (from: KeyboardLayout, to: KeyboardLayout)? {
        guard layouts.count >= 2 else { return nil }
        // Rank: current first, then recently used, then the order in System Settings.
        let order = ([current].compactMap { $0 } + recent + layouts.map(\.id))
        func rank(_ l: KeyboardLayout) -> Int { order.firstIndex(of: l.id) ?? order.count }
        let ranked = layouts.sorted { rank($0) < rank($1) }
        guard let from = ranked.max(by: { a, b in
            let ca = a.coverage(text), cb = b.coverage(text)
            return ca != cb ? ca < cb : rank(a) > rank(b)
        }) else { return nil }
        let others = ranked.filter { $0.id != from.id }
        func recency(_ l: KeyboardLayout) -> Int { recent.firstIndex(of: l.id) ?? Int.max }
        let byRecency = others.sorted { (recency($0), rank($0)) < (recency($1), rank($1)) }
        guard let to = byRecency.first(where: { $0.isCyrillic != from.isCyrillic }) ?? byRecency.first else { return nil }
        return (from, to)
    }
}
