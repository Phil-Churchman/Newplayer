package com.example.newplayer.data

import androidx.media3.common.MediaItem
import com.example.newplayer.MpdClient
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

//class RemoteSongRepository(
//    private val mpdClient: MpdClient,
//    private val songDao: SongDao,
//    private val artistDao: ArtistDao,
//    private val albumDao: AlbumDao,
//    private val profileDao: ProfileDao
//) {
//
//    val allSongs: Flow<List<Song>> = songDao.getAll()
//    val allArtists: Flow<List<Artist>> = artistDao.getAll()
//    val allAlbums: Flow<List<Album>> = albumDao.getAll()
//    val artistsWithArtwork: Flow<List<ArtistWithArtwork>> = albumDao.getArtistsWithArtwork()
//
//    fun getArtistNameById(artistId: Long): Flow<String?> {
//        return artistDao.getArtistNameById(artistId)
//    }
//
//    fun getAlbumsByArtistId(artistId: Long): Flow<List<Album>> {
//        return albumDao.getAlbumsByArtistId(artistId)
//    }
//
//    fun getAlbumById(albumId: Long): Flow<Album?> {
//        return albumDao.getAlbumById(albumId)
//    }
//
//    fun getSongsByAlbumId(albumId: Long): Flow<List<Song>> {
//        return songDao.getSongsByAlbumId(albumId)
//    }
//
//    private fun normalizeText(text: String?): String {
//        if (text.isNullOrBlank()) return ""
//        return text
//            .replace("â€™", "'")
//            .replace("â€œ", "\"")
//            .replace("â€", "\"")
//            .replace("â€“", "-")
//            .replace("â€¦", "...")
//            .replace("Ã¨", "è")
//            .replace("’", "'")
//            .replace("‘", "'")
//            .replace("“", "\"")
//            .replace("”", "\"")
//            .replace("–", "-")
//            .replace("…", "...")
//            .trim()
//    }
//
//    suspend fun syncLibrary(): List<MediaItem> {
//        val remoteProfileId = profileDao.getRemoteProfileId() ?: return emptyList()
//
//        songDao.deleteByProfileId(remoteProfileId)
//        artistDao.deleteByProfileId(remoteProfileId)
//        albumDao.deleteByProfileId(remoteProfileId)
//
//        val mpdSongs = mpdClient.fetchAllSongs() // Assuming MpdClient has this method
//
//        if (mpdSongs.isNotEmpty()) {
//            val uniqueArtistNames = mpdSongs.mapNotNull { it.albumArtist }
//                .filter { it.isNotBlank() }
//                .map { normalizeText(it) }
//                .distinct()
//            val artistsToInsert = uniqueArtistNames.map { Artist(name = it, profileId = remoteProfileId) }
//            artistDao.insertAll(artistsToInsert)
//            val artistIdMap = artistDao.getAll().first().associate { it.name to it.id }
//
//            val albumsToInsert = mpdSongs
//                .asSequence()
//                .filter { !it.album.isNullOrBlank() && !it.albumArtist.isNullOrBlank() }
//                .groupBy { normalizeText(it.albumArtist) to normalizeText(it.album) }
//                .mapNotNull { (artistAlbumPair, songsInAlbum) ->
//                    val (albumArtistName, albumName) = artistAlbumPair
//                    val artistId = artistIdMap[albumArtistName]
//                    if (artistId != null) {
//                        Album(name = albumName, artistId = artistId, artwork = null, profileId = remoteProfileId)
//                    } else {
//                        null
//                    }
//                }
//            albumDao.insertAll(albumsToInsert)
//            val albumIdMap = albumDao.getAll().first().associate { Pair(it.name, it.artistId) to it.id }
//
//            val songsToInsert = mpdSongs.mapNotNull { mpdSong ->
//                val artistName = normalizeText(mpdSong.albumArtist)
//                val albumName = normalizeText(mpdSong.album)
//                val artistId = artistIdMap[artistName]
//                val albumId = if (artistId != null) albumIdMap[Pair(albumName, artistId)] else null
//
//                if (albumId != null) {
//                    Song(
//                        title = normalizeText(mpdSong.title),
//                        artist = normalizeText(mpdSong.artist),
//                        album = albumName,
//                        path = mpdSong.path,
//                        duration = mpdSong.duration,
//                        albumArtist = artistName,
//                        albumId = albumId,
//                        track = mpdSong.track,
//                        profileId = remoteProfileId
//                    )
//                } else {
//                    null
//                }
//            }
//            songDao.insertAll(songsToInsert)
//        }
//
//        // Construct MediaItems from the newly inserted songs
//        return songDao.getSongsByProfileId(remoteProfileId).first().map { song ->
//            val songUri = mpdClient.getSongUri(song.path) // Assuming MpdClient can construct the full URI
//            MediaItem.Builder()
//                .setUri(songUri)
//                .setMediaId(song.id.toString())
//                .setMediaMetadata(
//                    androidx.media3.common.MediaMetadata.Builder()
//                        .setTitle(song.title)
//                        .setArtist(song.artist)
//                        .setAlbumTitle(song.album)
//                        .build()
//                )
//                .build()
//        }
//    }
//}
