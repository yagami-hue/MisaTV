package com.kniephos.kniephos

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.os.Environment
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val SLEEP_CHANNEL = "com.kniephos.kniephos/sleep_inhibitor"
        @Volatile
        private var spiderGuardInstalled = false
    }

    private fun installSpiderThreadCrashGuard() {
        if (spiderGuardInstalled) return
        spiderGuardInstalled = true
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val isMain = thread == Looper.getMainLooper().thread
            val isSpiderThread = !isMain && (
                thread.contextClassLoader?.javaClass?.name?.contains("SpiderDexClassLoader") == true ||
                throwable.stackTrace.any { frame ->
                    val cls = frame.className
                    cls.startsWith("com.github.catvod.") ||
                        cls.contains("SpiderDexClassLoader") ||
                        cls.contains("SpiderHostPlugin")
                }
            )
            if (isSpiderThread) {
                Log.e("MisaTV", "Intercepted uncaught spider thread crash on ${thread.name}", throwable)
            } else {
                prev?.uncaughtException(thread, throwable)
            }
        }
    }

    private fun ensureAllFilesAccessIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (Environment.isExternalStorageManager()) return
        val prefs = getSharedPreferences("misatv_perms", Context.MODE_PRIVATE)
        if (prefs.getBoolean("asked_all_files_v1", false)) return
        prefs.edit().putBoolean("asked_all_files_v1", true).apply()
        runOnUiThread {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (_: Throwable) {
                try { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) } catch (_: Throwable) {}
            }
        }
    }

    private fun exportLogFileToDownloads(srcPath: String, displayName: String): String {
        val src = File(srcPath)
        if (!src.exists() || !src.isFile) {
            throw IllegalArgumentException("日志文件不存在：$srcPath")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/MisaTV")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法创建下载目录文件")
            contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("无法写入目标文件")
            return "Download/MisaTV/$displayName"
        } else {
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val outDir = File(dir, "MisaTV").apply { mkdirs() }
            val dst = File(outDir, displayName)
            src.copyTo(dst, overwrite = true)
            return dst.absolutePath
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        installSpiderThreadCrashGuard()
        ensureAllFilesAccessIfNeeded()
        // wex / *Guard 加固壳的 Init.init(Application) 必须拿到真实的 Application。
        // FlutterPluginBinding.applicationContext 在部分机型上是 ContextImpl 而不是
        // Application，插件里再怎么剥 ContextWrapper 都取不到，所以这里从 Activity
        // 直接绑定一次 (getApplication()) 是框架保证的 Application 实例)。
        SpiderHostPlugin.bindApplication(application)
        super.configureFlutterEngine(flutterEngine)
        // 手动注册安卓原生 jar/DEX 蜘蛛运行器 (dex2jar + unidbg 的安卓等价实现)。
        // 该插件是本地代码 (未走 pub 插件自动注册)，故在此显式添加。
        flutterEngine.plugins.add(SpiderHostPlugin())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SLEEP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val enabled = (call.arguments as? Boolean) ?: false
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    "exportLogFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val name = call.argument<String>("name") ?: "misatv.log"
                        try {
                            val saved = exportLogFileToDownloads(path, name)
                            result.success(saved)
                        } catch (t: Throwable) {
                            result.error("EXPORT_FAILED", t.message ?: t.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
