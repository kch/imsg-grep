#!/usr/bin/swift

/**
 * Decodes archived NSAttributedString from stdin.
 * Accepts raw binary or hex with --hex flag.
 * Used for decoding macOS pasteboard data or Messages.app attributedBody.
 *
 * Example:
 *   pbpaste | ./decode
 *   sqlite3 chat.db "SELECT hex(attributedBody) FROM message WHERE ROWID = 126885;" | ./decode --hex
 */

 import Foundation
import ObjectiveC

let args = CommandLine.arguments
let readHex = args.count > 1 && args[1] == "--hex"

// Setup NSUnarchiver
let NSUnarchiver: AnyClass = NSClassFromString("NSUnarchiver")!
let sel = NSSelectorFromString("unarchiveObjectWithData:")
let imp = NSUnarchiver.method(for: sel)
let unarchive = unsafeBitCast(imp, to: (@convention(c) (AnyClass, Selector, NSData) -> NSAttributedString?).self)

// Read stdin
let input = FileHandle.standardInput.availableData

let data: Data
if readHex {
    let hexString = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    data = Data(hex: hexString) ?? Data()
} else {
    data = input
}

if let str = unarchive(NSUnarchiver, sel, data as NSData)?.string {
    print(str)
} else {
    fputs("Failed to decode data\n", stderr)
    exit(1)
}

// Hex helper
extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex

        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            let bytes = hex[index..<nextIndex]
            if let byte = UInt8(bytes, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        self = data
    }
}
