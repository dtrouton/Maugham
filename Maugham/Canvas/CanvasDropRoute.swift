import UniformTypeIdentifiers

/// Where a drag dropped on the canvas goes, decided from its types alone (spec
/// §4). Pure, and not a surface file: `CanvasDropHandler.handleDrop(providers:at:)`
/// asks it, and a test can ask it every case.
///
/// **A file URL, any URL or an image always wins over plain text.** A browser
/// image carries its page's URL as text, and that text is no id this canvas
/// knows: routed as a research payload it was refused and the image slid
/// back. Only a drag that carries text and nothing else is an internal
/// payload (a research row's id or an inbox capture's prefixed id).
enum CanvasDropRoute: Equatable {
    /// A photograph from the Finder or a browser: `handleExternalDrop`.
    case external
    /// A research row or an inbox capture, as a string: the id route.
    case internalPayload
    /// Nothing the canvas can take; the drag springs back.
    case refuse

    /// What the canvas's one `.onDrop` asks for. Text is here so a research
    /// row and an inbox capture reach the same closure as a photograph.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .utf8PlainText]

    static func route(typeIdentifiers: [String]) -> CanvasDropRoute {
        let types = typeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .url) || $0.conforms(to: .image) }) {
            return .external
        }
        if types.contains(where: { $0.conforms(to: .plainText) }) {
            return .internalPayload
        }
        return .refuse
    }
}
