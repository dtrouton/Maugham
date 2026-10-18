import XCTest

/// **The person key's doors, each counted** (your devices are you, plan 1
/// Task 8). Tasks 2–7 built one key per PERSON, a claim a device makes with it,
/// the verbs that link and forget it, and the recognition that admits a device
/// silently because of it. Every one of those is a door a device walks through
/// WITHOUT the root being asked, so a second door is a second, unreviewed way
/// in — and it arrives silently: a second verifier that forgets the device
/// binding admits a stranger carrying Denver's copied claim (Review Focus 1), a
/// second store construction reaches the developer's own iCloud Keychain from a
/// test host, a second caller of `recognise` admits on a Mac that is not the
/// book's root (Review Focus 5).
///
/// **The shape** is the P3b counted lists' (tripwire 50): each census is a
/// named ARRAY of `Site`s, each naming a spelling and the exact count per file
/// it is found in, comments excluded (`SourceScan`). The assertion is EQUALITY,
/// so it fails in both directions — a site that APPEARED is a second door, and
/// one that VANISHED is a door that moved without the census being told why.
/// Because the count is per FILE, an allow-listed file is not a free pass: a
/// second spelling of the door inside the very file that owns the first moves
/// its count. Count the arrays, never a number written in prose.
///
/// **A key may name a TYPE** (`type:DocumentStore`, foundations plan 2 Task 3):
/// every Mac or Core file declaring it, its count the SUM over those files —
/// so splitting a monolith into extension files moves no census, while a site
/// moved into an unrelated file still fails. A phone file is never claimed by
/// a type key: it stays keyed `MaughamPhone/<file>`.
///
/// **The roots are the Mac, MaughamCore AND the phone, and the phone's
/// allow-list is EMPTY** (controller ruling, plan 1 Task 8 fix round). Plan 1
/// has no phone construction point; plan 2's phone store-injection file and
/// any phone signing site must be registered here DELIBERATELY, as a
/// `MaughamPhone/<file>` key. A phone file is keyed by that prefix, so a phone
/// file that happens to share an allow-listed Mac file's NAME is never absorbed
/// into the Mac's allowance.
///
/// **Stated limits:**
/// - A call reflowed across two lines (`PersonKey` then `.findOrCreate(` on
///   the next) is invisible to a per-line regex. An EXISTING site reflowed
///   fails as vanished; a NEW site written reflowed escapes.
///   `TripwireGrepTests` shares the limit.
/// - `\.sign\(` is deliberately broad — every `.sign(` in all three trees.
///   Today it is exactly the claim writer's; an unrelated future `.sign(`
///   needs an entry with its reason, which is the point.
final class PersonKeyCensusTests: XCTestCase {

    /// One counted spelling. `pattern` is a regular expression matched against
    /// comment-stripped code lines; `sample` is a literal spelling the pattern
    /// matches, which the planted-offender controls write into a temp tree.
    struct Site {
        let pattern: String
        let sample: String
        let expected: [String: Int]
    }

    // MARK: - 1. Where a person-key store is constructed

    /// **`PersonKeyAccess.swift` is the ONE production construction of a
    /// `PersonKeyStore`**, and `DocumentStore.swift` its one reader. Core
    /// DEFINES both stores and constructs neither. A second construction is a
    /// second answer to *may a test host reach the keychain* — and the wrong
    /// answer creates a synchronizable item on the developer's own Apple ID
    /// from a gate worker. (The phone's construction file is plan 2's.)
    static let storeConstruction: [Site] = [
        Site(pattern: #"KeychainPersonKeyStore\("#,
             sample: "KeychainPersonKeyStore(accessGroup: g)",
             expected: ["PersonKeyAccess.swift": 1,
                        "MaughamPhone/PhonePersonKeyAccess.swift": 1]),
        Site(pattern: #"InMemoryPersonKeyStore\("#,
             sample: "InMemoryPersonKeyStore()",
             expected: ["PersonKeyAccess.swift": 1,
                        "MaughamPhone/PhonePersonKeyAccess.swift": 1]),
        // The store's one consumer per surface: the Mac's open, and the
        // phone's declaration on its first write in a book (plan 2 Task 1 —
        // `PhonePersonKeyAccess.store` matches this spelling by design, so
        // the phone's reader is counted here rather than escaping).
        // `storeForTesting` is a different identifier (no `\b` match).
        // The decision (and the team id) is Core's; each surface asks it once,
        // from its own construction file (plan 2 Task 1 fix round).
        Site(pattern: #"PersonKeyStoreChoice\.choose\("#,
             sample: "PersonKeyStoreChoice.choose(injected: i, isTestHost: h)",
             expected: ["PersonKeyAccess.swift": 1,
                        "MaughamPhone/PhonePersonKeyAccess.swift": 1]),
        Site(pattern: #"PersonKeyAccess\.store\b"#,
             sample: "let s = PersonKeyAccess.store",
             expected: ["type:DocumentStore": 1,
                        "MaughamPhone/PhoneDeviceRecord.swift": 1]),
    ]

