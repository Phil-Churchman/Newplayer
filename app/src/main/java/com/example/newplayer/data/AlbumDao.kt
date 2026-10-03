package com.example.newplayer.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface AlbumDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertAll(albums: List<Album>)

    @Query("SELECT * FROM albums ORDER BY name ASC")
    fun getAll(): Flow<List<Album>>

    @Query("DELETE FROM albums")
    suspend fun deleteAll()

    @Query("DELETE FROM albums WHERE profileId = :profileId")
    suspend fun deleteByProfileId(profileId: Long)

    @Query("SELECT * FROM albums WHERE artistId = :artistId ORDER BY name ASC")
    fun getAlbumsByArtistId(artistId: Long): Flow<List<Album>>

    @Query("SELECT * FROM albums WHERE id = :albumId")
    fun getAlbumById(albumId: Long): Flow<Album?>

    @Query("SELECT ar.id as artistId, ar.name as artistName, (SELECT al.artwork FROM albums al WHERE al.artistId = ar.id ORDER BY al.name ASC LIMIT 1) as artwork FROM artists ar ORDER BY ar.name ASC")
    fun getArtistsWithArtwork(): Flow<List<ArtistWithArtwork>>
}
