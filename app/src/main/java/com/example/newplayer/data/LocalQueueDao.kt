package com.example.newplayer.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface LocalQueueDao {

    @Query("SELECT * FROM local_queue ORDER BY position ASC")
    fun getQueue(): Flow<List<LocalQueue>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun addToQueue(item: LocalQueue)

    @Query("DELETE FROM local_queue WHERE songId = :songId")
    suspend fun removeFromQueue(songId: Long)

    @Query("DELETE FROM local_queue")
    suspend fun clearQueue()

    @Query("UPDATE local_queue SET isCurrent = (songId = :songId)")
    suspend fun setCurrent(songId: Long)

    @Query("SELECT * FROM local_queue WHERE isCurrent = 1 LIMIT 1")
    fun getCurrentSong(): Flow<LocalQueue?>
}
