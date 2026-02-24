package com.example.pdfhelper

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log

/**
 * Trampoline that captures which PDF alias was used and forwards to MainActivity.
 * Stores action + URI in SharedPreferences so MainActivity can read them reliably
 * (intent extras may not survive in some launch scenarios).
 */
class PdfIntentTrampolineActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val incoming = intent ?: run {
            Log.w(TAG, "onCreate: intent is null")
            finish()
            return
        }
        val uriString = incoming.data?.toString() ?: run {
            Log.w(TAG, "onCreate: intent.data is null, component=${incoming.component?.className}")
            finish()
            return
        }
        val action = "view"
        Log.d(TAG, "onCreate: uri=$uriString action=$action component=${incoming.component?.className}")
        // Store in memory (survives CLEAR_TASK; more reliable than SharedPreferences)
        PendingPdfIntent.set(uriString, action)
        Log.d(TAG, "onCreate: starting MainActivity with EXTRA_PDF_ACTION=$action")
        val forward = Intent(this, MainActivity::class.java).apply {
            data = incoming.data
            type = incoming.type
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            putExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION, action)
            // ClipData helps grant URI permission on some providers (e.g. WhatsApp)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN && incoming.data != null) {
                clipData = ClipData.newUri(contentResolver, "pdf", incoming.data)
            }
        }
        startActivity(forward)
        finish()
    }

    companion object {
        private const val TAG = "PdfIntentTrampoline"
        const val EXTRA_PDF_ACTION = "com.example.pdfhelper.PDF_ACTION"
    }
}
