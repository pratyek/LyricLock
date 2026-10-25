import AppKit
import SwiftUI

/// Saves a lyric as a 1080×1350 image card (album art backdrop, the line, song credits),
/// copies it to the clipboard and shows it in Finder. Ready for Instagram or WhatsApp.
@MainActor
enum ShareCard {
    static func save(line: String, title: String, artist: String, artwork: NSImage?,
                     palette: Palette, font: LyricFont) {
        let card = CardView(line: line, title: title, artist: artist, artwork: artwork,
                            palette: palette, font: font)
            .frame(width: 1080, height: 1350)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { NSSound.beep(); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { NSSound.beep(); return }

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/LyricLock")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
        let stamp = Int(Date().timeIntervalSince1970)
        let url = folder.appendingPathComponent("\(safe.prefix(40)) \(stamp).png")
        do { try png.write(to: url) } catch { NSSound.beep(); return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct CardView: View {
    let line: String
    let title: String
    let artist: String
    let artwork: NSImage?
    let palette: Palette
    let font: LyricFont

    var body: some View {
        ZStack {
            Color.black
            if let art = artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 1080, height: 1350)
                    .scaleEffect(1.4)
                    .blur(radius: 70)
                    .saturation(1.2)
                    .opacity(0.9)
            }
            LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 0) {
                Spacer()
                Text("“")
                    .font(.system(size: 160, weight: .black, design: .serif))
                    .foregroundStyle(palette.primary.opacity(0.85))
                    .frame(height: 110)
                Text(line)
                    .font(font.font(size: 74))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .minimumScaleFactor(0.5)
                    .shadow(color: palette.primary.opacity(0.5), radius: 24)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .padding(.horizontal, 90)
                Spacer()
                HStack(spacing: 22) {
                    if let art = artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text(artist).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.65))
                    }
                    .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 90)
                .padding(.bottom, 90)
            }
        }
        .frame(width: 1080, height: 1350)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}
