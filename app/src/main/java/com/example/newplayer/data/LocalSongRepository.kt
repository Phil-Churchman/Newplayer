package com.example.newplayer.data

import android.content.Context
import android.provider.MediaStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

class LocalSongRepository(
    private val context: Context,
    private val songDao: SongDao,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao
) {

    val allSongs: Flow<List<Song>> = songDao.getAll()
    val allArtists: Flow<List<Artist>> = artistDao.getAll()
    val allAlbums: Flow<List<Album>> = albumDao.getAll()

    fun getArtistNameById(artistId: Long): Flow<String?> {
        return artistDao.getArtistNameById(artistId)
    }

    fun getAlbumsByArtistId(artistId: Long): Flow<List<Album>> {
        return albumDao.getAlbumsByArtistId(artistId)
    }

    private fun normalizeText(text: String?): String {
        if (text.isNullOrBlank()) return ""
        return text
            // Fix mis-encoded characters
            .replace("â€™", "'")
            .replace("â€œ", "\"")
            .replace("â€", "\"")
            .replace("â€“", "-")
            .replace("â€¦", "...")
            .replace("Ã¨", "è")
            // Normalize typographic quotes
            .replace("’", "'")
            .replace("‘", "'")
            .replace("“", "\"")
            .replace("”", "\"")
            .replace("–", "-")
            .replace("…", "...")
            .trim() // Remove leading/trailing spaces
    }
    suspend fun scanForSongs() {
        // Clear existing data first
        songDao.deleteAll()
        artistDao.deleteAll()
        albumDao.deleteAll()

        // Use a temporary data class to hold all raw info from MediaStore
        data class RawSongInfo(
            val title: String,
            val artist: String,
            val album: String,
            val albumArtist: String,
            val path: String,
            val duration: Long
        )

        val rawSongs = mutableListOf<RawSongInfo>()

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ARTIST,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"

        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            null,
            null
        )?.use { cursor ->
            val titleColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumArtistColumn = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ARTIST)
            val pathColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)

            while (cursor.moveToNext()) {
                val songTitle = normalizeText(cursor.getString(titleColumn))
                val songArtist = normalizeText(cursor.getString(artistColumn))
                val songAlbum = normalizeText(cursor.getString(albumColumn))
                val songAlbumArtistRaw = if (albumArtistColumn != -1) cursor.getString(albumArtistColumn) else null

                // Determine the correct artist to use for the 'artists' table
                val effectiveAlbumArtist = if (songAlbumArtistRaw.isNullOrBlank() || songAlbumArtistRaw == "<unknown>") {
                    songArtist
                } else {
                    normalizeText(songAlbumArtistRaw)
                }

                if(songTitle.isNotBlank() && songAlbum.isNotBlank()) {
                    rawSongs.add(
                        RawSongInfo(
                            title = songTitle,
                            artist = songArtist,
                            album = songAlbum,
                            albumArtist = effectiveAlbumArtist, // This is the one we'll use for linking
                            path = cursor.getString(pathColumn),
                            duration = cursor.getLong(durationColumn)
                        )
                    )
                }
            }
        }

        if (rawSongs.isNotEmpty()) {
            // 1. Save all unique artists from the scanned songs
            val uniqueArtistNames = rawSongs.map { it.albumArtist }.filter { it.isNotBlank() }.distinct()
            val artistsToInsert = uniqueArtistNames.map { Artist(name = it) }
            artistDao.insertAll(artistsToInsert)

            // 2. Create a map of artist names to their newly generated IDs
            val artistIdMap = artistDao.getAll().first().associate { it.name to it.id }

            // 3. Save the songs
            val songsToInsert = rawSongs.map {
                Song(
                    title = it.title,
                    artist = it.artist,
                    album = it.album,
                    path = it.path,
                    duration = it.duration
                )
            }
            songDao.insertAll(songsToInsert)

            // 4. Save all albums with the correct artistId
            val albumsToInsert = rawSongs
                .groupBy { it.album } // Group by album name
                .mapNotNull { (albumName, songsInAlbum) ->
                    // For each album, find the artist ID using the effective album artist
                    val firstSong = songsInAlbum.first()
                    val artistId = artistIdMap[firstSong.albumArtist] // Look up the ID from the map

                    if (artistId != null) {
                        Album(name = albumName, artistId = artistId)
                    } else {
                        null // Should not happen if logic is correct
                    }
                }

            albumDao.insertAll(albumsToInsert)
        }
    }
}
