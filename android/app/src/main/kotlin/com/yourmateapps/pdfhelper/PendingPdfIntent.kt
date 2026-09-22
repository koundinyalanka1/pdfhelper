package com.yourmateapps.pdfhelper


/**
 * In-memory storage for PDF intent data passed from trampoline to MainActivity.
 * More reliable than SharedPreferences when FLAG_ACTIVITY_CLEAR_TASK is used.
 */
object PendingPdfIntent {

    @Volatile
    var uri: String? = null
        private set

    @Volatile
    var action: String? = null
        private set

    @Synchronized
    fun set(uri: String, action: String) {
        this.uri = uri
        this.action = action
    }

    @Synchronized
    fun take(): Pair<String, String>? {
        val u = uri
        val a = action
        uri = null
        action = null
        val result = if (u != null && a != null) Pair(u, a) else null
        return result
    }
}
