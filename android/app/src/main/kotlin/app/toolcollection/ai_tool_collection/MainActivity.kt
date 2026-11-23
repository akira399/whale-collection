package app.toolcollection.ai_tool_collection

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) receiveShare(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { it.remove() }
        }
    }

    private var pending: MethodChannel.Result? = null
    private var backupData: String? = null
    private val gravity = CardGravity(this)
    private var gravityChannel: EventChannel? = null
    private var shareChannel: MethodChannel? = null
    private val sharedTexts = ArrayDeque<String>()

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveShare(intent)
    }

    private fun receiveShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: return
        if (text.isBlank()) return
        sharedTexts.addLast(text)
        shareChannel?.invokeMethod("available", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        gravityChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "app.toolcollection/gravity")
        gravityChannel?.setStreamHandler(gravity)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.toolcollection/share")
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "take") result.success(sharedTexts.removeFirstOrNull())
            else result.notImplemented()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.toolcollection/backup")
            .setMethodCallHandler { call, result ->
                if (pending != null) {
                    result.error("busy", "文件选择器正在使用中", null)
                    return@setMethodCallHandler
                }
                val intent = when (call.method) {
                    "export", "exportMarkdown" -> {
                        backupData = call.argument<String>("data")
                        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            val markdown = call.method == "exportMarkdown"
                            type = if (markdown) "text/markdown" else "application/json"
                            putExtra(Intent.EXTRA_TITLE, if (markdown) "大肥鱼收藏清单.md" else "大肥鱼收藏箱备份.json")
                        }
                    }
                    "import" -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                    }
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                try {
                    pending = result
                    startActivityForResult(intent, if (call.method == "import") 702 else 701)
                } catch (error: Exception) {
                    pending = null
                    backupData = null
                    result.error("picker", "无法打开文件选择器", null)
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        gravity.onCancel(null)
        gravityChannel?.setStreamHandler(null)
        gravityChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Deprecated("Android activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 701 && requestCode != 702) return
        val result = pending ?: return
        pending = null
        try {
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
            } else if (requestCode == 701) {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("无法写入文件")
                stream.bufferedWriter(Charsets.UTF_8).use { it.write(backupData ?: "") }
                result.success(true)
            } else {
                val stream = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("无法读取文件")
                result.success(stream.bufferedReader(Charsets.UTF_8).use { it.readText() })
            }
        } catch (error: Exception) {
            result.error("file", "无法读写备份文件，请重试", null)
        } finally {
            backupData = null
        }
    }
}
