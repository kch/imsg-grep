// Image to PNG conversion - both CLI and library versions
// Applies rotation metadata to actual pixels, strips orientation from output.
// Optional: resample to fit dimensions, place in centered box with black background.
//
// CLI Usage: ./img2png < input.jpg > output.png
//        ./img2png --fit 800x600 < input.jpg > output.png
//        ./img2png --fit 800x600 --box 1024x768 < input.jpg > output.png
//        ./img2png --info < input.jpg   # prints WxH to stdout
//
// Build CLI:    swiftc -O -whole-module-optimization -lto=llvm-full -o bin/img2png ext/img2png.swift
// Build dylib:  swiftc -O -whole-module-optimization -lto=llvm-full -emit-library -D LIBRARY -o lib/imsg-grep/images/img2png.dylib ext/img2png.swift

import Foundation
import ImageIO
import UniformTypeIdentifiers

let VERSION = "1.0.0"

// Shared image processing functions

func loadImage(from data: Data) -> (CGImage, Int, Int)? {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        return nil
    }

    let orientation = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
        .flatMap { $0 as? [String: Any] }
        .flatMap { $0[kCGImagePropertyOrientation as String] as? UInt32 }
        .flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up

    let rotatedWidth  = orientation.rawValue > 4 ? image.height : image.width
    let rotatedHeight = orientation.rawValue > 4 ? image.width : image.height

    guard let rotateContext = CGContext(data: nil, width: rotatedWidth, height: rotatedHeight,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    rotateContext.interpolationQuality = .high

    let w = CGFloat(rotatedWidth)
    let h = CGFloat(rotatedHeight)

    let transforms: [CGImagePropertyOrientation: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        .down:          (w, h,  1,  1,  .pi),
        .downMirrored:  (w, h, -1,  1,  .pi),
        .left:          (w, 0,  1,  1,  .pi / 2),
        .leftMirrored:  (w, 0, -1,  1,  .pi / 2),
        .right:         (0, h,  1,  1, -.pi / 2),
        .rightMirrored: (0, h, -1,  1, -.pi / 2),
        .upMirrored:    (w, 0, -1,  1,  0),
    ]
    let (tx, ty, sx, sy, rot) = transforms[orientation] ?? (0, 0, 1, 1, 0)

    if tx != 0 || ty != 0 { rotateContext.translateBy(x: tx, y: ty) }
    if sx != 1 || sy != 1 { rotateContext.scaleBy(x: sx, y: sy) }
    if rot != 0           { rotateContext.rotate(by: rot) }

    rotateContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    guard let rotatedImage = rotateContext.makeImage() else {
        return nil
    }

    return (rotatedImage, rotatedWidth, rotatedHeight)
}

