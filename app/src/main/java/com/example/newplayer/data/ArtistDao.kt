package com.example.newplayer.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface ArtistDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertAll(artists: List<Artist>)

    @Query("SELECT * FROM artists ORDER BY name ASC")
    fun getAll(): Flow<List<Artist>>

    @Query("DELETE FROM artists")
    suspend fun deleteAll()
}
