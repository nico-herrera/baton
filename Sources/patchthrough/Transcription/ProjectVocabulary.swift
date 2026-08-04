import Foundation

enum ProjectVocabulary {
    private static let maximumTerms = 256
    private static let manifests = [
        "package.json", "Package.swift", "Cargo.toml", "pyproject.toml",
        "requirements.txt", "go.mod", "Gemfile", "Podfile",
    ]
    private static let ignored = Set([".git", ".build", "build", "dist", "node_modules", "vendor", "Pods"])
    private static let common = Set([
        "class", "const", "dependencies", "dependency", "description", "development",
        "function", "import", "interface", "package", "private", "project", "public",
        "return", "string", "struct", "target", "version",
    ])

    static func collect(projectRoot: URL?) -> [VocabularyTerm] {
        var terms: [String: VocabularyTerm] = [:]
        func add(_ text: String, source: String, weight: Double) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard terms.count < maximumTerms,
                  cleaned.count >= 3, cleaned.count <= 64,
                  cleaned.rangeOfCharacter(from: .letters) != nil,
                  !common.contains(cleaned.lowercased()) else { return }
            let key = cleaned.lowercased()
            if terms[key] == nil || terms[key]!.weight < weight {
                terms[key] = VocabularyTerm(text: cleaned, source: source, weight: weight)
            }
        }

        let personal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/patchthrough/vocabulary.txt")
        for line in lines(at: personal) { add(line, source: "personal_glossary", weight: 2) }

        guard let root = projectRoot, FileManager.default.fileExists(atPath: root.path) else {
            return Array(terms.values).sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
        }
        for line in lines(at: root.appendingPathComponent(".patchthrough/vocabulary.txt")) {
            add(line, source: "project_glossary", weight: 2)
        }
        let jsonGlossary = root.appendingPathComponent(".patchthrough/vocabulary.json")
        if let data = try? Data(contentsOf: jsonGlossary),
           let object = try? JSONSerialization.jsonObject(with: data) {
            let values = object as? [String] ?? (object as? [String: Any])?["terms"] as? [String] ?? []
            for value in values { add(value, source: "project_glossary", weight: 2) }
        }

        for manifest in manifests {
            let url = root.appendingPathComponent(manifest)
            guard let data = try? Data(contentsOf: url), data.count <= 512_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            for candidate in identifiers(in: text) where isSpecialized(candidate) {
                add(candidate, source: "manifest", weight: 1.4)
            }
        }

        let head = root.appendingPathComponent(".git/HEAD")
        if let value = try? String(contentsOf: head, encoding: .utf8),
           let branch = value.split(separator: "/").last {
            for part in branch.split(whereSeparator: { "-_".contains($0) }) {
                add(String(part), source: "branch", weight: 0.8)
            }
        }

        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var files = 0
            for case let file as URL in enumerator {
                if ignored.contains(file.lastPathComponent) { enumerator.skipDescendants(); continue }
                let depth = file.pathComponents.count - root.pathComponents.count
                if depth > 3 { enumerator.skipDescendants(); continue }
                guard (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
                files += 1
                if files > 400 { break }
                let stem = file.deletingPathExtension().lastPathComponent
                if isSpecialized(stem) { add(stem, source: "filename", weight: 0.8) }
                guard ["swift", "cs", "ts", "tsx", "js", "jsx", "rs", "go", "py"].contains(file.pathExtension),
                      let data = try? Data(contentsOf: file), data.count <= 128_000,
                      let source = String(data: data, encoding: .utf8) else { continue }
                for declaration in declarations(in: source) {
                    add(declaration, source: "declaration", weight: 1)
                }
            }
        }
        return Array(terms.values)
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.text < $1.text }
            .prefix(maximumTerms).map { $0 }
    }

    private static func lines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    private static func identifiers(in text: String) -> [String] {
        matches(#"[A-Za-z][A-Za-z0-9_.+\-]{2,63}"#, in: text)
    }

    private static func declarations(in text: String) -> [String] {
        matches(#"(?:class|struct|enum|protocol|interface|record|func|function)\s+([A-Za-z][A-Za-z0-9_]{2,63})"#, in: text, group: 1)
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    private static func isSpecialized(_ term: String) -> Bool {
        term.contains(where: \.isUppercase)
            || term.contains("-") || term.contains("_") || term.contains(".")
    }
}
