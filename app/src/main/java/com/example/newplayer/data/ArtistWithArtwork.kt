package com.example.newplayer.data

data class ArtistWithArtwork(
    val artistId: Long,
    val artistName: String,
    val artwork: ByteArray?
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as ArtistWithArtwork

        if (artistId != other.artistId) return false
        if (artistName != other.artistName) return false
        if (artwork != null) {
            if (other.artwork == null) return false
            if (!artwork.contentEquals(other.artwork)) return false
        } else if (other.artwork != null) return false

        return true
    }

    override fun hashCode(): Int {
        var result = artistId.hashCode()
        result = 31 * result + artistName.hashCode()
        result = 31 * result + (artwork?.contentHashCode() ?: 0)
        return result
    }
}
