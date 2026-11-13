// Checks the conversion on the real macOS layouts:  swift run LayoutCheck
import Foundation
import Layouts

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "OK    " : "FAIL  ") + what)
    if !ok { failures += 1 }
}
func L(_ id: String) -> KeyboardLayout {
    guard let l = KeyboardLayout.installed("com.apple.keylayout." + id) else { print("missing layout \(id)"); exit(2) }
    return l
}
func conv(_ s: String, _ a: String, _ b: String) -> String { Converter.convert(s, from: L(a), to: L(b)) }
func expect(_ s: String, _ a: String, _ b: String, _ want: String) {
    let got = conv(s, a, b)
    check(got == want, "\(a) → \(b): «\(s)» → «\(got)»" + (got == want ? "" : ", want «\(want)»"))
}

// What the Hammerspoon version did (U.S. ↔ Russian – PC), including punctuation on the same keys.
expect("ghbdtn", "US", "RussianWin", "привет")
expect("Ghbdtn? rfr ltkf&", "US", "RussianWin", "Привет, как дела?")
expect("руддщ цщкдв", "RussianWin", "US", "hello world")
expect("/", "US", "RussianWin", ".")
expect("@#$^", "US", "RussianWin", "\"№;:")

// Estonian: ü õ ö ä sit on the keys of х ъ ж э.
expect("üjhjij", "Estonian", "RussianWin", "хорошо")
expect("хорошо", "RussianWin", "Estonian", "üjhjij")
expect("ntht", "Estonian", "RussianWin", "тере")
expect("t[druk", "US", "Estonian", "tüdruk")

// Baltic and Nordic layouts against Russian – PC: a round trip gives back the same text.
let sample = "Съешь же ещё этих мягких французских булок, да выпей чаю"
for id in ["Latvian", "Lithuanian", "Finnish", "Swedish", "Norwegian", "Danish", "Icelandic", "German", "Polish"] {
    let there = conv(sample, "RussianWin", id), back = conv(there, id, "RussianWin")
    check(back == sample, "RussianWin ↔ \(id): «\(there.prefix(24))…» and back")
}
expect("ж", "RussianWin", "Finnish", "ö")
expect("ghbdsn", "US", "Ukrainian-PC", "привіт")
expect("ghbdtn", "US", "Russian", "привет")

// Which way to convert.
let three = [L("US"), L("RussianWin"), L("Estonian")]
func pick(_ s: String, current: String, recent: [String]) -> String {
    guard let p = Converter.pick(for: s, layouts: three, current: "com.apple.keylayout." + current,
                                 recent: recent.map { "com.apple.keylayout." + $0 }) else { return "none" }
    return "\(p.from.id.split(separator: ".").last!)→\(p.to.id.split(separator: ".").last!)"
}
check(pick("ghbdtn", current: "US", recent: ["US", "RussianWin"]) == "US→RussianWin", "Latin text on U.S. goes to Russian")
check(pick("руддщ", current: "RussianWin", recent: ["RussianWin", "Estonian", "US"]) == "RussianWin→Estonian",
      "Cyrillic text goes to the Latin layout used last (Estonian)")
check(pick("руддщ", current: "RussianWin", recent: ["RussianWin", "US", "Estonian"]) == "RussianWin→US",
      "… or U.S., if that was used last")
check(pick("üjhjij", current: "US", recent: ["US"]) == "Estonian→RussianWin", "ü means it was typed on Estonian")
check(pick("ghbdtn", current: "Estonian", recent: ["Estonian", "RussianWin"]) == "Estonian→RussianWin",
      "plain Latin letters: the current layout is the source")
check(Converter.pick(for: "abc", layouts: [L("US")], current: nil, recent: []) == nil, "one layout: nothing to convert to")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
