import SwiftUI

/// Shared layout numbers, so the screens that sit on top of each other line up.
enum LayoutMetrics {
    /// The horizontal inset for the app's own chrome and for the player.
    ///
    /// One value rather than one per view: the player had its artwork and track bar at 32 while
    /// the mini player and source bar directly beneath them sat at 12 and the title at none at
    /// all, so four elements of the same screen started at four different left edges. Matching
    /// the 16pt iOS content margin also lines the bars up with the list rows they sit under.
    static let horizontalPadding: CGFloat = 16

    /// Gap between a control and the info button explaining it.
    ///
    /// Explicit because `HStack`'s default spacing put the icon hard against the trailing edge of
    /// a switch — most visible on an iPad, where the row is wide and the two were the only
    /// things in it.
    static let infoButtonSpacing: CGFloat = 16

    /// Caps the player's width on an iPad. Left to fill, a square of artwork and a full-width
    /// slider stop reading as a player and start reading as a poster.
    static let maxPlayerWidth: CGFloat = 480
}
