import Foundation

public enum EPUBZipPackager {

    public enum Error: Swift.Error {
        case zipFailed(exitCode: Int32, stderr: String)
    }

    /// Writes the EPUB to `output`. Uses `/usr/bin/zip` to build the archive
    /// because Foundation's Compression framework doesn't provide a high-level
    /// zip writer and EPUB requires `mimetype` first + uncompressed.
    public static func write(
        package pkg: EPUBPackage,
        to output: URL,
        workingDirectory wd: URL
    ) async throws {
        let stage = wd.appendingPathComponent("epub-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        // 1. mimetype (no extension, exact content, no trailing newline).
        try EPUBContainerWriter.mimetypeContent
            .write(to: stage.appendingPathComponent("mimetype"),
                   atomically: true, encoding: .ascii)

        // 2. META-INF/container.xml.
        let metaInf = stage.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try EPUBContainerWriter.containerXML()
            .write(to: metaInf.appendingPathComponent("container.xml"),
                   atomically: true, encoding: .utf8)

        // 3. OEBPS/*
        let oebps = stage.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try EPUBOPFWriter.opfXML(for: pkg)
            .write(to: oebps.appendingPathComponent("content.opf"),
                   atomically: true, encoding: .utf8)
        try EPUBOPFWriter.navXHTML(for: pkg)
            .write(to: oebps.appendingPathComponent("nav.xhtml"),
                   atomically: true, encoding: .utf8)
        try pkg.stylesheetCSS
            .write(to: oebps.appendingPathComponent("styles.css"),
                   atomically: true, encoding: .utf8)
        for s in pkg.sections {
            try EPUBOPFWriter.sectionXHTML(for: s)
                .write(to: oebps.appendingPathComponent(s.filename),
                       atomically: true, encoding: .utf8)
        }
        if let cover = pkg.cover {
            try cover.data.write(to: oebps.appendingPathComponent(cover.filename),
                                 options: .atomic)
        }

        // 4. zip: mimetype first uncompressed, then the rest compressed.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        try await zip(
            stage: stage, output: output,
            firstUncompressedFile: "mimetype",
            otherFiles: ["META-INF", "OEBPS"]
        )
    }

    private static func zip(
        stage: URL, output: URL,
        firstUncompressedFile first: String,
        otherFiles others: [String]
    ) async throws {
        // Step A: zip -X0 mimetype (uncompressed, no extras, store-only).
        try await runZip(args: ["-X0", output.path, first], in: stage)
        // Step B: zip -Xr9D output META-INF OEBPS (recursive, normal compress).
        try await runZip(args: ["-Xr9D", output.path] + others, in: stage)
    }

    private static func runZip(args: [String], in directory: URL) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = args
        p.currentDirectoryURL = directory
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let err = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
                    cont.resume(throwing: Error.zipFailed(
                        exitCode: proc.terminationStatus, stderr: err))
                }
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
