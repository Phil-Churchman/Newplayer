package com.example.newplayer.data

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.PrimaryKey

@Entity(
    tableName = "local_queue",
    foreignKeys = [ForeignKey(
        entity = Song::class,
        parentColumns = ["id"],
        childColumns = ["songId"],
        onDelete = ForeignKey.CASCADE
    )]
)
data class LocalQueue(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val songId: Long,
    val position: Int,
    val isCurrent: Boolean = false
)