    // MARK: - 2. Where a person claim is verified

    /// **A claim is verified in `RegistryReader` only.** What P signs is
    /// rebuilt from the CONTAINING record's device (`signedContent(forDevice:)`),
    /// which is the whole of why a claim copied into a stranger's record fails
    /// there. A second verifier is the place that binding gets forgotten.
    ///
    /// **This census pins what was BUILT, not what the plan said** (accepted by
    /// the controller): the plan named `RegistryPersonClaim.swift` as the
    /// verifier's home, but that file holds only the claim's SHAPE and what is
    /// signed; the check lives in `RegistryReader`, beside the record verifier —
    /// tripwire 42's census lets exactly the writer and the reader ask for a
    /// digest.
    static let claimVerification: [Site] = [
        // The verifier: two statics (of a record; of a claim not yet in one)
        // and the registry's lookup of the verified map.
        Site(pattern: #"func verifiedPersonClaim\("#,
             sample: "func verifiedPersonClaim(_ c: PersonClaim) -> Bool",
             expected: ["RegistryReader.swift": 3]),
        // Its static callers: the registry building its verified map, and a
        // device checking the claim it is about to write into its own record.
        Site(pattern: #"RegistryReader\.verifiedPersonClaim\("#,
             sample: "RegistryReader.verifiedPersonClaim(of: r)",
             expected: ["RegistryPresence.swift": 2, "RegistryReader.swift": 1]),
        // What a claim is checked OVER — the reader alone rebuilds it.
        Site(pattern: #"signedContent\(forDevice:"#,
             sample: "claim.signedContent(forDevice: d)",
             expected: ["RegistryReader.swift": 1]),
        // What a claim is SIGNED over — its definition, and the writer.
        Site(pattern: #"SignedContent\("#,
             sample: "PersonClaim.SignedContent(device: d, personKey: k, personPub: p, name: n)",
             expected: ["RegistryPersonClaim.swift": 1, "RegistryWriter.swift": 1]),
        // A RAW claim read off a record — unverified. The record's own field and
        // decoder, and the verifier. Everything else reads
        // `Registry.verifiedPersonClaims`. (`maugham.personClaim.v1`, the
        // signed domain string, is not a read.)
        Site(pattern: #"(?<!maugham)\.personClaim\b(?!\s*\()"#,
             sample: "let raw = record.personClaim",
             expected: ["RegistryRecord.swift": 2, "RegistryReader.swift": 1]),
        // The one signature verifier: a line's seal, a record's signature and a
        // claim's all go through it. A new caller is a new verifier.
        Site(pattern: #"credentialsVerify\("#,
             sample: "OpLogChain.credentialsVerify(c, over: d)",
             expected: ["type:OpLogChain": 2, "type:OpLogStore": 1,
                        "RegistryReader.swift": 2]),
    ]

    // MARK: - 3. Who asks recognition

    /// **`Recognition.recognise` has named callers**: `RegistryPresence`'s two
    /// passes (the admission itself, which runs only on the Mac holding the
    /// book's root, and the link pass), and `AdmissionDecision`, which asks it
    /// only to decide whether a device goes to the sheet. A new caller is a new
    /// place a device may be admitted without the root being asked.
    static let recognition: [Site] = [
        Site(pattern: #"Recognition\.recognise\("#,
             sample: "Recognition.recognise(device: d, in: r)",
             expected: ["RegistryPresence.swift": 2, "AdmissionDecision.swift": 1]),
        // The silent admission's own verb, reached from Presence alone (ruling:
        // `RegistryPresence` names no rung, so the rung lives in Admission)…
        Site(pattern: #"RegistryAdmission\.admitRecognised\("#,
             sample: "RegistryAdmission.admitRecognised(d, in: root)",
             expected: ["RegistryPresence.swift": 1]),
        // …and Presence's pass, reached from the DocumentStore's open and its
        // on-arrival verb.
        Site(pattern: #"RegistryPresence\.admitRecognised\("#,
             sample: "RegistryPresence.admitRecognised(in: root)",
             expected: ["type:DocumentStore": 2]),
    ]

