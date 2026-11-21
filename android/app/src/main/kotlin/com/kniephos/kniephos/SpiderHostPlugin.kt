package com.kniephos.kniephos

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipFile

/**
 * Android 版「jar / DEX 蜘蛛」运行器 —— 直接落地 MisaTV 桌面端 dex2jar + JRE + unidbg 的
 * 安卓等价实现。
 *
 * 桌面端：下载 JRE17 → dex2jar 把 .dex 转成 .class jar → 用外部 JVM 进程(spider-host.jar)
 * 通过 stdio JSON 信封调用蜘蛛 → 加固壳首次用 unidbg 模拟 ARM .so 解包。
 *
 * 安卓端（ART 直接跑 DEX，无 java 可执行文件、无外部 JVM）：
 *   · 普通 jar / dex 蜘蛛  → 用 [dalvik.system.DexClassLoader] 直接加载并反射调用，
 *                          等价于「dex2jar 把 dex 变可运行」（这是安卓原生的做法）。
 *   · 加固壳（含 ARM .so）  → 走「原生执行」而非 unidbg 模拟：安卓设备本身就是 ARM，
 *                          直接用 [System.load] 加载壳里的 .so 就能跑通解密逻辑，
 *                          再用 DexClassLoader 加载解密出的真实实现（shell-shim 快路径）。
 *
 * 本插件通过 MethodChannel(com.kniephos.kniephos/spider) 与 Dart 侧通信：
 *   loadSpider(paths, className, ext, cacheDir) -> {ok, proxyPort, error}
 *   invoke(method, args[], className)             -> {ok, data, error}
 *   unload()                                     -> {ok}
 *   loadNative(path)                             -> {ok, error}   （unidbg 替代：原生 .so）
 *
 * 蜘蛛接口（对齐 TVBox / CatVod，与桌面 SpiderHost.java 的 dispatchMethod 一致）：
 *   String homeContent(boolean)
 *   String categoryContent(String, String, boolean, Map<String,String>)
 *   String detailContent(List<String>)
 *   String searchContent(String, boolean, String)
 *   String playerContent(String, String, List<String>)
 *   String liveContent(String)
 *   Object[] proxy(Map<String,String>)
 */
class SpiderHostPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var appContext: Context? = null

    /** 按 className 保存已初始化的蜘蛛实例：一个订阅会同时用到几十个源，不能用单例互相覆盖。 */
    private data class SpiderHolder(val instance: Any, val clazz: Class<*>, val loader: ClassLoader)

    /** 同一份 jar 只建一个 ClassLoader，避免为每个源重复解包加固壳。 */
    private val loaders = ConcurrentHashMap<String, ClassLoader>()
    private val spiders = ConcurrentHashMap<String, SpiderHolder>()

    /** 已完成 Init.init(Application) 的 jar：加固壳的 native 解包全局只需一次。 */
    private val initializedShells: MutableSet<String> = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var lastClassName: String? = null

    // 网盘凭据：壳在 init() 时用 Init.context().getSharedPreferences()/getFilesDir()
    // 读登录态。Dart 侧只写了桌面 JVM 口径的文件，安卓侧必须补写这些原生通道。
    @Volatile private var driveCookies = mapOf<String, String>()
    @Volatile private var driveSeed = mapOf<String, String>()
    @Volatile private var driveCacheDir = ""
        @Volatile private var managedDriveProviders = setOf<String>()
    // 壳自带的「宿主代理」本地端口（playerContent 返回的 127.0.0.1 地址要改写到这个端口）
    @Volatile private var proxyPort = 0

    // 在进程内起一个最小 HTTP server，把 /proxy?do=… 转发给蜘蛛的 proxy(Map) 方法，
    // 让加固壳回的 127.0.0.1 取流地址在安卓上也能解析（桌面由 spider-host.jar 的
    // com.github.catvod.Proxy 监听；这里用原生 ServerSocket 等价实现）。
    private var proxyServer: ServerSocket? = null
    private val proxyExecutor = Executors.newCachedThreadPool()

    // 加载/调用蜘蛛会做文件 IO、网络请求、加固壳原生解包（可达数十秒），必须离开主线程，
    // 否则 NetworkOnMainThreadException / ANR。MethodChannel 的 reply 仍回主线程。
    private val workExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "com.kniephos.kniephos/spider"

        // 给 R8 留一条静态引用：这些宿主类只被外部 jar 反射使用，没有引用的话
        // 在 shrink 阶段会被当成无用类裁掉（真正的保名由 proguard-rules.pro 负责）。
        private val HOST_CLASSES = arrayOf(
            com.github.catvod.crawler.Spider::class.java,
            com.github.catvod.crawler.SpiderApi::class.java,
            com.github.catvod.crawler.SpiderDebug::class.java,
        )

        /** 真实的 Application，由 MainActivity 在注册插件前绑定。 */
        @Volatile
        private var boundApp: Application? = null

        @JvmStatic
        fun bindApplication(app: Application?) {
            if (app != null) boundApp = app
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        unloadInternal()
        stopProxy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "loadSpider" -> {
                    val paths = (call.argument<List<*>>("paths") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                    val className = call.argument<String>("className") ?: ""
                    val ext = call.argument<String>("ext") ?: ""
                    val cacheDir = call.argument<String>("cacheDir") ?: appContext?.cacheDir?.absolutePath ?: ""
                   val instanceKey = call.argument<String>("instanceKey") ?: ""
                    runAsync(result) { loadSpider(paths, className, ext, cacheDir, instanceKey) }
                }
                "invoke" -> {
                    val method = call.argument<String>("method") ?: ""
                    val args = (call.argument<List<*>>("args") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                   val instanceKey = call.argument<String>("instanceKey") ?: ""
                    val className = call.argument<String>("className") ?: ""
                    runAsync(result) { invoke(method, args, className, instanceKey) }
                }
                "loadNative" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(loadNative(path))
                }
                "syncDrive" -> {
                    val cookies = mutableMapOf<String, String>()
                    (call.argument<Map<*, *>>("cookies"))?.forEach { (k, v) ->
                        val key = k?.toString()?.trim()?.lowercase()
                        val value = v?.toString()?.trim()
                        if (!key.isNullOrEmpty() && !value.isNullOrEmpty()) cookies[key] = value
                    }
                    val seed = mutableMapOf<String, String>()
                    (call.argument<Map<*, *>>("seed"))?.forEach { (k, v) ->
                        val key = k?.toString()?.trim()
                        val value = v?.toString()?.trim()
                        if (!key.isNullOrEmpty() && !value.isNullOrEmpty()) seed[key] = value
                    }
                    val cacheDir = call.argument<String>("cacheDir") ?: ""
                    runAsync(result) { syncDrive(cookies, seed, cacheDir) }
                }
                "resetSpiders" -> {
                    // 网盘凭据变更后只重建蜘蛛实例：保留 ClassLoader（壳 native 已解包）
                    // 与本地代理端口，重新走 init(Context, ext) 即可读到新 Cookie。
                    spiders.clear()
                    lastClassName = null
                    result.success(mapOf("ok" to true))
                }
                "unload" -> {
                    result.success(unload())
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.success(
                mapOf(
                    "ok" to false,
                    "error" to "plugin: ${t.javaClass.name}: ${t.message}",
                ),
            )
        }
    }

    /** 把耗时调用挪到后台线程，reply 仍需回到主线程。 */
    private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        workExecutor.execute {
            val reply: Map<String, Any?> = try {
                block()
            } catch (t: Throwable) {
                mapOf("ok" to false, "error" to "plugin: ${t.javaClass.name}: ${t.message}")
            }
            mainHandler.post { result.success(reply) }
        }
    }

    // ------------------------------------------------------------------
    // 网盘凭据同步：把登录 Cookie 写进安卓壳真正会读的位置
    // ------------------------------------------------------------------
    private fun syncDrive(
        cookies: Map<String, String>,
        seed: Map<String, String>,
        cacheDir: String,
    ): Map<String, Any?> {
        driveCookies = cookies
        driveSeed = seed
        if (cacheDir.isNotEmpty()) driveCacheDir = cacheDir
        return try {
            syncDriveInternal()
            mapOf("ok" to true)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to errorChain(t))
        }
    }

    /** 每个通道独立兜底：某个目录不可写时不能让其它通道也失效。 */
    private fun syncDriveInternal() {
        val ctx = appContext ?: return
        try {
            if (driveCacheDir.isNotEmpty()) {
                File(driveCacheDir).mkdirs()
                System.setProperty("tvbox.spiderCacheDir", driveCacheDir)
            }
            System.setProperty("java.io.tmpdir", ctx.cacheDir.absolutePath)
        } catch (_: Throwable) {}

        // 通道 1：SharedPreferences（真实实现用 Init.context().getSharedPreferences）。
        val prefKeys = mapOf(
            "quark" to listOf("Wex_quark_cookie"),
            "uc" to listOf("Wex_ucpan_cookie"),
            "baidu" to listOf("Wex_baidu_cookie"),
            "115" to listOf("Wex_pan115_cookie", "Wex_115_cookie", "115_cookie", "cookie_115", "pan115_cookie"),
            "thunder" to listOf("thunderCfg", "Wex_thunder_token"),
            "guangya" to listOf("Wex_GuangYa_Cache", "Wex_guangya_token"),
        )
        try {
            val edit = ctx.getSharedPreferences("NewWexFnw_preferences", Context.MODE_PRIVATE).edit()
            for ((provider, keys) in prefKeys) {
                val value = driveCookies[provider].orEmpty().ifEmpty { if (provider == "aliyun") driveCookies["ali"].orEmpty() else "" }
                for (prefKey in keys) {
                if (value.isEmpty()) { if (managedDriveProviders.contains(provider)) edit.remove(prefKey) } else edit.putString(prefKey, formatWexPrefValue(prefKey, value))
                }
            }
            edit.putString("pan.thread_proxy_mode", "java")
            for ((k, v) in driveSeed) {
                if (k.isNotEmpty() && v.isNotEmpty()) edit.putString(k, v)
            }
            edit.apply()
        } catch (_: Throwable) {}

        // 通道 2：裸 Cookie 文件。不同壳家族分别用 getFilesDir()/getDir("TV")/
        // spiderCacheDir 作为根，全部写一遍，解绑时删除。
        val fileNames = mapOf(
            "quark" to listOf(".quarkcookie", "quark_cookie.txt"),
            "uc" to listOf(".ucpancookie", "uc_cookie.txt"),
            "baidu" to listOf(".baiducookie", "baidu_cookie.txt", "baidu.txt"),
            "115" to listOf(".115cookie", "115_cookie.txt", "115.txt"),
            "thunder" to listOf(".xunleitoken", ".xunleicookie", "xunlei_token.txt", "xunlei_cookie.txt", "xunlei.txt", ".thundertoken", "thunder_token.txt"),
            "guangya" to listOf(".guangyatoken", ".guangyacookie", "guangya_token.txt", "guangya_cookie.txt", "guangya.txt", ".guangya", "guangyapan_token.txt"),
            "bili" to listOf("bili_cookie.txt", ".bilicookie"),
        )
        val roots = mutableSetOf<File>()
        try {
            ctx.filesDir?.let { f ->
                roots.add(File(f, "TV"))
                roots.add(File(f, "files/TV"))
                roots.add(File(f, "TVBox"))
            }
            roots.add(ctx.getDir("TV", Context.MODE_PRIVATE))
            roots.add(File(ctx.dataDir, "files/TV"))
            roots.add(File(ctx.cacheDir, "TVBox"))
            roots.add(File(ctx.cacheDir, "files/TV"))
            ctx.getExternalFilesDir(null)?.let { roots.add(File(it, "TVBox")) }
            ctx.getExternalFilesDir(null)?.let { roots.add(File(it, "TV")) }
            if (driveCacheDir.isNotEmpty()) roots.add(File(driveCacheDir, "files/TV"))
        } catch (_: Throwable) {}
        for ((provider, names) in fileNames) {
            val value = driveCookies[provider].orEmpty()
            for (root in roots) {
                for (name in names) {
                try {
                    val file = File(root, name)
                    if (value.isEmpty()) {
                        if (managedDriveProviders.contains(provider)) file.delete()
                    } else {
                        root.mkdirs()
                        file.writeText(value)
                    }
                    } catch (_: Throwable) {}
                }
            }
        }

        // 通道 3：Pizazz / 太太太硬了 家族的 JSON 三字段判定。
        try {
           val dirs = mutableListOf<File>()
           runCatching { dirs.add(File(ctx.cacheDir, "tvbox-ext/TVBox").apply { mkdirs() }) }
           runCatching { dirs.add(File(Environment.getExternalStorageDirectory(), "TVBox").apply { mkdirs() }) }
val names = mapOf("quark" to "quark_cookie.txt", "uc" to "uc_cookie.txt", "baidu" to "baidu.txt", "aliyun" to "aliyun.txt", "thunder" to "xunlei_cookie.txt", "guangya" to "guangya_token.txt", "115" to "115.txt")
            val tokenFiles = mapOf("thunder" to "xunlei.txt", "guangya" to "guangya.txt")
for (dir in dirs) {
    for ((provider, name) in names) {
        runCatching {
            val value = driveCookies[provider].orEmpty()
            val file = File(dir, name)
            if (value.isEmpty()) {
               if (managedDriveProviders.contains(provider)) file.delete()
                return@runCatching
            }
            val obj = if (file.exists()) runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() } else JSONObject()
                obj.put("cookie", value)
                if (obj.optString("nickname").isEmpty()) obj.put("nickname", "MisaTV")
                if (obj.optString("member_type").isEmpty()) obj.put("member_type", "1"); if (provider == "baidu" && driveSeed["baidu_user_id"].orEmpty().isNotEmpty()) obj.put("userId", driveSeed["baidu_user_id"].orEmpty())
            file.writeText(obj.toString())
        }
    }
    for ((provider, fileName) in tokenFiles) {
        runCatching {
            val raw = driveCookies[provider].orEmpty().trim()
            val file = File(dir, fileName)
            if (raw.isEmpty()) {
               if (managedDriveProviders.contains(provider)) file.delete()
                return@runCatching
            }
            var tokenType = "Bearer"
            var accessToken = raw
            var refreshToken = ""
            var sub = ""
            var expiresIn = 7200L
            var deviceId = ""
            if (raw.startsWith("{")) {
                runCatching {
                    val src = JSONObject(raw)
                    val resp = src.optJSONObject("token_resp") ?: src
                    accessToken = resp.optString("access_token").ifEmpty { resp.optString("accessToken") }
                    refreshToken = resp.optString("refresh_token").ifEmpty { resp.optString("refreshToken") }
                    tokenType = resp.optString("token_type").ifEmpty { resp.optString("tokenType") }.ifEmpty { "Bearer" }
                    sub = resp.optString("sub").ifEmpty { resp.optString("userId") }
                    val exp = resp.optLong("expires_in", resp.optLong("expireTime", 7200L))
                    if (exp > 0L) expiresIn = exp
                    deviceId = src.optString("deviceid").ifEmpty { src.optString("deviceId") }
                }
            }
            if (deviceId.isEmpty()) {
                val digest = java.security.MessageDigest.getInstance("MD5").digest("MisaTV:$provider:$accessToken".toByteArray())
                deviceId = digest.joinToString("") { "%02x".format(it) }
            }
            val expiresEnd = System.currentTimeMillis() + expiresIn * 1000L
            val tokenResp = JSONObject()
                .put("token_type", tokenType)
                .put("access_token", accessToken)
                .put("refresh_token", refreshToken)
                .put("sub", sub)
                .put("expires_in", expiresIn)
                .put("expires_end", expiresEnd)
            val payload = JSONObject()
                .put("token_resp", tokenResp)
                .put("deviceid", deviceId)
                .put("username", "MisaTV")
            file.writeText(payload.toString())
        }
    }
}

        } catch (_: Throwable) {}; managedDriveProviders = driveCookies.filterValues { it.isNotEmpty() }.keys
    }

    private fun formatWexPrefValue(prefKey: String, raw: String): String {
        val trimmed = raw.trim()
        return when (prefKey) {
            "Wex_GuangYa_Cache" -> {
                var tokenType = "Bearer"
                var accessToken = ""
                var refreshToken = ""
                if (trimmed.startsWith("{")) {
                    try {
                        val obj = JSONObject(trimmed)
                        tokenType = obj.optString("token_type").ifEmpty { obj.optString("tokenType") }.ifEmpty { "Bearer" }
                        accessToken = obj.optString("access_token").ifEmpty { obj.optString("accessToken") }
                        refreshToken = obj.optString("refresh_token").ifEmpty { obj.optString("refreshToken") }
                    } catch (_: Throwable) {
                        refreshToken = trimmed
                    }
                } else {
                    refreshToken = trimmed
                }
                JSONObject().apply {
                    put("token_type", tokenType)
                    put("access_token", accessToken)
                    put("refresh_token", refreshToken)
                }.toString()
            }
            "thunderCfg" -> {
                var accessToken = ""
                var refreshToken = ""
                var tokenType = "Bearer"
                var userId = ""
                var deviceId = ""
                var deviceSign = ""
                var peerId = ""
                var expireTime = 0L
                if (trimmed.startsWith("{")) {
                    try {
                        val obj = JSONObject(trimmed)
                        val resp = obj.optJSONObject("token_resp") ?: obj
                        accessToken = resp.optString("accessToken").ifEmpty { resp.optString("access_token") }
                        refreshToken = resp.optString("refreshToken").ifEmpty { resp.optString("refresh_token") }
                        tokenType = resp.optString("tokenType").ifEmpty { resp.optString("token_type") }.ifEmpty { "Bearer" }
                        userId = resp.optString("userId").ifEmpty { resp.optString("user_id") }.ifEmpty { resp.optString("sub") }
                        deviceId = obj.optString("deviceId").ifEmpty { obj.optString("device_id") }
                        deviceSign = obj.optString("deviceSign").ifEmpty { obj.optString("device_sign") }
                        peerId = obj.optString("peerId").ifEmpty { obj.optString("peer_id") }
                       val rawExpire = resp.optLong("expireTime", 0L).let { if (it > 0L) it else resp.optLong("expires_end", 0L) }
                       if (rawExpire > 0L) { expireTime = if (rawExpire < 1_000_000_000_000L) rawExpire * 1000L else rawExpire }
                       else { val expiresIn = resp.optLong("expires_in", 0L); if (expiresIn > 0L) expireTime = System.currentTimeMillis() + expiresIn * 1000L }
                    } catch (_: Throwable) {
                        refreshToken = trimmed
                    }
                } else {
                    refreshToken = trimmed
                }
                JSONObject().apply {
                    put("accessToken", accessToken)
                    put("refreshToken", refreshToken)
                    put("tokenType", tokenType)
                    put("userId", userId)
                    put("expireTime", expireTime)
                    put("authVersion", "downloadprovider-25.0.6.30")
                    put("authPackage", "com.xunlei.downloadprovider")
                    put("authClientId", "Xp6vsxz_7IYVw2BB")
                    if (deviceId.isNotEmpty()) put("deviceId", deviceId)
                    if (deviceSign.isNotEmpty()) put("deviceSign", deviceSign)
                    if (peerId.isNotEmpty()) put("peerId", peerId)
                }.toString()
            }
            else -> raw
        }
    }

    // -------------------------------------------------------------------------
    // 加载并初始化蜘蛛
    // ------------------------------------------------------------------
    @Synchronized   // 加固壳首次解包很贵，串行加载避免多个源同时触发重复解包
    private fun loadSpider(paths: List<String>, className: String, ext: String, cacheDir: String, instanceKey: String = ""): Map<String, Any?> {
        return try {
            // 壳的 init(Context, ext) 会把网盘 Cookie 读进内存，必须先写好凭据。
            if (cacheDir.isNotEmpty()) driveCacheDir = cacheDir
            syncDriveInternal()
            if (paths.isEmpty()) throw IllegalArgumentException("paths 为空")
            if (className.isEmpty()) throw IllegalArgumentException("className 为空")

            // Android 14 (API 34) 起对动态代码加载加了只读要求：交给 DexClassLoader 的
            // dex / jar / apk 在打开前必须是不可写文件，否则 ART 直接抛
            // `SecurityException: Writable dex file '...' is not allowed.`。
            val jars = paths.map { path ->
                val f = File(path)
                if (!f.exists()) throw IllegalArgumentException("蜘蛛文件不存在：$path")
                if (!makeReadOnly(f)) {
                    throw SecurityException("无法把蜘蛛文件设为只读（Android 14+ 要求）：$path")
                }
                f
            }
            val dexPath = jars.joinToString(File.pathSeparator) { it.absolutePath }

            // wex / 加固壳把 .so 与加密 payload 放在 jar 的 assets/ 里，壳代码通过
            // ClassLoader.getResourceAsStream("assets/wexguard_v8.so") 取用。
            // Android 各版本 BaseDexClassLoader 对 jar 内资源的支持不一致，所以用
            // SpiderDexClassLoader 显式从 zip 读；同时把 assets 落一份到私有目录，
            // 供 native 侧可能的 System.loadLibrary / 文件查找兜底。
            val base = appContext?.cacheDir ?: File(cacheDir)
            val assetsDir = File(base, "guard_assets/${dexPath.hashCode()}").apply { mkdirs() }
            for (jar in jars) extractJarAssets(jar, assetsDir)

            val optimizedDir = File(appContext?.codeCacheDir ?: File(cacheDir), "spider_dex").apply { mkdirs() }
            val loader = loaders.getOrPut(dexPath) {
                SpiderDexClassLoader(
                    dexPath,
                    optimizedDir.absolutePath,
                    assetsDir.absolutePath,
                    this.javaClass.classLoader,
                    jars,
                )
            }

            startProxy()

            val cacheKey = instanceKey.ifEmpty { className }
            if (spiders.containsKey(cacheKey)) {
                lastClassName = cacheKey
                return mapOf("ok" to true, "proxyPort" to proxyPort)
            }

            val prevTccl = Thread.currentThread().contextClassLoader
            Thread.currentThread().contextClassLoader = loader
            try {
                // 加固壳契约（反汇编 classes.dex 得到）：Init.init(Application) 触发
                // DexNative.<clinit> 释放 assets/wexguard_v7|v8.so 并 System.load，
                // native getLoader() 解密 .guard 得到真实实现，之后 stub 的
                // BaseSpiderGuard.<init> 通过 Init.getSpider(name) 拿到真实蜘蛛。
                // 少了这一步，Class.forName(壳类) 只会得到 ClassNotFoundException。
                initShell(dexPath, loader)

                val clazz = Class.forName(className, true, loader)
                val instance = clazz.getDeclaredConstructor().newInstance()

                // init(Context, ext)
                try {
                    clazz.getMethod("init", Context::class.java, String::class.java)
                        .invoke(instance, appContext, ext)
                } catch (_: NoSuchMethodException) {
                    try { clazz.getMethod("init", Context::class.java).invoke(instance, appContext) } catch (_: NoSuchMethodException) {}
                }

                // initApi(SpiderApi)（可选）
                try {
                    val apiCls = Class.forName("com.github.catvod.crawler.SpiderApi", true, loader)
                    val api = apiCls.getDeclaredConstructor().newInstance()
                    clazz.getMethod("initApi", apiCls).invoke(instance, api)
                } catch (_: Throwable) { /* 多数蜘蛛没有 initApi */ }

                spiders[cacheKey] = SpiderHolder(instance, clazz, loader)
                lastClassName = cacheKey

                // 启动进程内宿主代理（加固壳 / 哔哩聚合源会用 127.0.0.1 回放地址）
                startProxy()

                mapOf("ok" to true, "proxyPort" to proxyPort)
            } finally {
                Thread.currentThread().contextClassLoader = prevTccl
            }
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to errorChain(t))
        }
    }

    // ------------------------------------------------------------------
    // 反射调用蜘蛛方法（对齐 SpiderHost.java dispatchMethod）
    // ------------------------------------------------------------------
    private fun invoke(method: String, args: List<String>, className: String = "", instanceKey: String = ""): Map<String, Any?> {
        val name = instanceKey.ifEmpty { className.ifEmpty { lastClassName ?: "" } }
        val holder = spiders[name] ?: return errMap("蜘蛛尚未加载：$name")
        val sp = holder.instance
        val clazz = holder.clazz
        // 进程内 HTTP 代理按最近使用的蜘蛛路由；真实实现（尤其加固壳 payload）也常从
        // 线程上下文 ClassLoader 找资源，所以调用期间绑定到它的加载器。
        lastClassName = name
        val prevTccl = Thread.currentThread().contextClassLoader
        Thread.currentThread().contextClassLoader = holder.loader
        return try {
            val data = when (method) {
                "homeContent" -> clazz.getMethod("homeContent", Boolean::class.javaPrimitiveType)
                    .invoke(sp, true) as? String ?: ""
                "homeVideoContent" -> clazz.getMethod("homeVideoContent").invoke(sp) as? String ?: ""
                "categoryContent" -> {
                    val extend = LinkedHashMap<String, String>()
                    if (args.size > 2 && args[2].isNotEmpty()) {
                        for (kv in args[2].split("&".toRegex()).toTypedArray()) {
                            val eq = kv.indexOf('=')
                            if (eq > 0) {
                                val k = decode(kv.substring(0, eq))
                                val v = decode(kv.substring(eq + 1))
                                extend[k] = v
                            }
                        }
                    }
                    clazz.getMethod(
                        "categoryContent", String::class.java, String::class.java,
                        Boolean::class.javaPrimitiveType, java.util.HashMap::class.java
                    ).invoke(
                        sp,
                        args.getOrNull(0) ?: "",
                        args.getOrNull(1) ?: "1",
                        true,
                        extend
                    ) as? String ?: ""
                }
                "detailContent" -> {
                    val rawId = args.getOrNull(0) ?: ""
                    val ids = if (args.size > 1) args.toMutableList() else if (rawId.contains("$$$") || rawId.contains("://") || rawId.startsWith("{")) mutableListOf(rawId) else rawId.split(",").toMutableList()
                    clazz.getMethod("detailContent", List::class.java)
                        .invoke(sp, ids) as? String ?: ""
                }
                "searchContent" -> {
                    val wd = args.getOrNull(0) ?: ""
                    try {
                        clazz.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType, String::class.java)
                            .invoke(sp, wd, false, args.getOrNull(1) ?: "1") as? String ?: ""
                    } catch (_: NoSuchMethodException) {
                        clazz.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType)
                            .invoke(sp, wd, false) as? String ?: ""
                    }
                }
                "playerContent" -> {
                    val vips = (args.getOrNull(2) ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
                    clazz.getMethod("playerContent", String::class.java, String::class.java, List::class.java)
                        .invoke(sp, args.getOrNull(0) ?: "", args.getOrNull(1) ?: "", vips) as? String ?: ""
                }
                "liveContent" -> clazz.getMethod("liveContent", String::class.java)
                    .invoke(sp, args.getOrNull(0) ?: "") as? String ?: ""
                "proxy" -> {
                    val params = LinkedHashMap<String, String>()
                    if (args.isNotEmpty() && args[0].isNotEmpty()) {
                        try {
                            val obj = JSONObject(args[0])
                            obj.keys().forEach { params[it] = obj.optString(it) }
                        } catch (_: Throwable) {}
                    }
                    val ret = clazz.getMethod("proxy", Map::class.java).invoke(sp, params)
                    ret?.let { toProxyJson(it) } ?: ""
                }
                else -> return errMap("未知方法: $method")
            }
            mapOf("ok" to true, "data" to data)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to errorChain(t))
        } finally {
            Thread.currentThread().contextClassLoader = prevTccl
        }
    }

    private fun loadNative(path: String): Map<String, Any> {
        return try {
            if (path.isEmpty()) throw IllegalArgumentException("path 为空")
            // 安卓原生的「unidbg 替代」：直接在本机 ART/ARM 上加载壳的 .so，
            // 让它的 JNI 解密逻辑真实跑起来（桌面用 unidbg 模拟，安卓不需要）。
            // W^X：被 dlopen 的库同样不能可写，否则新版 Android 会拒绝加载。
            val lib = File(path)
            if (!lib.exists()) throw IllegalArgumentException("原生库不存在：$path")
            makeReadOnly(lib)
            System.load(lib.absolutePath)
            mapOf("ok" to true)
        } catch (t: Throwable) {
            mapOf("ok" to false, "error" to "${t.javaClass.name}: ${t.message}")
        }
    }

    private fun unload(): Map<String, Any> {
        unloadInternal()
        stopProxy()
        return mapOf("ok" to true)
    }

    private fun unloadInternal() {
        spiders.clear()
        loaders.clear()
        lastClassName = null
    }

    // ------------------------------------------------------------------
    // 进程内宿主代理（最小 HTTP server，转发 /proxy）
    // ------------------------------------------------------------------
    @Synchronized
    private fun startProxy() {
        val existing = proxyServer
        if (existing != null && !existing.isClosed && proxyPort > 0) return
        try {
            val server = ServerSocket(0, 50, java.net.InetAddress.getLoopbackAddress())
            proxyPort = server.localPort
            proxyServer = server
            proxyExecutor.execute {
                while (!server.isClosed) {
                    try {
                        val sock = server.accept() ?: break
                        proxyExecutor.execute { handleProxy(sock) }
                    } catch (_: Throwable) {
                        if (server.isClosed) break
                    }
                }
            }
        } catch (_: Throwable) {
            proxyServer = null
            proxyPort = 0
        }
    }

    private fun stopProxy() {
        try { proxyServer?.close() } catch (_: Throwable) {}
        proxyServer = null
        proxyPort = 0
    }

    private fun handleProxy(sock: java.net.Socket) {
        try {
      sock.soTimeout = 30000
val reader = sock.getInputStream().bufferedReader()
val requestLine = reader.readLine() ?: return
val parts = requestLine.split(" ")
if (parts.size < 2) { sock.close(); return }
            val isHead = parts[0].equals("HEAD", ignoreCase = true)
val uri = java.net.URI.create("http://localhost" + parts[1])
val params = LinkedHashMap<String, String>()
uri.query?.split("&")?.forEach { pair ->
    val eq = pair.indexOf('=')
    if (eq > 0) params[decode(pair.substring(0, eq))] = decode(pair.substring(eq + 1))
}
val rawPath = uri.rawPath ?: ""
            if (rawPath.startsWith("/proxy/")) {
                val sub = rawPath.removePrefix("/proxy/")
val slashIdx = sub.indexOf('/')
val firstRaw = if (slashIdx >= 0) sub.substring(0, slashIdx) else sub
val restRaw = if (slashIdx >= 0) sub.substring(slashIdx + 1) else ""
val firstSeg = java.net.URLDecoder.decode(firstRaw, "UTF-8")
val restPath = java.net.URLDecoder.decode(restRaw, "UTF-8")
if (firstSeg.isNotEmpty() && !params.containsKey("do")) params["do"] = firstSeg
params["path"] = java.net.URLDecoder.decode(sub, "UTF-8")
params["uri"] = rawPath
if (restPath.isNotEmpty()) params["subpath"] = restPath
            }
while (true) {
    val line = reader.readLine() ?: break
    if (line.isEmpty()) break
    val colon = line.indexOf(':')
    if (colon > 0) {
        val key = line.substring(0, colon).trim().lowercase()
        val value = line.substring(colon + 1).trim()
        if (key.isNotEmpty() && !params.containsKey(key)) {
            params[key] = value
        }
    }
}
val out = if (params["do"] == "ck") ProxyResponse(200, "text/plain; charset=utf-8", "ok".toByteArray(), null, emptyMap()) else invokeProxy(params)
val hasContentTypeHeader = out.headers.keys.any { it.equals("Content-Type", ignoreCase = true) }
val hasContentLengthHeader = out.headers.keys.any { it.equals("Content-Length", ignoreCase = true) }
val hasCorsHeader = out.headers.keys.any { it.equals("Access-Control-Allow-Origin", ignoreCase = true) }
val headers = buildString {
    append("HTTP/1.1 ${out.status} ${httpStatusPhrase(out.status)}\r\n")
    if (!hasContentTypeHeader && out.contentType != null) {
        append("Content-Type: ${out.contentType}\r\n")
    }
    out.headers.forEach { (k, v) ->
        if (!k.equals("Connection", ignoreCase = true) && !k.equals("Transfer-Encoding", ignoreCase = true)) {
            append("$k: $v\r\n")
        }
    }
    if (!hasContentLengthHeader && out.bodyBytes != null) {
        append("Content-Length: ${out.bodyBytes.size}\r\n")
    }
    if (!hasCorsHeader) {
        append("Access-Control-Allow-Origin: *\r\n")
    }
    append("Connection: close\r\n\r\n")
}
val os = sock.getOutputStream()
os.write(headers.toByteArray())
if (isHead) {
                try { out.bodyStream?.close() } catch (_: Throwable) {}
            } else if (out.bodyStream != null) {
    out.bodyStream.use { stream ->
        val buf = ByteArray(8192)
        while (true) {
            val n = stream.read(buf)
            if (n < 0) break
            if (n > 0) os.write(buf, 0, n)
        }
    }
} else if (out.bodyBytes != null && out.bodyBytes.isNotEmpty()) {
    os.write(out.bodyBytes)
}
os.flush()
} catch (_: Throwable) {
try { sock.close() } catch (_: Throwable) {}
} finally {
try { sock.close() } catch (_: Throwable) {}
        }
    }

    /** 调用蜘蛛的 proxy(Map)，把 Object[]{status, contentType, InputStream} 转成 HTTP 响应。 */
