package com.example.newplayer.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "artists",
    indices = [Index(value = ["name"], unique = true)]
)
data class Artist(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val name: String
)