    // MARK: - 4. Who links and forgets a person key

    /// **Linking is `RegistryPresence`'s** (at open, from a verified claim on
    /// an already-admitted device — PK-3) **and forgetting is the
    /// `DocumentStore`'s** (the root's People & Devices verb). Both re-sign
    /// person records; a new caller is a record re-signed by nobody's decision.
    static let linkAndForget: [Site] = [
        Site(pattern: #"RegistryAdmission\.linkPersonKey\("#,
             sample: "RegistryAdmission.linkPersonKey(k, to: p)",
             expected: ["RegistryPresence.swift": 1]),
        Site(pattern: #"RegistryAdmission\.forgetPersonKey\("#,
             sample: "RegistryAdmission.forgetPersonKey(person: p)",
             expected: ["type:DocumentStore": 1]),
    ]

    // MARK: - 5. Who finds the key, and who signs with it

    /// **The person key is found once per surface, and signs one thing.**
    /// `findOrCreate` is called at the Mac's open alone; the phone calls the
    /// find-only `PersonKey.find` from its declaration and never mints; the
    /// claim is made by `RegistryWriter.personClaim` alone, called from Core's
    /// one claim rule (`RegistryPresence.claimIntent`) that both surfaces ask;
    /// and the only `.sign(` in Mac + Core is the writer's, over the claim's
    /// content.
    /// The person key is a SOFTWARE key (tripwire 36's one named exception), so
    /// what it signs is the whole of what it can vouch for — a second signing
    /// site is the key vouching for something nobody designed it to.
    /// `mintItem(` / `PersonKeyItem(` are the key's one mint, in its own file.
    static let personKeySigning: [Site] = [
        // The Mac's open alone MAY create the key (it has the writer's name
        // to seed it with)…
        Site(pattern: #"PersonKey\.findOrCreate\("#,
             sample: "PersonKey.findOrCreate(in: s, seedName: n)",
             expected: ["type:DocumentStore": 1]),
        // …and the phone only FINDS it (plan 2 Task 1, controller ruling 5:
        // a phone that minted would fork the person) — once, in
        // `PhoneDeviceRecord.findPersonKey`, which the claim AND Settings'
        // *This Device* line both ask (plan 2 Task 2: the line routes through
        // this reader rather than being a second one). `finding` is `find`
        // saying why there is no key; either spelling is the same door.
        Site(pattern: #"PersonKey\.find(?:ing)?\("#,
             sample: "PersonKey.find(in: s)",
             expected: ["MaughamPhone/PhoneDeviceRecord.swift": 1]),
        // The claim is signed in ONE place for both surfaces — Core's
        // `RegistryPresence.claimIntent` (plan 2 Task 1 fix round, tripwire 19).
        Site(pattern: #"RegistryWriter\.personClaim\("#,
             sample: "RegistryWriter.personClaim(forDevice: d, signedBy: k)",
             expected: ["RegistryPresence.swift": 1]),
        Site(pattern: #"\.sign\("#,
             sample: "let s = try key.sign(digest)",
             expected: ["RegistryWriter.swift": 1]),
        Site(pattern: #"mintItem\("#,
             sample: "let i = PersonKey.mintItem(name: n)",
             expected: ["PersonKey.swift": 2]),
        Site(pattern: #"PersonKeyItem\("#,
             sample: "PersonKeyItem(privateKey: a, publicKey: b, name: n)",
             expected: ["PersonKey.swift": 1]),
    ]

    // MARK: - The censuses

    func test_aPersonKeyStoreIsConstructedInPersonKeyAccessOnly() throws {
        try assertCensus(Self.storeConstruction, named: "storeConstruction")
    }

    func test_aPersonClaimIsVerifiedInRegistryReaderOnly() throws {
        try assertCensus(Self.claimVerification, named: "claimVerification")
    }

    func test_recognitionIsAskedByANamedSetOfCallers() throws {
        try assertCensus(Self.recognition, named: "recognition")
    }

    func test_aPersonKeyIsLinkedAndForgottenByANamedSetOfCallers() throws {
        try assertCensus(Self.linkAndForget, named: "linkAndForget")
    }

