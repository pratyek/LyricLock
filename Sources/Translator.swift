import Foundation
import NaturalLanguage
import Translation

/// English translations using Apple's on-device translator (macOS 26+). Nothing leaves the Mac.
enum LyricTranslator {
    enum Outcome {
        case translated([String?])
        case alreadyEnglish
        case needsDownload(String)
        case unavailable(String)
    }

    static func translate(_ texts: [String]) async -> Outcome {
        let sample = texts.joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let detected = recognizer.dominantLanguage else {
            return .unavailable("couldn't tell the song's language")
        }
        if detected == .english { return .alreadyEnglish }
        let name = Locale.current.localizedString(forLanguageCode: detected.rawValue) ?? detected.rawValue

        guard #available(macOS 26.0, *) else {
            return .unavailable("needs macOS 26 or later")
        }
        let source = Locale.Language(identifier: detected.rawValue)
        let target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: break
        case .supported: return .needsDownload(name)
        default: return .unavailable("Apple's translator doesn't support \(name) yet")
        }

        let session = TranslationSession(installedSource: source, target: target)
        let requests = texts.enumerated().compactMap { i, text -> TranslationSession.Request? in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "♪" else { return nil }
            return TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
        }
        do {
            let responses = try await session.translations(from: requests)
            var out = [String?](repeating: nil, count: texts.count)
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < out.count,
                   r.targetText.lowercased() != texts[i].lowercased() {
                    out[i] = r.targetText
                }
            }
            return .translated(out)
        } catch {
            return .unavailable("translation failed (\(error.localizedDescription))")
        }
    }
}
