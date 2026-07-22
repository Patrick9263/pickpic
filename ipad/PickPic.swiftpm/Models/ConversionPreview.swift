import Foundation

struct ConversionPreview:
    Codable,
    Hashable,
    Sendable
{
    let sourceFilename: String
    let outputFilename: String
    let byteSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let convertedAt: Date
}
