import AppKit
import ImageIO
import RegravaCore
import RegravaRender
import SwiftUI

/// Wallpaper picker (A8): Favourites (star) and the categories, "Pick random wallpaper", a
/// grid of thumbnails with favourites in the context menu and the author credit.
struct WallpaperPicker: View {
    @Binding var selection: String
    @State private var category: String
    @AppStorage("favouriteBackgrounds") private var favouritesData = Data()

    static let favourites = "favourites"

    init(selection: Binding<String>) {
        _selection = selection
        _category = State(initialValue: WallpaperLibrary.category(containing: selection.wrappedValue)?.name ?? WallpaperLibrary.categories.first?.name ?? "")
    }

    private var favouriteIDs: [String] {
        (try? JSONDecoder().decode([String].self, from: favouritesData)) ?? []
    }

    private func setFavourite(_ id: String, _ on: Bool) {
        var ids = favouriteIDs.filter { $0 != id }
        if on { ids.append(id) }
        favouritesData = (try? JSONEncoder().encode(ids)) ?? Data()
    }

    private var wallpapers: [WallpaperLibrary.Wallpaper] {
        if category == Self.favourites {
            let all = WallpaperLibrary.categories.flatMap(\.wallpapers)
            return favouriteIDs.compactMap { id in all.first { $0.id == id } }
        }
        return WallpaperLibrary.categories.first { $0.name == category }?.wallpapers ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(2)) {
            SegmentedPicker(
                options: [Self.favourites] + WallpaperLibrary.categories.map(\.name),
                label: { $0 == Self.favourites ? "" : $0 },
                icon: { $0 == Self.favourites ? "star" : nil },
                size: .small,
                selection: $category
            )
            RSButton(title: "Pick random wallpaper", icon: "wand.and.sparkles", kind: .secondary, isWide: true) {
                if let pick = WallpaperLibrary.categories.flatMap(\.wallpapers).randomElement() {
                    selection = pick.id
                }
            }
            if category == Self.favourites && wallpapers.isEmpty {
                Text("You have no favourite backgrounds yet. To add a background to your favourites, right-click on it and select \"Add to favourites\".")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperThumbnail(wallpaper: wallpaper, isSelected: wallpaper.id == selection, isFavourite: favouriteIDs.contains(wallpaper.id))
                            .onTapGesture { selection = wallpaper.id }
                            .contextMenu {
                                let isFavourite = favouriteIDs.contains(wallpaper.id)
                                Button { setFavourite(wallpaper.id, !isFavourite) } label: {
                                    Label(isFavourite ? "Remove from favourites" : "Add to favourites", systemImage: isFavourite ? "star.slash" : "star")
                                }
                            }
                            .help(wallpaper.name)
                    }
                }
            }
            if let author = WallpaperLibrary.categories.first(where: { $0.name == category })?.author {
                HStack(spacing: 3) {
                    Text("Those beautiful images were created by")
                    Link(author.name, destination: author.url)
                }
                .font(Theme.Typo.label)
                .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            }
        }
    }
}

private struct WallpaperThumbnail: View {
    var wallpaper: WallpaperLibrary.Wallpaper
    var isSelected: Bool
    var isFavourite: Bool
    @State private var image: NSImage?

    var body: some View {
        PickerTile(isSelected: isSelected) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Theme.Colors.lighterBg
            }
        }
        .overlay {
            // Favourite star: centred, with a text shadow.
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .opacity(isFavourite ? 1 : 0)
                .animation(.easeInOut(duration: 0.125), value: isFavourite)
                .allowsHitTesting(false)
        }
        .task(id: wallpaper.id) { image = await WallpaperThumbnails.shared.thumbnail(for: wallpaper.id) }
    }
}

/// Picker tile shared by wallpapers and gradients: 32×32, radius 6, an inner 1 px #fff8
/// overlay border, and a 1 px outline offset by 1 px, white at 40% on hover and white when selected.
struct PickerTile<Content: View>: View {
    var isSelected: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        Color.clear
            .frame(width: 32, height: 32)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0x88 / 255), lineWidth: 1).blendMode(.overlay))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.white : hovered ? Color.white.opacity(0.4) : .clear, lineWidth: 1)
                    .padding(-2)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Small thumbnails, made once per wallpaper.
actor WallpaperThumbnails {
    static let shared = WallpaperThumbnails()
    private var cache: [String: NSImage] = [:]

    func thumbnail(for id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let url = WallpaperLibrary.url(for: id),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache[id] = thumbnail
        return thumbnail
    }
}
