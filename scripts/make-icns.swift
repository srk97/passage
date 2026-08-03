#!/usr/bin/env swift

import Foundation

private struct IconEntry {
    let type: String
    let fileName: String
}

private let entries = [
    IconEntry(type: "icp4", fileName: "icon_16x16.png"),
    IconEntry(type: "icp5", fileName: "icon_32x32.png"),
    IconEntry(type: "icp6", fileName: "icon_32x32@2x.png"),
    IconEntry(type: "ic07", fileName: "icon_128x128.png"),
    IconEntry(type: "ic08", fileName: "icon_256x256.png"),
    IconEntry(type: "ic09", fileName: "icon_512x512.png"),
    IconEntry(type: "ic10", fileName: "icon_512x512@2x.png"),
]

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icns.swift ICONSET OUTPUT\n".utf8))
    exit(64)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])

func appendUInt32(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

do {
    var body = Data()
    for entry in entries {
        let png = try Data(contentsOf: input.appendingPathComponent(entry.fileName))
        body.append(Data(entry.type.utf8))
        appendUInt32(8 + png.count, to: &body)
        body.append(png)
    }

    var archive = Data("icns".utf8)
    appendUInt32(8 + body.count, to: &archive)
    archive.append(body)
    try archive.write(to: output, options: [.atomic])
} catch {
    FileHandle.standardError.write(Data("make-icns: \(error.localizedDescription)\n".utf8))
    exit(1)
}
