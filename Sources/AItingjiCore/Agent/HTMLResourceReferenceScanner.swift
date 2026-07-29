import Foundation

public struct HTMLResourceReference: Equatable, Sendable {
    public enum Attribute: String, Equatable, Sendable {
        case src
        case srcset
    }

    public var tagName: String
    public var attribute: Attribute
    public var value: String

    public init(tagName: String, attribute: Attribute, value: String) {
        self.tagName = tagName
        self.attribute = attribute
        self.value = value
    }
}

public enum HTMLResourceReferenceScannerError: Error, Equatable, Sendable {
    case malformedAttribute
    case forbiddenTag(String)
    case forbiddenAttribute(String)
    case forbiddenCSSResource
    case unsafeLink(String)
}

public struct HTMLResourceReferenceScanner: Sendable {
    public init() {}

    public func scan(_ html: String) throws -> [HTMLResourceReference] {
        let forbiddenTags: Set<String> = [
            "base", "script", "iframe", "object", "embed", "form", "link", "svg",
            "video", "audio", "track", "plaintext", "xmp", "template", "noscript"
        ]
        var references: [HTMLResourceReference] = []
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<" else {
                index = html.index(after: index)
                continue
            }
            if html[index...].hasPrefix("<!--") {
                guard let end = html[index...].range(of: "-->") else {
                    throw HTMLResourceReferenceScannerError.malformedAttribute
                }
                index = end.upperBound
                continue
            }

            var cursor = html.index(after: index)
            skipWhitespace(in: html, index: &cursor)
            if cursor == html.endIndex { break }
            if html[cursor] == "!" || html[cursor] == "?" || html[cursor] == "/" {
                index = skipTag(in: html, from: cursor)
                continue
            }

            let tagName = readName(in: html, index: &cursor).lowercased()
            guard !tagName.isEmpty else {
                index = html.index(after: index)
                continue
            }
            if forbiddenTags.contains(tagName) {
                throw HTMLResourceReferenceScannerError.forbiddenTag(tagName)
            }

            var attributes: [(String, String)] = []
            while cursor < html.endIndex {
                skipWhitespace(in: html, index: &cursor)
                guard cursor < html.endIndex else { break }
                if html[cursor] == ">" {
                    cursor = html.index(after: cursor)
                    break
                }
                if html[cursor] == "/" {
                    cursor = html.index(after: cursor)
                    continue
                }
                let name = readName(in: html, index: &cursor).lowercased()
                guard !name.isEmpty else {
                    cursor = html.index(after: cursor)
                    continue
                }
                skipWhitespace(in: html, index: &cursor)
                guard cursor < html.endIndex, html[cursor] == "=" else {
                    continue
                }
                cursor = html.index(after: cursor)
                skipWhitespace(in: html, index: &cursor)
                let value = try readAttributeValue(in: html, index: &cursor)
                attributes.append((name, decodeHTMLEntities(value)))
            }

            for (name, value) in attributes {
                if name.hasPrefix("on") {
                    throw HTMLResourceReferenceScannerError.forbiddenAttribute(name)
                }
                if name == "ping" {
                    throw HTMLResourceReferenceScannerError.forbiddenAttribute(name)
                }
                if name == "style", containsCSSResource(value) {
                    throw HTMLResourceReferenceScannerError.forbiddenCSSResource
                }
                if tagName == "meta",
                   name == "http-equiv",
                   value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh"
                {
                    throw HTMLResourceReferenceScannerError.forbiddenAttribute("http-equiv=refresh")
                }
                if tagName == "a", name == "href" {
                    try validateLink(value)
                }
                let isMediaAttribute = name == "src" || name == "srcset"
                    || name == "poster" || name == "data" || name == "background"
                    || name == "xlink:href" || (name == "href" && tagName != "a")
                if isMediaAttribute, tagName != "img", tagName != "source" {
                    throw HTMLResourceReferenceScannerError.forbiddenAttribute("\(tagName).\(name)")
                }
            }

            if tagName == "img" || tagName == "source" {
                for (name, value) in attributes {
                    if name == "src" {
                        references.append(HTMLResourceReference(tagName: tagName, attribute: .src, value: value))
                    } else if name == "srcset" {
                        references.append(contentsOf: parseSrcset(value).map {
                            HTMLResourceReference(tagName: tagName, attribute: .srcset, value: $0)
                        })
                    }
                }
            }

