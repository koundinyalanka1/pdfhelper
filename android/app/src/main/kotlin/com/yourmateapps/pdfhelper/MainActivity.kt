package com.yourmateapps.pdfhelper

import android.content.Intent
import android.util.Log
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
    }

    private val CHANNEL = "com.yourmateapps.pdfhelper/pdf"

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Update activity intent so getIntent() returns the latest (with URI + permission)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "resolvePdfUri" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrEmpty()) {
                        result.error("INVALID", "URI is null or empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val path = resolveUriToPath(uriString)
                        result.success(path)
                    } catch (e: Exception) {
                        result.error("RESOLVE_ERROR", e.message, null)
                    }
                }
                "getPdfIntentData" -> {
                    Log.d(TAG, "getPdfIntentData called, intent.data=${intent?.data} component=${intent?.component?.className}")
                    // Prefer in-memory (trampoline sets before starting MainActivity)
                    val pending = PendingPdfIntent.take()
                    if (pending != null) {
                        val (uriString, action) = pending
                        Log.d(TAG, "getPdfIntentData: from PendingPdfIntent uri=$uriString action=$action")
                        if (isPdfUri(uriString)) {
                            val path = try { resolveUriToPath(uriString) } catch (e: Exception) { null }
                            Log.d(TAG, "getPdfIntentData: resolved path=$path")
                            if (path != null) {
                                result.success(mapOf("path" to path, "action" to action))
                                return@setMethodCallHandler
                            }
                        }
                    }
                    // Fallback: read from Activity intent
                    Log.d(TAG, "getPdfIntentData: PendingPdfIntent null, trying Activity intent")
                    val data = intent ?: run {
                        Log.w(TAG, "getPdfIntentData: intent is null")
                        return@setMethodCallHandler result.success(null)
                    }
                    val uriString = data.data?.toString() ?: run {
                        Log.w(TAG, "getPdfIntentData: intent.data is null")
                        return@setMethodCallHandler result.success(null)
                    }
                    if (!isPdfUri(uriString)) {
                        Log.w(TAG, "getPdfIntentData: not a PDF uri=$uriString")
                        return@setMethodCallHandler result.success(null)
                    }
                    val path = try { resolveUriToPath(uriString) } catch (e: Exception) { null }
                        ?: run {
                            Log.w(TAG, "getPdfIntentData: failed to resolve uri")
                            return@setMethodCallHandler result.success(null)
                        }
                    val action = data.getStringExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION)
                        ?: "view"
                    Log.d(TAG, "getPdfIntentData: from intent path=$path action=$action")
                    result.success(mapOf("path" to path, "action" to action))
                }
                "getPdfIntentAction" -> {
                    val fromExtra = intent?.getStringExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION)
                    if (fromExtra != null) {
                        result.success(fromExtra)
                        return@setMethodCallHandler
                    }
                    result.success("view")
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isPdfUri(uri: String): Boolean {
        val lower = uri.lowercase()
        return lower.contains(".pdf") || lower.startsWith("content://") || lower.startsWith("file://")
    }

    private fun resolveUriToPath(uriString: String): String? {
        val uri = Uri.parse(uriString)
        return when (uri.scheme) {
            "file" -> uri.path
            "content" -> copyContentToTemp(uri)
            else -> null
        }
    }

    private fun copyContentToTemp(uri: Uri): String? {
        // Get filename from OpenableColumns if available (some providers don't support query)
        var fileName = "opened.pdf"
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0) {
                    cursor.getString(nameIndex)?.let { name ->
                        fileName = if (name.endsWith(".pdf", ignoreCase = true)) name else "$name.pdf"
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "copyContentToTemp: query failed, using default filename: $e")
        }

        // Copy content - try with FLAG_GRANT_READ_URI_PERMISSION in case permission wasn't granted
        val tempFile = File(cacheDir, "intent_${System.currentTimeMillis()}_$fileName")
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { output ->
                    input.copyTo(output)
                }
                Log.d(TAG, "copyContentToTemp: copied to ${tempFile.absolutePath}")
                tempFile.absolutePath
            } ?: run {
                Log.w(TAG, "copyContentToTemp: openInputStream returned null for $uri")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "copyContentToTemp: failed for $uri: $e")
            null
        }
    }
}
