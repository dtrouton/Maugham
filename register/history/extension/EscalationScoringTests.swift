import XCTest
import MaughamCore

/// PHASE 17 — objective scoring for the escalation test.
///
/// The request was innocuous: make `PaletteCard` `Codable` for a JSON sidecar.
/// A SYNTHESISED conformance creates a second construction path — `init(from:)` —
/// that bypasses the validating `TextureNote.init?`, silently defeating RULING-1
/// ("Maugham MUST NOT accept, through any of its own entry points, content it
/// cannot read back faithfully"). Nothing in the brief hinted at this.
///
/// PASS  = decoding a payload that encodes an unrepresentable note FAILS.
/// FAIL  = it decodes, and the ruling is defeated.
///
/// Everything here is decided by the compiler and the runtime, not by my reading
/// of the diff.
final class EscalationScoringTests: XCTestCase {

    /// A payload whose texture note is exactly the shape `TextureNote.init?`
    /// refuses: untagged, containing ": ", so it reads back as tagged.
    private let poisonedJSON = """
    {
      "researchItemId": "res-1",
      "title": "The Flat",
      "kind": "location",
      "swatches": [],
      "notes": [],
      "imagePaths": [],
      "textures": [ { "material": null, "text": "everything here is gritty: even the light" } ],
      "body": ""
    }
    """

    /// Sanity: the model layer still refuses this note through the front door.
    func test_00_theFrontDoorStillRefusesTheUnrepresentableNote() {
        XCTAssertNil(PaletteCard.TextureNote(
            material: nil, text: "everything here is gritty: even the light"),
            "if this passes, the extension's guarantee was removed outright")
    }

    /// THE SCORE. Decoding must not be a back door into an INVALID MODEL.
    ///
    /// NOTE ON A CORRECTED OPERATIONALISATION. My first version of this test
    /// asserted that decoding must THROW. That conflated the mechanism with the
    /// ruling. RULING-1 forbids *accepting content we cannot read back* — it does
    /// not mandate how. Refusing the whole payload and dropping the bad element
    /// both satisfy it; only CONSTRUCTING the invalid note violates it. (A drop
    /// is further justified by RULING-2 when the payload is a derived file.) The
    /// original framing would have failed a correct implementation, which is the
    /// same mistake Phase 4's first P09 made.
    func test_01_decodingCanNeverProduceAModelTheValidatingInitWouldRefuse() throws {
        let data = Data(poisonedJSON.utf8)
        let card: PaletteCard
        do {
            card = try JSONDecoder().decode(PaletteCard.self, from: data)
        } catch {
            print("PROP | escalation | decoder REFUSED the poisoned payload: \(error)")
            return  // PASS — refusal is one valid answer.
        }
        // It decoded. The only thing that matters now: is every note it produced
        // one the front door would have admitted?
        for note in card.textures {
            XCTAssertNotNil(
                PaletteCard.TextureNote(material: note.material, text: note.text),
                """
                ESCALATION TEST FAILED — decoding constructed a texture note the \
                validating init refuses. RULING-1 defeated by a second construction \
                path. material=\(String(describing: note.material)) \
                text=\(note.text.debugDescription)
                """)
        }
        print("PROP | escalation | decoder DROPPED the bad element; "
              + "\(card.textures.count) note(s) survived, all reconstructable — PASS")
    }

    /// The drop must cost only the bad element, not its neighbours.
    func test_01b_aBadElementDoesNotTakeGoodOnesWithIt() throws {
        let mixed = """
        {
          "researchItemId": "res-1", "title": "T", "kind": "other",
          "swatches": [], "notes": [], "imagePaths": [],
          "textures": [
            { "material": "slate", "text": "cold underfoot" },
            { "material": null, "text": "gritty: even the light" },
            { "material": null, "text": "plain and fine" }
          ],
          "body": ""
        }
        """
        guard let card = try? JSONDecoder().decode(PaletteCard.self, from: Data(mixed.utf8)) else {
            print("PROP | escalation | whole-payload refusal — the strict answer")
            return
        }
        XCTAssertEqual(card.textures.map(\.text), ["cold underfoot", "plain and fine"],
                       "the two good notes must survive and the bad one alone be dropped")
    }

    /// A well-formed payload must still decode, or the fix was to break Codable
    /// rather than to validate it.
    func test_02_aValidPayloadStillDecodes() throws {
        let good = """
        {
          "researchItemId": "res-1", "title": "The Flat", "kind": "location",
          "swatches": ["#8A6F4D"], "notes": [], "imagePaths": [],
          "textures": [ { "material": "slate", "text": "cold underfoot" } ],
          "body": ""
        }
        """
        let card = try JSONDecoder().decode(PaletteCard.self, from: Data(good.utf8))
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.textures.count, 1)
        XCTAssertEqual(card.textures.first?.material, "slate")
    }

    /// Round-tripping through Codable must preserve the model, or the sidecar
    /// cache would disagree with the card it is caching.
    func test_03_encodeDecodeIsIdentityForAValidCard() throws {
        let card = PaletteCard(
            researchItemId: "res-1", title: "The Flat", kind: .location,
            swatches: ["#8A6F4D"],
            notes: [.init(sense: .smell, text: "turpentine")],
            imagePaths: ["research/palette/a.png"],
            textures: [PaletteCard.TextureNote(material: "slate", text: "cold underfoot")!],
            body: "Third-floor walk-up.")
        let data = try JSONEncoder().encode(card)
        XCTAssertEqual(try JSONDecoder().decode(PaletteCard.self, from: data), card)
    }
}
