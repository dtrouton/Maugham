# Task 4 report
Implemented `figure` on add_comment / add_query / add_suggested_change / add_craft_note.
- AnnotationToolHelpers.swift: `AnnotationTarget.resolve` (either/or anchor form) and `addFigureNote` (find figure via ReadFigureTool.find over publishFigures(); FigureAnchorAddress; machine-form suggested value via FigureAnnotationOps.suggestedCell with FormulaNames; prior = table[key]; stamp device = Document.loadIdentities[.assistant].deviceId, session mcp-<8>; DocumentStore.addFigureAnnotation). No review-pass stamp.
- AnnotationCreationTools.swift: document_id/paragraph_id now optional in Params, schema `required` = project_id, body; `figure` (+ `suggested_value` on suggestion); descriptions updated. Paragraph path unchanged (existing AnnotationCreationToolsTests green).
- Errors: unknown figure (nearest names), kind mismatch, bad cell/deleted row, range on suggestion, parked, unparsable value (parser message), mixing forms, quote with figure, image figure.
- Bare figure names are not accepted by `figure` (needs tbl:/fig: label per FigureAnchorAddress.parse).
- Tests: MaughamTests/MCP/Tools/FigureAnnotationCreationTests.swift (7). Focused run + TripwireGrepTests green. `./scripts/test.sh`: only UpdateInstallerTests crossVolume (known) failed after fixing a `/*` in a doc comment that tripped test_noScannedFileIsTruncatedByAnUnclosedBlockComment.
- DocBudget: Maugham/MCP/AREA.md 6327 -> 6406 (numbers only; AREA gained one catalogue clause and one rule).
