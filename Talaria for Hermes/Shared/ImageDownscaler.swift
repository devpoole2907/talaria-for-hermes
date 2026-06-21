import UIKit

/// Shrinks picked images before they're sent inline as base64 `image_url` parts.
///
/// Images ride in the JSON request body, and base64 inflates bytes by ~33%, so a
/// full-resolution photo (often several MB of HEIC/PNG) becomes a multi-MB request
/// that servers / proxies reject with HTTP 413. Re-encoding to a bounded-dimension
/// JPEG cuts that to a few hundred KB while staying well within vision models'
/// resolution limits (they downsample large images anyway).
enum ImageDownscaler {
    /// Longest-edge cap. 1568px is at/under the limit common vision models
    /// downsample to, so going larger only inflates the payload for no gain.
    private static let maxDimension: CGFloat = 1568
    /// Target ceiling for the encoded bytes; quality steps down until met.
    private static let maxBytes = 3 * 1024 * 1024
    private static let qualitySteps: [CGFloat] = [0.8, 0.6, 0.45, 0.3]

    /// Returns a downscaled JPEG for `data`, or nil if it isn't a decodable image
    /// (callers should fall back to the original bytes in that case).
    static func prepareForUpload(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = resized(image, maxDimension: maxDimension)

        for quality in qualitySteps {
            if let encoded = scaled.jpegData(compressionQuality: quality),
               encoded.count <= maxBytes {
                return encoded
            }
        }
        // Even at the lowest quality it's still over budget — send that anyway;
        // it's far smaller than the original and gives the best shot at < 413.
        return scaled.jpegData(compressionQuality: qualitySteps.last ?? 0.3)
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // target is already in pixels; don't multiply by screen scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
