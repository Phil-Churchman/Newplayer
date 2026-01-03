package com.example.newplayer.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface SongDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(songs: List<Song>)

    @Query("SELECT * FROM songs")
    fun getAll(): Flow<List<Song>>

    @Query("DELETE FROM songs")
    suspend fun deleteAll()

    @Query("DELETE FROM songs WHERE profileId = :profileId")
    suspend fun deleteByProfileId(profileId: Long)

    @Query("SELECT * FROM songs WHERE albumId = :albumId ORDER BY track ASC")
    fun getSongsByAlbumId(albumId: Long): Flow<List<Song>>
}
