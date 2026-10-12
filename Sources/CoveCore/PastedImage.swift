import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Clipboard pixels become ordinary draft attachments; no temporary file or upload is needed.
public enum PastedImage {
  public static func attachment(data: Data, name: String = "Pasted image") throws -> OutgoingAttachment {
    guard data.count <= OutgoingAttachment.totalLimit else {
      throw CoveError.message("The copied image exceeds Gmail’s 25 MB attachment limit.")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let identifier = CGImageSourceGetType(source),
          let type = UTType(identifier as String) else {
      throw CoveError.message("Cove couldn’t read the copied image.")
    }
    // Preserve compressed bytes (including animated GIFs). Clipboard TIFF/HEIC becomes PNG.
    if [UTType.png, .jpeg, .gif].contains(type) {
      return OutgoingAttachment(filename: name + "." + (type.preferredFilenameExtension ?? "png"),
                                mimeType: type.preferredMIMEType, data: data)
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
    guard width > 0, height > 0, width * height <= 40_000_000,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw CoveError.message("The copied image is too large or couldn’t be opened.")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      throw CoveError.message("Cove couldn’t prepare the copied image.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CoveError.message("Cove couldn’t prepare the copied image.")
    }
    let attachment = OutgoingAttachment(filename: name + ".png", mimeType: "image/png", data: output as Data)
    try OutgoingAttachment.validate([attachment])
    return attachment
  }
}
