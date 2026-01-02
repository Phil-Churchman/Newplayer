package com.example.newplayer.data

import android.content.Context
import android.provider.MediaStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

class LocalSongRepository(
    private val context: Context,
    private val songDao: SongDao,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao,
    private val localQueueDao: LocalQueueDao
) {

    val allSongs: Flow<List<Song>> = songDao.getAll()
    val allArtists: Flow<List<Artist>> = artistDao.getAll()
    val allAlbums: Flow<List<Album>> = albumDao.getAll()

    // Queue Functions
    val queue: Flow<List<LocalQueue>> = localQueueDao.getQueue()

    suspend fun addToQueue(songId: Long) {
        val currentQueue = queue.first()
        val nextPosition = if (currentQueue.isEmpty()) 0 else currentQueue.maxOf { it.position } + 1
        localQueueDao.addToQueue(LocalQueue(songId = songId, position = nextPosition))
    }

    suspend fun removeFromQueue(songId: Long) {
        localQueueDao.removeFromQueue(songId)
    }

    suspend fun clearQueue() {
        localQueueDao.clearQueue()
    }

    suspend fun setCurrent(songId: Long) {
        localQueueDao.setCurrent(songId)
    }

    fun getCurrentSongInQueue(): Flow<LocalQueue?> {
        return localQueueDao.getCurrentSong()
    }

    fun getArtistNameById(artistId: Long): Flow<String?> {
        return artistDao.getArtistNameById(artistId)
    }

    fun getAlbumsByArtistId(artistId: Long): Flow<List<Album>> {
        return albumDao.getAlbumsByArtistId(artistId)
    }

    fun getAlbumById(albumId: Long): Flow<Album?> {
        return albumDao.getAlbumById(albumId)
    }

    fun getSongsByAlbumId(albumId: Long): Flow<List<Song>> {
        return songDao.getSongsByAlbumId(albumId)
    }

    private fun normalizeText(text: String?): String {
        if (text.isNullOrBlank()) return ""
        return text
            .replace("â€™", "'")
            .replace("â€œ", "\"")
            .replace("â€", "\"")
            .replace("â€“", "-")
            .replace("â€¦", "...")
            .replace("Ã¨", "è")
            .replace("’", "'")
            .replace("‘", "'")
            .replace("“", "\"")
            .replace("”", "\"")
            .replace("–", "-")
            .replace("…", "...")
            .trim()
    }
    suspend fun scanForSongs() {
        songDao.deleteAll()
        artistDao.deleteAll()
        albumDao.deleteAll()

        data class RawSongInfo(
            val title: String,
            val artist: String,
            val album: String,
            val albumArtist: String,
            val path: String,
            val duration: Long,
            val track: Int
        )

        val rawSongs = mutableListOf<RawSongInfo>()

        val projection = arrayOf(
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ARTIST,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK
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
            val trackColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TRACK)

            while (cursor.moveToNext()) {
                val songTitle = normalizeText(cursor.getString(titleColumn))
                val songArtist = normalizeText(cursor.getString(artistColumn))
                val songAlbum = normalizeText(cursor.getString(albumColumn))
                val songAlbumArtistRaw = if (albumArtistColumn != -1) cursor.getString(albumArtistColumn) else null
                val effectiveAlbumArtist = if (songAlbumArtistRaw.isNullOrBlank() || songAlbumArtistRaw == "<unknown>") songArtist else normalizeText(songAlbumArtistRaw)
                val trackNumberRaw = cursor.getString(trackColumn)
                val trackNumber = trackNumberRaw?.split('/')?.get(0)?.toIntOrNull() ?: 0


                if (songTitle.isNotBlank() && songAlbum.isNotBlank()) {
                    rawSongs.add(
                        RawSongInfo(
                            title = songTitle,
                            artist = songArtist,
                            album = songAlbum,
                            albumArtist = effectiveAlbumArtist,
                            path = cursor.getString(pathColumn),
                            duration = cursor.getLong(durationColumn),
                            track = trackNumber
                        )
                    )
                }
            }
        }

        if (rawSongs.isNotEmpty()) {
            val uniqueArtistNames = rawSongs.map { it.albumArtist }.filter { it.isNotBlank() }.distinct()
            val artistsToInsert = uniqueArtistNames.map { Artist(name = it) }
            artistDao.insertAll(artistsToInsert)
            val artistIdMap = artistDao.getAll().first().associate { it.name to it.id }

            val albumsToInsert = rawSongs
                .groupBy { it.album } 
                .mapNotNull { (albumName, songsInAlbum) ->
                    val firstSong = songsInAlbum.first()
                    val artistId = artistIdMap[firstSong.albumArtist]
                    if (artistId != null) {
                        Album(name = albumName, artistId = artistId)
                    } else {
                        null
                    }
                }
            albumDao.insertAll(albumsToInsert)
            val albumIdMap = albumDao.getAll().first().associate { it.name to it.id }

            val songsToInsert = rawSongs.mapNotNull { rawSong ->
                val albumId = albumIdMap[rawSong.album]
                if (albumId != null) {
                    Song(
                        title = rawSong.title,
                        artist = rawSong.artist,
                        album = rawSong.album,
                        path = rawSong.path,
                        duration = rawSong.duration,
                        albumArtist = rawSong.albumArtist,
                        albumId = albumId,
                        track = rawSong.track
                    )
                } else {
                    null
                }
            }
            songDao.insertAll(songsToInsert)
        }
    }
}