private class ProxyResponse(
    val status: Int,
    val contentType: String?,
    val bodyBytes: ByteArray?,
    val bodyStream: InputStream?,
    val headers: Map<String, String>
)

private fun httpStatusPhrase(code: Int): String = when (code) {
    200 -> "OK"
    201 -> "Created"
    204 -> "No Content"
    206 -> "Partial Content"
    301 -> "Moved Permanently"
    302 -> "Found"
    303 -> "See Other"
    304 -> "Not Modified"
    307 -> "Temporary Redirect"
    308 -> "Permanent Redirect"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    416 -> "Range Not Satisfiable"
    500 -> "Internal Server Error"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    else -> "OK"
}

private fun invokeProxy(params: Map<String, String>): ProxyResponse {
    val holder = lastClassName?.let { spiders[it] }
        ?: return ProxyResponse(500, "text/plain; charset=utf-8", "spider not loaded".toByteArray(), null, emptyMap())
    val sp = holder.instance
    val clazz = holder.clazz
    return try {
        fun callGlobalProxy(): Any? = try {
            Class.forName("com.github.catvod.spider.Proxy", true, holder.loader)
                .getMethod("proxy", Map::class.java)
                .invoke(null, params)
        } catch (_: ClassNotFoundException) {
            null
        } catch (_: NoSuchMethodException) {
            null
        }
        fun callSpiderProxy(): Any? {
            var r = try {
                clazz.getMethod("proxy", Map::class.java).invoke(sp, params)
            } catch (_: NoSuchMethodException) {
                null
            }
            if (r == null) {
                r = try {
                    clazz.getMethod("proxyLocal", Map::class.java).invoke(sp, params)
                } catch (_: NoSuchMethodException) {
                    null
                }
            }
            return r
        }
        val ret = if (params.containsKey("do")) {
            callGlobalProxy() ?: callSpiderProxy()
        } else {
            callSpiderProxy() ?: callGlobalProxy()
        }
        val arr = ret as? Array<*>
            ?: return ProxyResponse(500, "text/plain; charset=utf-8", "bad proxy return".toByteArray(), null, emptyMap())
        val status = (arr.getOrNull(0) as? Number)?.toInt() ?: 200
        val contentType = (arr.getOrNull(1) as? String)?.takeIf { it.isNotBlank() }
        val headers = LinkedHashMap<String, String>()
        val rawHeaders = arr.getOrNull(3) as? Map<*, *>
        rawHeaders?.forEach { (k, v) ->
            val key = k?.toString()?.trim()
            val value = v?.toString()?.trim()
            if (!key.isNullOrEmpty() && value != null) {
                headers[key] = value
            }
        }
        when (val body = arr.getOrNull(2)) {
            is InputStream -> ProxyResponse(status, contentType, null, body, headers)
            is ByteArray -> ProxyResponse(status, contentType, body, null, headers)
            is String -> ProxyResponse(status, contentType, body.toByteArray(), null, headers)
            else -> ProxyResponse(status, contentType, ByteArray(0), null, headers)
        }
    } catch (t: Throwable) {
        ProxyResponse(500, "text/plain; charset=utf-8", (rootCause(t).message ?: "").toByteArray(), null, emptyMap())
    }
}

    // ------------------------------------------------------------------
    // 加固壳初始化
    // ------------------------------------------------------------------

    /**
     * wex / *Guard 加固壳的入口是 jar 内的 `com.github.catvod.spider.Init.init(Application)`：
     * 它会触发 DexNative 释放 assets 里的 ARM .so 并 System.load，再由 native
     * getLoader() 解密 .guard 得到真正的蜘蛛实现。TVBox 宿主加载 jar 后都会显式调它，
     * 本插件之前漏了这一步，导致壳 stub 永远拿不到真实实现。
     *
     * 普通 jar 没有这个类，直接跳过。
     */
    private fun initShell(dexPath: String, loader: ClassLoader) {
        if (!initializedShells.add(dexPath)) return
        try {
            val initCls = try {
                Class.forName("com.github.catvod.spider.Init", false, loader)
            } catch (_: ClassNotFoundException) {
                return
            }

            // 壳版本不同，init 的签名可能是 (Application)、(Context) 或无参。
            // 之前写死 getDeclaredMethod("init", Context) 会在 (Application) 上抛
            // NoSuchMethodException；这里按签名兼容地挑一个，找不到就当普通 jar 跳过。
            val methods = initCls.declaredMethods.filter { it.name == "init" }
            val target = methods.firstOrNull { m ->
                val ps = m.parameterTypes
                ps.isNotEmpty() && ps.size == 1 && ps[0].isAssignableFrom(Application::class.java)
            } ?: methods.firstOrNull { it.parameterTypes.isEmpty() }
            if (target == null) {
                // 有 Init 类但没有可调用的 init：不阻断普通蜘蛛加载。
                return
            }

            val app = if (target.parameterTypes.isEmpty()) null else applicationObject()
            if (target.parameterTypes.isNotEmpty() && app == null) {
                throw IllegalStateException(
                    "无法取得 Application（加固壳 Init.init 需要它）；" + contextDiagnostics()
                )
            }
            target.isAccessible = true
            if (target.parameterTypes.isEmpty()) target.invoke(null) else target.invoke(null, app)
        } catch (t: Throwable) {
            initializedShells.remove(dexPath)   // 解包失败可下次重试
            throw t
        }
    }

    /**
     * Init.init 内部会把参数强转成 Application，但 Flutter 的 applicationContext 在
     * 部分机型 / Flutter 版本里是 android.app.ContextImpl（或多层 ContextWrapper），
     * 单纯剥 wrapper 再 `as? Application` 会返回 null —— 这正是上一版日志里
     * "无法取得 Application" 的原因。这里按可靠性从高到低依次尝试：
     *   1. MainActivity 绑定的 Activity.getApplication()（框架保证）
     *   2. Context.getApplicationContext()（ContextImpl 会返回 LoadedApk 里的 Application）
     *   3. wrapper 链上任意一层是 Application
     *   4. 隐藏 API ActivityThread.currentApplication / AppGlobals.getInitialApplication
     *   5. ContextImpl.mPackageInfo.mApplication 兜底
     */
    private fun applicationObject(): Application? {
        boundApp?.let { return it }
        try {
            (appContext?.applicationContext as? Application)?.let { return it }
        } catch (_: Throwable) {}

        var ctx: Context? = appContext
        var hops = 0
        val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Context, Boolean>())
        while (ctx != null && hops++ < 8 && seen.add(ctx)) {
            if (ctx is Application) return ctx
            try {
                (ctx.applicationContext as? Application)?.let { return it }
            } catch (_: Throwable) {}
            ctx = (ctx as? ContextWrapper)?.baseContext
        }

        for (spec in arrayOf(
            "android.app.ActivityThread" to "currentApplication",
            "android.app.AppGlobals" to "getInitialApplication",
        )) {
            try {
                val cls = Class.forName(spec.first)
                val m = cls.getDeclaredMethod(spec.second).apply { isAccessible = true }
                (m.invoke(null) as? Application)?.let { return it }
            } catch (_: Throwable) {}
        }

        try {
            var c: Context? = appContext
            repeat(8) { c = (c as? ContextWrapper)?.baseContext ?: c }
            c?.let { base ->
                val pkg = base.javaClass.getDeclaredField("mPackageInfo")
                    .apply { isAccessible = true }.get(base)
                (pkg.javaClass.getDeclaredField("mApplication").apply { isAccessible = true }
                    .get(pkg) as? Application)?.let { return it }
            }
        } catch (_: Throwable) {}
        return null
    }

    /** Application 真的取不到时，把 Context 的类名链打进日志，便于下一轮定位。 */
    private fun contextDiagnostics(): String {
        val chain = mutableListOf<String>()
        var ctx: Context? = appContext
        var hops = 0
        while (ctx != null && hops++ < 6) {
            chain.add(ctx.javaClass.name)
            val next = (ctx as? ContextWrapper)?.baseContext
            if (next == null || next === ctx) break
            ctx = next
        }
        val appCtx = try { appContext?.applicationContext?.javaClass?.name } catch (_: Throwable) { "err" }
        return "appContext=${appContext?.javaClass?.name}, chain=${chain.joinToString(">")}, " +
            "applicationContext=$appCtx, boundApp=${boundApp?.javaClass?.name}"
    }

    /** 把 jar 内 assets/ 下的 .so / .guard 落一份到私有目录，作为 native 侧兜底。 */
    private fun extractJarAssets(jar: File, outDir: File) {
        try {
            outDir.mkdirs()
            ZipFile(jar).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val name = entry.name
                    if (entry.isDirectory || !name.startsWith("assets/")) continue
                    val target = File(outDir, name.removePrefix("assets/"))
                    if (!target.canonicalPath.startsWith(outDir.canonicalPath + File.separator)) continue
                    if (target.exists() && target.length() == entry.size) continue
                    target.parentFile?.mkdirs()
                    zip.getInputStream(entry).use { input ->
                        FileOutputStream(target).use { out -> input.copyTo(out) }
                    }
                    if (name.endsWith(".so")) {
                        // Android 14+ 的 W^X：dlopen 的库文件也必须不可写。
                        makeReadOnly(target)
                        // System.loadLibrary("wexguard_v8") 需要 lib 前缀，壳里存的是
                        // assets/wexguard_v8.so，补一份别名让两种加载方式都能命中。
                        val leaf = target.name
                        if (!leaf.startsWith("lib")) {
                            val alias = File(target.parentFile, "lib$leaf")
                            if (!alias.exists()) {
                                target.copyTo(alias, overwrite = true)
                                makeReadOnly(alias)
                            }
                        }
                    }
                }
            }
        } catch (_: Throwable) { /* 普通 jar / 非 zip：没有 assets 是正常的 */ }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /** 反射调用会把真实异常包成 InvocationTargetException，日志里必须展开整条链。 */
    private fun errorChain(t: Throwable): String {
        val parts = mutableListOf<String>()
        var cur: Throwable? = t
        var hops = 0
        while (cur != null && hops++ < 6) {
            val msg = cur.message
            parts.add(cur.javaClass.name + if (msg.isNullOrEmpty()) "" else ": $msg")
            cur = cur.cause
        }
        return parts.joinToString(" <- ")
    }

    /**
     * Android 14 (API 34) 起，DexClassLoader / System.load 打开的文件必须不可写
     * （"更安全的动态代码加载"）。Dart 侧下载的 jar 默认是可写的，这里在加载前收紧权限。
     * File.setReadOnly() 内部就是 chmod；个别 ROM 上不生效时用 /system/bin/chmod 兜底。
     */
    private fun makeReadOnly(file: File): Boolean {
        if (!file.exists()) return false
        if (file.canWrite()) file.setReadOnly()
        if (file.canWrite()) {
            try {
                Runtime.getRuntime().exec(arrayOf("/system/bin/chmod", "444", file.absolutePath)).waitFor()
            } catch (_: Throwable) { /* 部分 ROM 无该可执行文件 */ }
        }
        return !file.canWrite()
    }

    private fun errMap(msg: String): Map<String, Any> = mapOf("ok" to false, "error" to msg)

    private fun decode(s: String): String = try { java.net.URLDecoder.decode(s, "UTF-8") } catch (_: Throwable) { s }

    private fun rootCause(t: Throwable): Throwable {
        var c = t
        while (c.cause != null) c = c.cause as Throwable
        return c
    }

    private fun toProxyJson(ret: Any?): String {
        if (ret !is Array<*>) return ""
        val status = (ret.getOrNull(0) as? Number)?.toInt() ?: 200
        val bytes = when (val b = ret.getOrNull(2)) {
            is ByteArray -> b.toString(Charsets.UTF_8)
            is String -> b
            is InputStream -> readStream(b).toString(Charsets.UTF_8)
            else -> ""
        }
        return JSONObject().apply {
            put("status", status)
            put("body", bytes)
        }.toString()
    }

    private fun readStream(stream: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        var n: Int
        while (stream.read(buf).also { n = it } > 0) {
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /**
     * 加固壳用 `Init.classLoader().getResourceAsStream("assets/wexguard_v8.so")` 与
     * `getSystemResourceAsStream("assets/xxx.guard")` 读取 jar 内的载荷。
     * Android 的 BaseDexClassLoader 对 zip 内非 dex 资源的支持随版本变化（不保证
     * findResource 能命中），因此这里显式从 jar 读取，保证壳的 DexNative.<clinit>
     * 一定能拿到 .so，否则会 NPE / UnsatisfiedLinkError。
     */
    private class SpiderDexClassLoader(
        dexPath: String,
        optimizedDirectory: String?,
        librarySearchPath: String?,
        parent: ClassLoader?,
        private val jars: List<File>,
    ) : dalvik.system.DexClassLoader(dexPath, optimizedDirectory, librarySearchPath, parent) {

        private fun jarEntryUrl(name: String): java.net.URL? {
            val key = name.removePrefix("/")
            for (jar in jars) {
                try {
                    ZipFile(jar).use { zip ->
                        if (zip.getEntry(key) == null) return@use
                        return java.net.URL("jar:" + jar.toURI().toURL().toExternalForm() + "!/" + key)
                    }
                } catch (_: Throwable) { /* 换下一个 jar */ }
            }
            return null
        }

        override fun getResourceAsStream(name: String?): InputStream? {
            if (name.isNullOrEmpty()) return null
            val key = name.removePrefix("/")
            for (jar in jars) {
                try {
                    ZipFile(jar).use { zip ->
                        val entry = zip.getEntry(key) ?: return@use
                        val bytes = zip.getInputStream(entry).use { it.readBytes() }
                        return ByteArrayInputStream(bytes)
                    }
                } catch (_: Throwable) { /* 换下一个 jar */ }
            }
            return super.getResourceAsStream(name)
        }

        override fun findResource(name: String?): java.net.URL? {
            if (name.isNullOrEmpty()) return super.findResource(name)
            return jarEntryUrl(name) ?: super.findResource(name)
        }

        override fun getResource(name: String?): java.net.URL? {
            if (name.isNullOrEmpty()) return super.getResource(name)
            // 壳的 assets/* 优先取 jar 内的副本，别被宿主 APK 同名资源遮蔽。
            return jarEntryUrl(name) ?: super.getResource(name)
        }

        override fun getResources(name: String?): java.util.Enumeration<java.net.URL> {
            if (name.isNullOrEmpty()) return super.getResources(name)
            val own = jarEntryUrl(name) ?: return super.getResources(name)
            val rest = try { super.getResources(name) } catch (_: Throwable) {
                java.util.Collections.emptyEnumeration<java.net.URL>()
            }
            val list = mutableListOf(own)
            while (rest.hasMoreElements()) list.add(rest.nextElement())
            return java.util.Collections.enumeration(list)
        }
    }
}