func emitPNG(image: CGImage, fitW: Int = 0, fitH: Int = 0, boxW: Int = 0, boxH: Int = 0) -> Data? {
    var finalImage  = image
    var finalWidth  = image.width
    var finalHeight = image.height

    // Fit if requested
    if fitW > 0 && fitH > 0 {
        let scale = min(Double(fitW) / Double(image.width), Double(fitH) / Double(image.height))
        let scaledW = Int(Double(image.width) * scale)
        let scaledH = Int(Double(image.height) * scale)

        guard let fitContext = CGContext(data: nil, width: scaledW, height: scaledH,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        fitContext.interpolationQuality = .high
        fitContext.draw(image, in: CGRect(x: 0, y: 0, width: scaledW, height: scaledH))

        guard let fittedImage = fitContext.makeImage() else {
            return nil
        }

        finalImage  = fittedImage
        finalWidth  = scaledW
        finalHeight = scaledH
    }

    // Box if requested
    if boxW > 0 && boxH > 0 {
        guard let boxContext = CGContext(data: nil, width: boxW, height: boxH,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        boxContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        boxContext.fill(CGRect(x: 0, y: 0, width: boxW, height: boxH))

        let x = (boxW - finalWidth) / 2
        let y = (boxH - finalHeight) / 2
        boxContext.draw(finalImage, in: CGRect(x: x, y: y, width: finalWidth, height: finalHeight))

        guard let boxedImage = boxContext.makeImage() else {
            return nil
        }

        finalImage = boxedImage
    }

    let outputData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(outputData, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }

    let options: [CFString: Any] = [kCGImagePropertyPNGCompressionFilter: 9]
    CGImageDestinationAddImage(destination, finalImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        return nil
    }

    return outputData as Data
}

// MARK: - Library API

// Opaque image handle
public class ImageHandle {
    let image: CGImage
    let width: Int
    let height: Int

    init(image: CGImage, width: Int, height: Int) {
        self.image  = image
        self.width  = width
        self.height = height
    }
}

// Load image from file path, apply rotation. Returns opaque handle or null on error.
@_cdecl("img2png_load_path")
public func img2png_load_path(path: UnsafePointer<CChar>,
                              outW: UnsafeMutablePointer<Int>,
                              outH: UnsafeMutablePointer<Int>) -> UnsafeMutableRawPointer? {
    let pathStr = String(cString: path)
    let url = URL(fileURLWithPath: pathStr)

    guard let data = try? Data(contentsOf: url) else {
        return nil
    }

    return img2png_load(inputData: data.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! },
                        inputLen: data.count, outW: outW, outH: outH)
}

// Load image from data, apply rotation. Returns opaque handle or null on error.
@_cdecl("img2png_load")
public func img2png_load(inputData: UnsafePointer<UInt8>, inputLen: Int,
                         outW: UnsafeMutablePointer<Int>,
                         outH: UnsafeMutablePointer<Int>) -> UnsafeMutableRawPointer? {
    let data = Data(bytes: inputData, count: inputLen)

    guard let (rotatedImage, rotatedWidth, rotatedHeight) = loadImage(from: data) else {
        return nil
    }

    let handle = ImageHandle(image: rotatedImage, width: rotatedWidth, height: rotatedHeight)
    outW.pointee = rotatedWidth
    outH.pointee = rotatedHeight
    return Unmanaged.passRetained(handle).toOpaque()
}

// Convert to PNG with optional fitting and boxing.
// fitW, fitH: scale to fit within these dimensions (0 = skip)
// boxW, boxH: place in centered box with black background (0 = skip)
// Returns PNG data and length via out parameters. Caller must free data.
@_cdecl("img2png_convert")
public func img2png_convert(
    handle: UnsafeMutableRawPointer,
    fitW: Int, fitH: Int,
    boxW: Int, boxH: Int,
    outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    outLen: UnsafeMutablePointer<Int>
) -> Bool {
    let img = Unmanaged<ImageHandle>.fromOpaque(handle).takeUnretainedValue()

    guard let pngData = emitPNG(image: img.image, fitW: fitW, fitH: fitH, boxW: boxW, boxH: boxH) else {
        return false
    }

    let bytes = malloc(pngData.count)!
    _ = pngData.withUnsafeBytes { memcpy(bytes, $0.baseAddress!, pngData.count) }

    outData.pointee = bytes.assumingMemoryBound(to: UInt8.self)
    outLen.pointee  = pngData.count

    return true
}

// Release image handle
@_cdecl("img2png_release")
public func img2png_release(handle: UnsafeMutableRawPointer) {
    Unmanaged<ImageHandle>.fromOpaque(handle).release()
}

// Free memory allocated by library
@_cdecl("img2png_free")
public func img2png_free(ptr: UnsafeMutableRawPointer?) {
    free(ptr)
}

// MARK: - CLI Main

func parseDimensions(_ str: String) -> (Int, Int)? {
    let parts = str.split(separator: "x")
    guard parts.count == 2,
          let w = Int(parts[0]),
          let h = Int(parts[1]) else { return nil }
    return (w, h)
}

#if !LIBRARY
@main
struct CLI {
    static func main() {
    // Parse arguments
    var fit: (Int, Int)?
    var box: (Int, Int)?
    var infoMode = false
    var i = 1

    while i < CommandLine.arguments.count {
        switch CommandLine.arguments[i] {
        case "--version":
            print(VERSION)
            exit(0)
        case "--fit":
            guard i + 1 < CommandLine.arguments.count,
                  let dims = parseDimensions(CommandLine.arguments[i + 1]) else {
                fputs("Invalid --fit WxH\n", stderr)
                exit(1)
            }
            fit = dims
            i += 2
        case "--box":
            guard i + 1 < CommandLine.arguments.count,
                  let dims = parseDimensions(CommandLine.arguments[i + 1]) else {
                fputs("Invalid --box WxH\n", stderr)
                exit(1)
            }
            box = dims
            i += 2
        case "--info":
            infoMode = true
            i += 1
        default:
            fputs("Unknown option: \(CommandLine.arguments[i])\n", stderr)
            exit(1)
        }
    }

    // Read entire stdin into memory
    let inputData = FileHandle.standardInput.readDataToEndOfFile()

    guard !inputData.isEmpty else {
        if CommandLine.arguments.count == 1 {
            print("Usage: img2png [OPTIONS] < input > output")
            print("")
            print("Options:")
            print("  --fit WxH        Scale to fit within dimensions")
            print("  --box WxH        Place in centered box with black background")
            print("  --info           Print dimensions only")
            print("  --version        Print version")
            print("")
            print("Examples:")
            print("  img2png < input.jpg > output.png")
            print("  img2png --fit 800x600 < input.jpg > output.png")
            print("  img2png --fit 800x600 --box 1024x768 < input.jpg > output.png")
            exit(0)
        } else {
            fputs("No input data\n", stderr)
            exit(1)
        }
    }

    guard let (rotatedImage, rotatedWidth, rotatedHeight) = loadImage(from: inputData) else {
        fputs("Failed to load image\n", stderr)
        exit(1)
    }

    // If info mode, print dimensions and exit
    if infoMode {
        print("\(rotatedWidth)x\(rotatedHeight)")
        exit(0)
    }

    let fitW = fit?.0 ?? 0
    let fitH = fit?.1 ?? 0
    let boxW = box?.0 ?? 0
    let boxH = box?.1 ?? 0

    guard let pngData = emitPNG(image: rotatedImage, fitW: fitW, fitH: fitH, boxW: boxW, boxH: boxH) else {
        fputs("Failed to convert to PNG\n", stderr)
        exit(1)
    }

    // Write to stdout
    FileHandle.standardOutput.write(pngData)
    }
}
#endif
