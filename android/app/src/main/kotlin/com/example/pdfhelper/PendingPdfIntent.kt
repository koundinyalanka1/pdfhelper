package com.example.pdfhelper

import android.util.Log

/**
 * In-memory storage for PDF intent data passed from trampoline to MainActivity.
 * More reliable than SharedPreferences when FLAG_ACTIVITY_CLEAR_TASK is used.
 */
object PendingPdfIntent {
    private const val TAG = "PendingPdfIntent"

    @Volatile
    var uri: String? = null
        private set

    @Volatile
    var action: String? = null
        private set

    fun set(uri: String, action: String) {
        Log.d(TAG, "set: uri=$uri action=$action")
        this.uri = uri
        this.action = action
    }

    fun take(): Pair<String, String>? {
        val u = uri
        val a = action
        uri = null
        action = null
        val result = if (u != null && a != null) Pair(u, a) else null
        Log.d(TAG, "take: result=${if (result != null) "uri=${result.first} action=${result.second}" else "null"}")
        return result
    }
}
