import SwiftUI

struct ArtworkImageView: View {
    let data: Data?
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let data, let uiImage = UIImage(data: data) {
                // `Color.clear` takes exactly the size offered, and the cover is drawn over it
                // and cropped to that box by the clip shape below.
                //
                // Sizing the image itself with `.aspectRatio(contentMode: .fill)` is what broke:
                // `.fill` reports a size *larger* than the offer in one axis for any cover that
                // isn't square, and a clip shape trims the drawing but not the layout. So a
                // cover wider than it was tall reported an oversized width, and the Now Playing
                // column — which sizes to its widest child — grew with it, dragging the track bar
                // and the source indicator out past the edge of the screen.
                Color.clear
                    .overlay {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
