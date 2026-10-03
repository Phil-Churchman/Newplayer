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

    @Query("DELETE FROM artists WHERE profileId = :profileId")
    suspend fun deleteByProfileId(profileId: Long)

    @Query("SELECT name FROM artists WHERE id = :artistId")
    fun getArtistNameById(artistId: Long): Flow<String?>
}
