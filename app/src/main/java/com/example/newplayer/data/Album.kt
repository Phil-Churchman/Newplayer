package com.example.newplayer.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.example.player.data.Profile

@Entity(
    tableName = "albums",
    indices = [Index(value = ["name"], unique = true)],
    foreignKeys = [ForeignKey(
        entity = Profile::class,
        parentColumns = ["id"],
        childColumns = ["profileId"],
        onDelete = ForeignKey.CASCADE
    )
    ]
)
data class Album(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val name: String,
    val artistId: Long,
    val artwork: ByteArray? = null,
    @ColumnInfo(defaultValue = "1")
    val profileId: Long = 1
)
