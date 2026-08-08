#!/usr/bin/env swift
//
// pbdump — dump every flavour of the current NSPasteboard entry, with metadata.
//
//   ./tools/pbdump.swift            # type names, byte counts, image dimensions
//   ./tools/pbdump.swift --text     # also preview textual flavours
//
// Answers "what did that app actually publish?" — the question behind every
// decision in clipboard.zig's `image_types` probe order and daemon.zig's
// text-before-image fallthrough. Swift rather than Zig on purpose: this is a
// throwaway diagnostic, and reaching NSPasteboard from Swift costs no FFI
// bindings to maintain.
//
// Default output is deliberately content-free — type names, lengths, and
// image dimensions only — so it's safe to run against a live clipboard
// without spilling whatever you last copied into a terminal or a bug report.
// `--text` opts into previews.

import AppKit
import ImageIO

let showText = CommandLine.arguments.contains("--text")
let pb = NSPasteboard.general

print("pasteboard:  \(pb.name.rawValue)")
print("changeCount: \(pb.changeCount)")

let items = pb.pasteboardItems ?? []
print("items:       \(items.count)")

// Mirrors `Pasteboard.image_types` in src/clipboard.zig, in the same order.
let probed = ["public.png", "public.tiff", "public.jpeg"]
// Types the daemon branches on: the concealed-type opt-out, our own origin
// marker, and the string flavour that wins over any image.
let special = ["org.nspasteboard.ConcealedType", "dev.zclip.origin",
               "public.utf8-plain-text"]

// Header-only read: CGImageSource parses metadata without decoding pixels,
// so a 12MB screenshot costs nothing to inspect.
func imageInfo(_ data: Data) -> String? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let kind = CGImageSourceGetType(src) as String? ?? "?"
    return "\(w)x\(h)  decoded-as \(kind)"
}

func textPreview(_ data: Data) -> String? {
    guard let s = String(data: data, encoding: .utf8) else { return nil }
    let flat = s.replacingOccurrences(of: "\n", with: "\\n")
    return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
}

for (i, item) in items.enumerated() {
    print("\n  [\(i)]")
    for type in item.types {
        let raw = type.rawValue
        let data = item.data(forType: type)
        let len = data?.count ?? 0

        var mark = " "
        if probed.contains(raw) { mark = "*" }
        if special.contains(raw) { mark = "!" }

        var note = ""
        if let d = data {
            if let info = imageInfo(d) {
                note = "  image: \(info)"
            } else if showText, let p = textPreview(d) {
                note = "  text: \"\(p)\""
            } else if String(data: d, encoding: .utf8) != nil {
                note = "  (utf8 text — rerun with --text to preview)"
            }
        }

        let pad = String(repeating: " ", count: max(1, 34 - raw.count))
        print("  \(mark) \(raw)\(pad)\(len) bytes\(note)")
    }
}

print("\n  * = probed by clipboard.zig image_types   ! = load-bearing filter/marker")
