package com.example.newplayer.data

import android.content.Context
import android.provider.MediaStore
import kotlinx.coroutines.flow.Flow

class LocalSongRepository(
    private val context: Context,
    private val songDao: SongDao,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao
) {

    val allSongs: Flow<List<Song>> = songDao.getAll()
    val allArtists: Flow<List<Artist>> = artistDao.getAll()
    val allAlbums: Flow<List<Album>> = albumDao.getAll()

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

        val songs = mutableListOf<Song>()
        val albumArtists = mutableSetOf<String>()

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
                val songArtist = cursor.getString(artistColumn)
                val song = Song(
                    title = cursor.getString(titleColumn),
                    artist = songArtist,
                    album = cursor.getString(albumColumn),
                    path = cursor.getString(pathColumn),
                    duration = cursor.getLong(durationColumn)
                )
                songs.add(song)

                val albumArtist = if (albumArtistColumn != -1) cursor.getString(albumArtistColumn) else null
                val artistNameToStore = if (albumArtist.isNullOrBlank() || albumArtist == "<unknown>") {
                    songArtist
                } else {
                    albumArtist
                }

                if (!artistNameToStore.isNullOrBlank()) {
                    albumArtists.add(artistNameToStore)
                }
            }
        }

        if (songs.isNotEmpty()) {
            songDao.insertAll(songs)

            val artistsToInsert = albumArtists.map { Artist(name = it) }
            artistDao.insertAll(artistsToInsert)

            val albumsToInsert = songs.map { Album(name = it.album) }.distinctBy { it.name }
            albumDao.insertAll(albumsToInsert)
        }
    }
}