            index = cursor
            if tagName == "style" {
                guard let range = html[index...].range(of: "</style", options: [.caseInsensitive]) else {
                    throw HTMLResourceReferenceScannerError.malformedAttribute
                }
                if containsCSSResource(String(html[index..<range.lowerBound])) {
                    throw HTMLResourceReferenceScannerError.forbiddenCSSResource
                }
                index = range.lowerBound
            }
        }
        return references
    }

    private func readName(in html: String, index: inout String.Index) -> String {
        let start = index
        while index < html.endIndex {
            let scalar = html[index].unicodeScalars.first!
            if CharacterSet.alphanumerics.contains(scalar) || html[index] == "-" || html[index] == "_" || html[index] == ":" {
                index = html.index(after: index)
            } else {
                break
            }
        }
        return String(html[start..<index])
    }

    private func readAttributeValue(in html: String, index: inout String.Index) throws -> String {
        guard index < html.endIndex else {
            throw HTMLResourceReferenceScannerError.malformedAttribute
        }
        if html[index] == "\"" || html[index] == "'" {
            let quote = html[index]
            index = html.index(after: index)
            let start = index
            guard let end = html[index...].firstIndex(of: quote) else {
                throw HTMLResourceReferenceScannerError.malformedAttribute
            }
            index = html.index(after: end)
            return String(html[start..<end])
        }
        let start = index
        while index < html.endIndex,
              !html[index].isWhitespace,
              html[index] != ">"
        {
            index = html.index(after: index)
        }
        return String(html[start..<index])
    }

    private func parseSrcset(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false).compactMap { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init)
        }
    }

    private func containsCSSResource(_ value: String) -> Bool {
        let compact = normalizedCSS(value).lowercased().filter { !$0.isWhitespace }
        return compact.contains("url(")
            || compact.contains("@import")
            || compact.contains("image-set(")
            || compact.contains("@font-face")
    }

    private func normalizedCSS(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index...].hasPrefix("/*") {
                guard let end = value[index...].range(of: "*/") else { return output }
                index = end.upperBound
                continue
            }
            guard value[index] == "\\" else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            index = value.index(after: index)
            guard index < value.endIndex else { break }
            var digits = ""
            while index < value.endIndex, digits.count < 6, value[index].isHexDigit {
                digits.append(value[index])
                index = value.index(after: index)
            }
            if !digits.isEmpty, let scalarValue = UInt32(digits, radix: 16), let scalar = UnicodeScalar(scalarValue) {
                output.unicodeScalars.append(scalar)
                if index < value.endIndex, value[index].isWhitespace {
                    index = value.index(after: index)
                }
            } else if index < value.endIndex {
                output.append(value[index])
                index = value.index(after: index)
            }
        }
        return output
    }

    private func validateLink(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            throw HTMLResourceReferenceScannerError.unsafeLink(value)
        }
    }

    private func skipWhitespace(in html: String, index: inout String.Index) {
        while index < html.endIndex, html[index].isWhitespace {
            index = html.index(after: index)
        }
    }

    private func skipTag(in html: String, from index: String.Index) -> String.Index {
        guard let end = html[index...].firstIndex(of: ">") else { return html.endIndex }
        return html.index(after: end)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&", let semicolon = value[index...].firstIndex(of: ";") else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            let entityStart = value.index(after: index)
            let entity = String(value[entityStart..<semicolon])
            let replacement: Character?
            switch entity.lowercased() {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "colon": replacement = ":"
            default:
                let radix = entity.lowercased().hasPrefix("#x") ? 16 : 10
                let digits = entity.hasPrefix("#") ? String(entity.dropFirst(radix == 16 ? 2 : 1)) : ""
                replacement = UInt32(digits, radix: radix).flatMap(UnicodeScalar.init).map(Character.init)
            }
            if let replacement {
                output.append(replacement)
                index = value.index(after: semicolon)
            } else {
                output.append(value[index])
                index = value.index(after: index)
            }
        }
        return output
    }
}
