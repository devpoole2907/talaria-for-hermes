import Foundation

/// The `input` payload for a session chat request.
///
/// Hermes' `/api/sessions/{id}/chat` accepts either a bare string or an
/// OpenAI-style array of content parts. We send the array form only when there
/// are image attachments, so plain text turns keep the simpler string shape.
enum HermesChatInput: Encodable {
    case text(String)
    case parts([Part])

    /// Builds an input from the user's message plus any attachments. Image
    /// attachments (sniffed by their data, regardless of how they were picked)
    /// become `image_url` parts carrying a base64 data URL. Non-image
    /// attachments are dropped here — the API server has no path for them yet.
    static func make(text: String, attachments: [ComposerAttachment]) -> HermesChatInput {
        let imageURLs: [String] = attachments.compactMap { attachment in
            guard let data = attachment.data, let mime = imageMIMEType(for: data) else { return nil }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        guard !imageURLs.isEmpty else { return .text(text) }

        var parts: [Part] = []
        if !text.isEmpty {
            parts.append(Part(type: "text", text: text, imageURL: nil))
        }
        for url in imageURLs {
            parts.append(Part(type: "image_url", text: nil, imageURL: ImageURL(url: url)))
        }
        return .parts(parts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    struct Part: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }
    }

    struct ImageURL: Encodable {
        let url: String
    }

    /// Sniffs common image formats from the leading bytes. Returns nil for data
    /// that isn't a recognised image so non-image files are excluded.
    static func imageMIMEType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        // HEIC/HEIF: `....ftypheic` / `ftypmif1` etc.
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        return nil
    }
}
