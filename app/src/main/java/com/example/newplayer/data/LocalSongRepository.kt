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

    suspend fun scanForSongs() {
        val songs = mutableListOf<Song>()
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
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
            val pathColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)

            while (cursor.moveToNext()) {
                songs.add(
                    Song(
                        title = cursor.getString(titleColumn),
                        artist = cursor.getString(artistColumn),
                        album = cursor.getString(albumColumn),
                        path = cursor.getString(pathColumn),
                        duration = cursor.getLong(durationColumn)
                    )
                )
            }
        }

        if (songs.isNotEmpty()) {
            songDao.insertAll(songs)

            val artists = songs.map { Artist(name = it.artist) }.distinctBy { it.name }
            val albums = songs.map { Album(name = it.album) }.distinctBy { it.name }

            artistDao.insertAll(artists)
            albumDao.insertAll(albums)
        }
    }
}
