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

    @Query("SELECT * FROM albums WHERE artistId = :artistId ORDER BY name ASC")
    fun getAlbumsByArtistId(artistId: Long): Flow<List<Album>>

    @Query("SELECT * FROM albums WHERE id = :albumId")
    fun getAlbumById(albumId: Long): Flow<Album?>
}