    func test_thePersonKeyIsFoundAndSignsInANamedSetOfPlaces() throws {
        try assertCensus(Self.personKeySigning, named: "personKeySigning")
    }

    // MARK: - The planted-offender controls

    func test_theStoreCensusFiresOnPlantedOffenders() throws {
        try assertFiresOnPlantedOffenders(Self.storeConstruction)
    }

    func test_theClaimVerificationCensusFiresOnPlantedOffenders() throws {
        try assertFiresOnPlantedOffenders(Self.claimVerification)
    }

    func test_theRecognitionCensusFiresOnPlantedOffenders() throws {
        try assertFiresOnPlantedOffenders(Self.recognition)
    }

    func test_theLinkAndForgetCensusFiresOnPlantedOffenders() throws {
        try assertFiresOnPlantedOffenders(Self.linkAndForget)
    }

    func test_thePersonKeySigningCensusFiresOnPlantedOffenders() throws {
        try assertFiresOnPlantedOffenders(Self.personKeySigning)
    }

    /// The sharpest case the brief names, planted by hand rather than
    /// generated: a second store construction under the allow-listed
    /// FILENAME, a raw claim read in a surface, and a verifier that rebuilds
    /// the signed content somewhere else. Each moves a count; the comments
    /// beside them move none.
    func test_theSharpestOffendersFireUnderAllowListedNames() throws {
        let dir = try plantedDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            // KeychainPersonKeyStore( in a comment is prose, not a door.
            enum PersonKeyAccess {
                static func store() -> any PersonKeyStore {
                    return KeychainPersonKeyStore(accessGroup: a)
                }
                static func another() -> any PersonKeyStore {
                    KeychainPersonKeyStore(accessGroup: b)  // the second door
                }
            }
            """.write(to: dir.appendingPathComponent("PersonKeyAccess.swift"),
                      atomically: true, encoding: .utf8)
        try """
            /// A raw `record.personClaim` named in a doc comment is fine.
            let who = record.personClaim?.name
            let ok = OpLogChain.credentialsVerify(asClaimed, over: digest)
            let content = claim.signedContent(forDevice: record.device)
            """.write(to: dir.appendingPathComponent("PeopleAndDevicesModel.swift"),
                      atomically: true, encoding: .utf8)

        let found = try Self.foldedCounts(
            of: Self.storeConstruction + Self.claimVerification, in: [dir]).counts
        XCTAssertEqual(found[#"KeychainPersonKeyStore\("#], ["PersonKeyAccess.swift": 2],
            "the allow-listed file's SECOND construction moves its count; the comment does not")
        XCTAssertEqual(found[#"(?<!maugham)\.personClaim\b(?!\s*\()"#],
                       ["PeopleAndDevicesModel.swift": 1])
        XCTAssertEqual(found[#"credentialsVerify\("#], ["PeopleAndDevicesModel.swift": 1])
        XCTAssertEqual(found[#"signedContent\(forDevice:"#], ["PeopleAndDevicesModel.swift": 1])
    }

    /// **The phone's allow-list is empty.** For every site in every census, a
    /// sample planted under a `MaughamPhone/` root is counted under its
    /// phone-qualified key and fails the census — including one wearing the
    /// NAME of a file the Mac is allowed (`PersonKeyAccess.swift` et al.),
    /// which must not be absorbed into the Mac's count.
    func test_everyCensusFiresOnAnOffenderPlantedUnderThePhone() throws {
        let all = Self.storeConstruction + Self.claimVerification + Self.recognition
            + Self.linkAndForget + Self.personKeySigning
        for site in all {
            let dir = try plantedDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let mac = dir.appendingPathComponent("Maugham", isDirectory: true)
            let phone = dir.appendingPathComponent(Self.phoneRootName, isDirectory: true)
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
            // The Mac side exactly as expected…
            for (key, count) in site.expected {
                try plant(Self.plantedBody(forKey: key, repeating: site.sample, count: count),
                          as: Self.plantedName(forKey: key), in: mac)
            }
            XCTAssertEqual(try Self.foldedCounts(of: [site], in: [mac, phone]).counts[site.pattern],
                           site.expected)
            // …then one phone offender under an allow-listed Mac file's name.
            // A site the phone alone is allowed (`PersonKey.find`) has no Mac
            // name to borrow; a second phone file under a new name must fail.
            // A type key lends its type's own file name, which the phone file
            // does not declare — and is not absorbed by even if it did.
            let borrowedKey = site.expected.keys.sorted()
                .first { !$0.hasPrefix(Self.phoneRootName + "/") }
            let borrowed = borrowedKey.map(Self.plantedName(forKey:)) ?? "PlantedOffender.swift"
            try site.sample.write(to: phone.appendingPathComponent(borrowed),
                                  atomically: true, encoding: .utf8)
            let found = try Self.foldedCounts(of: [site], in: [mac, phone]).counts[site.pattern]
            XCTAssertEqual(found?[Self.phoneRootName + "/" + borrowed], 1,
                "a phone `\(site.pattern)` is keyed under MaughamPhone/")
            if let borrowedKey {
                XCTAssertEqual(found?[borrowedKey], site.expected[borrowedKey],
                    "the phone file is not absorbed into the Mac's allowance")
            }
            XCTAssertNotEqual(found, site.expected,
                "a phone `\(site.pattern)` must fail the census — its allow-list is empty")
        }
    }

    // MARK: - Machinery

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The Mac, the shared substrate, and the phone (whose allow-list is empty
    /// — see the type's doc comment).
    private static var roots: [URL] {
        [repoRoot.appendingPathComponent("Maugham", isDirectory: true),
         repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true),
         repoRoot.appendingPathComponent(phoneRootName, isDirectory: true)]
    }

    /// A root with this last component is the phone's: its files are keyed
    /// `MaughamPhone/<file>`, never by the bare name a Mac entry uses.
    static let phoneRootName = "MaughamPhone"

    /// Occurrences of each site's pattern per file under `roots`, counted over
    /// comment-stripped code lines. Keyed by pattern; a pattern found nowhere
    /// maps to `[:]`.
    static func counts(of sites: [Site], in roots: [URL]) throws -> [String: [String: Int]] {
        let regexes = try sites.map { ($0.pattern, try NSRegularExpression(pattern: $0.pattern)) }
        var result: [String: [String: Int]] = [:]
        for (pattern, _) in regexes { result[pattern] = [:] }
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { continue }
            let rootIsPhone = root.lastPathComponent == phoneRootName
            let rootDepth = root.resolvingSymlinksInPath().pathComponents.count
            for case let url as URL in walker where url.pathExtension == "swift" {
                // Under the phone's root, or under a `MaughamPhone` folder
                // beneath a planted root (the controls' phone sites, plan 2).
                let between = url.resolvingSymlinksInPath().pathComponents
                    .dropLast().dropFirst(rootDepth)
                let isPhone = rootIsPhone || between.contains(phoneRootName)
                let key = (isPhone ? phoneRootName + "/" : "") + url.lastPathComponent
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = SourceScan.codeLines(of: text)
                for (pattern, regex) in regexes {
                    var n = 0
                    for line in lines {
                        n += regex.numberOfMatches(
                            in: line, range: NSRange(line.startIndex..., in: line))
                    }
                    if n > 0 { result[pattern]![key, default: 0] += n }
                }
            }
        }
        return result
    }

    /// `counts`, each site's map re-keyed the way its `expected` is: a Mac or
    /// Core file a `type:` key claims is counted under that key (the sum over
    /// the type's files). Types are resolved over the non-phone roots only, so
    /// a phone file is never claimed. `offenders` lists every type key that
    /// resolved to no file.
    static func foldedCounts(
        of sites: [Site], in roots: [URL]
    ) throws -> (counts: [String: [String: Int]], offenders: [String]) {
        let raw = try counts(of: sites, in: roots)
        let typeRoots = roots.filter { $0.lastPathComponent != phoneRootName }
        var folded: [String: [String: Int]] = [:]
        var offenders: [String] = []
        for site in sites {
            let (byKey, unresolved) = SourceTree.foldingIntoTypeKeys(
                raw[site.pattern] ?? [:], keyedLike: site.expected.keys,
                in: typeRoots, combine: +)
            folded[site.pattern] = byKey
            offenders += unresolved
        }
        return (folded, Array(Set(offenders)).sorted())
    }

    /// The file a planted control writes for an expected key: a `type:` key
    /// plants its type's own `<Type>.swift`.
    static func plantedName(forKey key: String) -> String {
        SourceTree.typeName(ofKey: key).map { "\($0).swift" } ?? key
    }

    /// `sample` × `count` (after `prefix`), declaring the key's type first when
    /// the key is a `type:` key — the census claims the file by its declaration.
    static func plantedBody(forKey key: String, prefix: [String] = [],
                            repeating sample: String, count: Int) -> String {
        let declaration = SourceTree.typeName(ofKey: key).map { ["extension \($0) {}"] } ?? []
        return (declaration + prefix + Array(repeating: sample, count: count))
            .joined(separator: "\n")
    }

    private func assertCensus(_ sites: [Site], named name: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let (found, unresolved) = try Self.foldedCounts(of: sites, in: Self.roots)
        XCTAssertTrue(unresolved.isEmpty, "`\(name)`: \(unresolved)", file: file, line: line)
        for site in sites {
            XCTAssertEqual(found[site.pattern], site.expected,
                "The production sites of `\(site.pattern)` moved. A site that "
                + "APPEARED is a second door onto the person key; one that "
                + "VANISHED is a door that moved. Update `\(name)` with the "
                + "reason in the same commit, or put it back. Found: "
                + "\((found[site.pattern] ?? [:]).sorted(by: { $0.key < $1.key }))",
                file: file, line: line)
        }
    }

    /// Write `text` at `name` under `dir` — a `MaughamPhone/<file>` key lands
    /// in a `MaughamPhone` folder, which `counts` keys back to the same name.
    @discardableResult
    private func plant(_ text: String, as name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func plantedDirectory() throws -> URL {
        let dir = TestTemp.root
            .appendingPathComponent("person-key-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Proves, for every site in `sites`, all three things the census relies on:
    ///
    /// 1. **A vanished site fires**: an empty tree matches no expectation.
    /// 2. **The counter is exact**: a tree reproducing every expected site —
    ///    `sample` written `count` times into a file of that NAME, plus the
    ///    same spelling in a comment — matches every expectation exactly.
    /// 3. **An appeared site fires, in both places it can appear**: one more
    ///    `sample` in an ALLOW-LISTED file (file-plus-count, not file alone),
    ///    and one in a file the site does not name.
    private func assertFiresOnPlantedOffenders(
        _ sites: [Site], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // 1. Vanished.
        let empty = try plantedDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        for site in sites {
            XCTAssertNotEqual(try Self.foldedCounts(of: [site], in: [empty]).counts[site.pattern],
                              site.expected,
                              "an empty tree must fail `\(site.pattern)`", file: file, line: line)
        }

        for site in sites {
            // 2. Exact.
            let dir = try plantedDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            for (key, count) in site.expected {
                try plant(Self.plantedBody(forKey: key, prefix: ["// \(site.sample) — prose only"],
                                           repeating: site.sample, count: count),
                          as: Self.plantedName(forKey: key), in: dir)
            }
            XCTAssertEqual(try Self.foldedCounts(of: [site], in: [dir]).counts[site.pattern],
                           site.expected,
                "the reproduced tree must satisfy `\(site.pattern)` exactly "
                + "(the sample does not match its own pattern, or a comment counted)",
                file: file, line: line)

            // 3a. Appeared under an allow-listed name.
            let allowed = try XCTUnwrap(site.expected.keys.sorted().first)
            let url = dir.appendingPathComponent(Self.plantedName(forKey: allowed))
            try (try String(contentsOf: url, encoding: .utf8) + "\n" + site.sample)
                .write(to: url, atomically: true, encoding: .utf8)
            var widened = site.expected
            widened[allowed, default: 0] += 1
            let inAllowed = try Self.foldedCounts(of: [site], in: [dir]).counts[site.pattern]
            XCTAssertEqual(inAllowed, widened, file: file, line: line)
            XCTAssertNotEqual(inAllowed, site.expected,
                "a second `\(site.pattern)` inside \(allowed) must fail the census",
                file: file, line: line)

            // 3b. Appeared in a file the site does not name (the allowed file
            // restored first, so this is the only difference).
            try Self.plantedBody(forKey: allowed, repeating: site.sample,
                                 count: site.expected[allowed]!)
                .write(to: url, atomically: true, encoding: .utf8)
            try site.sample.write(
                to: dir.appendingPathComponent("PlantedOffender.swift"),
                atomically: true, encoding: .utf8)
            let elsewhere = try Self.foldedCounts(of: [site], in: [dir]).counts[site.pattern]
            XCTAssertEqual(elsewhere?["PlantedOffender.swift"], 1,
                "a `\(site.pattern)` in an unnamed file must be counted", file: file, line: line)
            XCTAssertNotEqual(elsewhere, site.expected,
                "a `\(site.pattern)` in an unnamed file must fail the census",
                file: file, line: line)
        }
    }
}
