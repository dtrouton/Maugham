import Foundation
import MaughamCore

/// **The Word (`.docx`) compile** — the third publish format beside
/// `PDFCompiler` and `EPUBCompiler` (report plan 4, R-4-5), through the same
/// gate: the door resolves each body for Word's images (`resolve(bodies:)`),
/// `PublishProblemGate` judges them, and the compiler emits what was judged.
///
/// Report plan 4 Task 2 makes `.docx` a format every door dispatches; the
/// compiler itself is Tasks 3–5's. Until then each compile arm answers
/// `notYetBuiltStub(problems:)`.
public enum DOCXCompiler {

    /// The same shape as `EPUBCompiler.Result`: Word has no log, so a door's
    /// `logExcerpt` for a DOCX compile is `""`.
    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors: [TectonicLogParser.Diagnostic]
        /// Every body's publish problems as the compile ended — see
        /// `PDFCompiler.Result.problems`.
        public var problems: [PublishProblem] = []
    }

    /// The image formats a Word body may carry. Word embeds png, jpeg and gif
    /// natively; pdf and svg are rasterised to PNG when the DOCX is prepared
    /// (R-4-2), so a Report with PDF charts exports to Word.
    static let imageAllowed: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "svg"]

    /// Every body resolved for Word's images: the door's gate calls this and
    /// hands the answer to the compiler.
    static func resolve(bodies: [BodyPlan.Body]) throws -> [PublishProblemGate.Body] {
        try PublishProblemGate.resolve(bodies: bodies, imageAllowed: imageAllowed)
    }

    // MARK: - TEMPORARY STUB (report plan 4 Task 2; Tasks 4–5 delete it)

    /// The sentence the stub fails with. TEMPORARY — see `notYetBuiltStub`.
    static let notYetBuiltSentence = "Word export isn't built yet"

    /// **TEMPORARY, the one stub compile arm.** The two minting
    /// doors (`CompileOrchestrator`, `Republisher`) call this in their `.docx` arm
    /// until Task 4 builds the compiler and Task 5 the republish; the
    /// whole-branch review checks that no caller and no definition remain.
    /// It writes nothing and returns a failed `Result` — no output path, the
    /// one error — carrying the gate's problems so they ride along as for any
    /// failed compile. Nothing is minted on the failure path.
    static func notYetBuiltStub(problems: [PublishProblem]) -> Result {
        Result(
            outputPath: "", warnings: [],
            errors: [TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: notYetBuiltSentence,
                contextLines: ["Nothing was compiled."])],
            problems: problems)
    }
}
