package com.example.newplayer.data

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import java.io.ByteArrayOutputStream

class LocalSongRepository(
    private val context: Context,
    private val songDao: SongDao,
    private val artistDao: ArtistDao,
    private val albumDao: AlbumDao,
    private val profileDao: ProfileDao
) {

    val allSongs: Flow<List<Song>> = songDao.getAll()
    val allArtists: Flow<List<Artist>> = artistDao.getAll()
    val allAlbums: Flow<List<Album>> = albumDao.getAll()
    val artistsWithArtwork: Flow<List<ArtistWithArtwork>> = albumDao.getArtistsWithArtwork()

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
            .replace("â€œ", "\" ")
            .replace("â€", "\" ")
            .replace("â€“", "-")
            .replace("â€¦", "...")
            .replace("Ã¨", "è")
            .replace("’", "'")
            .replace("‘", "'")
            .replace("“", "\" ")
            .replace("”", "\" ")
            .replace("–", "-")
            .replace("…", "...")
            .trim()
    }

    private fun getAndResizeArtwork(albumId: Long): ByteArray? {
        try {
            val artworkUri = ContentUris.withAppendedId(Uri.parse("content://media/external/audio/albumart"), albumId)
            context.contentResolver.openInputStream(artworkUri)?.use { inputStream ->
                val originalBitmap = BitmapFactory.decodeStream(inputStream)
                if (originalBitmap == null) return null

                val maxHeight = 512
                val maxWidth = 512

                if (originalBitmap.height <= maxHeight && originalBitmap.width <= maxWidth) {
                    val baos = ByteArrayOutputStream()
                    originalBitmap.compress(Bitmap.CompressFormat.JPEG, 85, baos)
                    return baos.toByteArray()
                }

                val ratio: Float = originalBitmap.width.toFloat() / originalBitmap.height.toFloat()
                val newWidth: Int
                val newHeight: Int
                if (originalBitmap.width > originalBitmap.height) {
                    newWidth = maxWidth
                    newHeight = (maxWidth / ratio).toInt()
                } else {
                    newWidth = (maxHeight * ratio).toInt()
                    newHeight = maxHeight
                }

                val scaledBitmap = Bitmap.createScaledBitmap(originalBitmap, newWidth, newHeight, true)
                val baos = ByteArrayOutputStream()
                scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 85, baos)
                return baos.toByteArray()
            }
        } catch (e: Exception) {
            // Could be FileNotFoundException or other issues
            return null
        }
        return null
    }


    suspend fun scanForSongs(): List<MediaItem> {
        val localProfileId = profileDao.getLocalProfileId() ?: return emptyList()

        songDao.deleteByProfileId(localProfileId)
        artistDao.deleteByProfileId(localProfileId)
        albumDao.deleteByProfileId(localProfileId)

        data class RawSongInfo(
            val title: String,
            val artist: String,
            val album: String,
            val albumArtist: String,
            val path: String,
            val duration: Long,
            val track: Int,
            val albumIdFromMediaStore: Long
        )

        val rawSongs = mutableListOf<RawSongInfo>()

        val projection = arrayOf(
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ARTIST,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.ALBUM_ID
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
            val albumIdColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)

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
                            track = trackNumber,
                            albumIdFromMediaStore = cursor.getLong(albumIdColumn)
                        )
                    )
                }
            }
        }

        if (rawSongs.isNotEmpty()) {
            val uniqueArtistNames = rawSongs.map { it.albumArtist }.filter { it.isNotBlank() }.distinct()
            val artistsToInsert = uniqueArtistNames.map { Artist(name = it, profileId = localProfileId) }
            artistDao.insertAll(artistsToInsert)
            val artistIdMap = artistDao.getAll().first().associate { it.name to it.id }

            val albumsToInsert = rawSongs
                // 1. Correctly group by a Pair of album and albumArtist
                .groupBy { Pair(it.album, it.albumArtist) }
                .mapValues { (_, songsInAlbum) -> songsInAlbum.first() }
                .mapNotNull { (key, firstSong) ->
                    // 2. Destructure the key and get the artistId
                    val (albumName, albumArtist) = key
                    val artistId = artistIdMap[albumArtist]

                    if (artistId != null) {
                        val artwork = getAndResizeArtwork(firstSong.albumIdFromMediaStore)
                        Album(name = albumName, artistId = artistId, artwork = artwork, profileId = localProfileId)
                    } else {
                        null
                    }
                }
            albumDao.insertAll(albumsToInsert)
            // You were also missing .first() here in your provided snippet
            val albumIdMap = albumDao.getAll().first().associate { Pair(it.name, it.artistId) to it.id }

            val songsToInsert = rawSongs.mapNotNull { rawSong ->
                // Adjust the lookup to use the composite key
                val artistId = artistIdMap[rawSong.albumArtist]
                val albumId = if (artistId != null) albumIdMap[Pair(rawSong.album, artistId)] else null

                if (albumId != null) {
                    Song(
                        title = rawSong.title,
                        artist = rawSong.artist,
                        album = rawSong.album,
                        path = rawSong.path,
                        duration = rawSong.duration,
                        albumArtist = rawSong.albumArtist,
                        albumId = albumId,
                        track = rawSong.track,
                        profileId = localProfileId
                    )
                } else {
                    null
                }
            }
            songDao.insertAll(songsToInsert)
        }
        return allSongs.first().map { song ->
            val artworkUri = ContentUris.withAppendedId(Uri.parse("content://media/external/audio/albumart"), song.albumId)
            MediaItem.Builder()
                .setUri(song.path)
                .setMediaId(song.id.toString())
                .setMediaMetadata(
                    androidx.media3.common.MediaMetadata.Builder()
                        .setTitle(song.title)
                        .setArtist(song.artist)
                        .setAlbumTitle(song.album)
                        .setArtworkUri(artworkUri)
                        .build()
                )
                .build()
        }
    }
}
