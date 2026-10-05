package work.nextline.number_memo

import android.content.Intent
import android.app.Activity
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.util.UUID
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null
    private var pendingText: String? = null
    private var dartReady = false
    private var fileChannel: MethodChannel? = null
    private var pendingSave: MethodChannel.Result? = null
    private var pendingSource: String? = null
    private val saveRequest = 7143
    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickLimit = 0L
    @Volatile private var pickCancelled = false
    private val pickRequest = 7144

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingText = sharedText(intent)
        fileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "work.nextline.number_memo/files").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveFile" -> saveFile(call, result)
                    "pickFile" -> pickFile(call, result)
                    else -> result.notImplemented()
                }
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "work.nextline.number_memo/share"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "initialText") {
                    dartReady = true
                    result.success(pendingText)
                    pendingText = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingSave != null || pendingPick != null) {
            result.error("busy", "A file dialog is already open", null)
            return
        }
        val path = call.argument<String>("sourcePath")
        if (path == null || !File(path).isFile) {
            result.error("missing", "The export file is missing", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = call.argument<String>("mimeType") ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, call.argument<String>("filename") ?: "number-memo-export")
        }
        pendingSave = result
        pendingSource = path
        try {
            startActivityForResult(intent, saveRequest)
        } catch (error: Exception) {
            pendingSave = null
            pendingSource = null
            result.error("unavailable", error.message, null)
        }
    }

    // file_selector reads Android selections into a byte[] before Dart sees
    // them. Database imports need a bounded stream and only a path over the
    // platform channel, including providers that cannot report a file size.
    private fun pickFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingSave != null || pendingPick != null) {
            result.error("busy", "파일 선택 화면이 이미 열려 있습니다.", null)
            return
        }
        val limit = call.argument<Number>("maxBytes")?.toLong()
        if (limit == null || limit <= 0 || limit > 4L * 1024 * 1024 * 1024) {
            result.error("invalid_limit", "파일 크기 제한이 올바르지 않습니다.", null)
            return
        }
        val mimeTypes = call.argument<List<String>>("mimeTypes") ?: emptyList()
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (mimeTypes.isNotEmpty()) {
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
        }
        pendingPick = result
        pendingPickLimit = limit
        pickCancelled = false
        try {
            startActivityForResult(intent, pickRequest)
        } catch (error: Exception) {
            pendingPick = null
            result.error("unavailable", error.message, null)
        }
    }

    private fun finishPick(resultCode: Int, data: Intent?) {
        val result = pendingPick ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingPick = null
            result.success(null)
            return
        }
        val limit = pendingPickLimit
        Thread {
            var directory: File? = null
            try {
                var name = "backup.db"
                var declaredSize: Long? = null
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                            name = cursor.getString(nameIndex).take(512).ifBlank { name }
                        }
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                            declaredSize = cursor.getLong(sizeIndex).takeIf { it >= 0 }
                        }
                    }
                }
                if ((declaredSize ?: 0) > limit) {
                    throw IOException("파일이 ${limit / (1024 * 1024)} MB 제한을 초과합니다.")
                }
                val root = File(cacheDir, "number-memo-imports")
                val target = File(root, UUID.randomUUID().toString())
                if (!target.mkdirs()) throw IOException("임시 폴더를 만들 수 없습니다.")
                directory = target
                val file = File(target, "source")
                var total = 0L
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "선택한 파일을 읽을 수 없습니다." }
                    file.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (pickCancelled) throw IOException("파일 가져오기가 취소되었습니다.")
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > limit) {
                                throw IOException("파일이 ${limit / (1024 * 1024)} MB 제한을 초과합니다.")
                            }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                if (declaredSize != null && total != declaredSize) {
                    throw IOException("파일이 완전히 복사되지 않았습니다. 다시 선택해 주세요.")
                }
                runOnUiThread {
                    if (pendingPick === result) {
                        pendingPick = null
                        result.success(mapOf(
                            "path" to file.path,
                            "name" to name,
                            "directory" to target.path,
                            "size" to total
                        ))
                    } else {
                        target.deleteRecursively()
                    }
                }
            } catch (error: Exception) {
                directory?.deleteRecursively()
                runOnUiThread {
                    if (pendingPick === result) {
                        pendingPick = null
                        result.error("pick_failed", error.message, null)
                    }
                }
            }
        }.start()
    }

    @Deprecated("Activity result bridge for FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickRequest) {
            finishPick(resultCode, data)
            return
        }
        if (requestCode != saveRequest) return
        val result = pendingSave ?: return
        val path = pendingSource
        pendingSave = null
        pendingSource = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || path == null) {
            result.success(null)
            return
        }
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output) { "Cannot open the selected destination" }
                    File(path).inputStream().use { input -> input.copyTo(output) }
                }
                runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) {
                runOnUiThread { result.error("save_failed", error.message, null) }
            }
        }.start()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedText(intent) ?: return
        if (dartReady) {
            shareChannel?.invokeMethod("sharedText", text)
        } else {
            pendingText = text
        }
    }

    private fun sharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return null
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(100_000)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pendingSave?.error("closed", "The app closed before the file was saved", null)
        pendingSave = null
        pendingSource = null
        pickCancelled = true
        pendingPick?.error("closed", "파일 가져오기가 완료되기 전에 앱이 닫혔습니다.", null)
        pendingPick = null
        fileChannel?.setMethodCallHandler(null)
        fileChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        dartReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
