import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * 桌面版 Spider 运行器 —— 等效 DexClassLoader 的宿主侧。
 * 用法:
 *   一次性: SpiderHost <spiderJar>[;<jar2>...] <className> <method> [args...]
 *   常驻:   SpiderHost --serve <spiderJar>[;<jar2>...]
 * 结果 JSON 打到 stdout；错误/日志走 stderr。
 *
 * ★ Kniephos fork 说明（2026-10-27，自 stubs.jar 内 SpiderRunner 源码复制）：
 *   唯一改动 = `serve()` 的请求**在主线程顺序执行**，不再提交 WORKERS 线程池。
 *   实证：池化线程上执行时，加固壳家族（wex / AiNew*）的 detailContent 会拿到空
 *   站点基址（okhttp `Expected URL scheme 'http' or 'https' but no colon was found`），
 *   playerContent 抛反射 NPE；同一参数在主线程的一次性路径下完全正常 —— 该族的
 *   站点基址解析与「初始化线程」绑定（Android 桩的 main thread 语义）。串行执行
 *   不影响 SpiderPool 的「类名+ext」实例复用语义。
 *   之所以 fork 而不是改 stubs.jar：本机没有 JDK，且 stubs.jar 是成套构建产物。
 *
 * ★ 常驻(--serve)协议：环境只初始化一次（URLClassLoader + Init/App 单例），
 *   然后循环从 stdin 读 JSON 行请求：
 *     {"id": "...", "className": "com.github.catvod.spider.Xxx", "method": "homeContent", "args": ["ext", ...]}
 *   每请求从 SpiderPool 取实例（按「类名+ext」复用，避免跨请求状态串扰），
 *   结果以**单行 JSON 信封**写 stdout 并 flush：
 *     {"id":"...", "ok":true|false, "data":"结果JSON字符串", "pp":<宿主代理端口>}
 *   data 经 Gson 序列化（内嵌 \n 被转义为 \\n），物理单行，行协议不被结果内容打穿。
 *   读到 EOF 或 "quit" 行退出。
 */
public class SpiderHost {

  /** ★ 宿主代理实际绑定端口（ensureHostProxy 后生效；信封 `pp` 字段上报给宿主） */
  private static int hostProxyPort = -1;

  /**
   * ★ 2026-10-09（jar 自解链前置，勿删）：**启动即拉起 JVM 内宿主代理**。
   *   背景：jar 里的 `com.github.catvod.spider.Proxy.a()` 自己探 9978~9999 的 `/proxy?do=ck`
   *   （桌面端已应答 ok）来决定播放地址端口——它**不会**经 `Class.forName("com.github.catvod.Proxy")`
   *   触发本 JVM 宿主代理（`com.github.catvod.Proxy.ensure()`）启动 ⇒ 宿主代理端口（-Dtvbox.proxy.port）
   *   无人监听，播放器打 `/proxy/<port>` 必 ECONNREFUSED（1.20.0 第三出真机实证）。
   *   反射调一次 getPort() 即完成 ensure()（绑 -Dtvbox.proxy.port，失败退化临时端口），与旧行为兼容。
   *   ★ 端口经信封 `pp` 上报：多 JVM 并存时，宿主把播放地址改写到**真正服务过调用的这一只**，
   *     `Pan.proxy` 的 shareid/BDCLND 状态就在它内存里（第四→五轮实证 19973 被无状态 JVM 占有的错位）。
   */
  private static void ensureHostProxy() {
    try {
      Object p = Class.forName("com.github.catvod.Proxy").getMethod("getPort").invoke(null);
      if (p instanceof Number) hostProxyPort = ((Number) p).intValue();
      // 把**实际绑定端口**打给宿主：-Dtvbox.proxy.port 被残留 JVM / 同 jar 的
      // serve host 占用时，Proxy 会退化到临时端口；`--hold` 没有信封可回传 pp，
      // 宿主只能靠这行 stderr 把壳吐出的 127.0.0.1:<旧端口>/proxy 改写到正确进程。
      if (hostProxyPort > 0) {
        System.err.println("[host-proxy] listening port=" + hostProxyPort);
      } else {
        System.err.println("[host-proxy] 未启动（端口无效）");
      }
    } catch (Throwable t) {
      System.err.println("[host-proxy] 预启动失败: " + t);
    }
  }

  /**
   * ★ 2026-10-09（第六轮真机实证修复，勿删）：把**蜘蛛 jar 的类加载器**绑定给宿主代理。
   *   预启动发生在 setupEnv 之前（栈上只有应用加载器），captureCallerLoader 捕获不到
   *   jar 加载器且只捕获一次 ⇒ dispatch 反射 `com.github.catvod.spider.Proxy` 时
   *   `ClassNotFoundException` → `/proxy/<port>` 全部 500。
   *   必须在 setupEnv 之后调用本方法（serve 与一次性两条路都调）。
   */
  private static void bindHostProxyLoader(ClassLoader cl) {
    try {
      Class.forName("com.github.catvod.Proxy").getMethod("bindLoader", ClassLoader.class).invoke(null, cl);
    } catch (Throwable t) {
      System.err.println("[host-proxy] 绑定类加载器失败: " + t);
    }
  }

  public static void main(String[] args) {
    // 站源载荷（尤其加固壳）可能自己调用 System.exit 杀死宿主。
    // 在加载任何 spider jar 之前安装守卫：宿主自己的退出照常放行，
    // 载荷发起的退出只让本次 RPC 失败，进程继续服务后续请求。
    ExitGuard.install();
    ensureHostProxy();
    // ★ stdout 专供「结果/信封」：蜘蛛自己的 System.out.println 会与结果/信封共用同一管道，
    //   打印碎片（不带换行的半行）+ 信封 → 整行 JSON 解析失败 → 常驻池侧挂起到超时
    //   （用户侧表现「半天搜不出来」）。这里把 System.out 重定向到 stderr，
    //   结果与信封一律走 realOut（stderr 由宿主消费，既防管道写满也保留 SpiderLog 诊断）。
    PrintStream realOut = System.out;
    System.setOut(System.err);
    int code = 0;
    try {
      // ★ 常驻模式：--serve <jars;...>（环境只初始化一次，服务多请求）
      if (args.length >= 2 && "--serve".equals(args[0])) {
        serve(args[1].split(";"), realOut);
        return; // serve 靠 EOF / quit 自然返回，不 System.exit（保持 JVM 退出码 0）
      }
      if (args.length < 3) throw new IllegalArgumentException("usage: SpiderHost <jars;...> <className> <method> [args...]");
      // ★ Kniephos fork：--hold <jars;...> <className> <method> [args...]
      //   打完结果后**不退出**（挂住 JVM，让壳内自解链服务 / 宿主代理活着），
      //   直到 stdin EOF 或收到 quit 行。播放链路必须走这条：网盘取流地址是
      //   `http://127.0.0.1:<shellPort>/chunk?...`（壳自己的多线程取流服务）
      //   与 `http://127.0.0.1:<pp>/proxy?...`（宿主代理），都在这个 JVM 内存里。
      boolean hold = false;
      if ("--hold".equals(args[0])) {
        hold = true;
        args = Arrays.copyOfRange(args, 1, args.length);
        if (args.length < 3) throw new IllegalArgumentException("usage: SpiderHost --hold <jars;...> <className> <method> [args...]");
      }
      String[] jars = args[0].split(";");
      Env env = setupEnv(jars);
      bindHostProxyLoader(env.cl);
      String result = dispatch(env, args[1], args[2],
          args.length > 3 ? Arrays.copyOfRange(args, 3, args.length) : new String[0], null);
      realOut.println(result == null ? "" : result);
      realOut.flush();
      if (hold) {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        String line;
        while ((line = in.readLine()) != null) {
          if ("quit".equals(line.trim())) break;
        }
        System.exit(0); // 宿主已放手（播放结束/应用退出）；壳内守护线程不保证自然结束
      }
    } catch (Throwable t) {
      Throwable cause = unwrap(t);
      System.err.println("[SpiderHost.ERROR] " + cause.getClass().getName() + ": " + cause.getMessage());
      StackTraceElement[] st = cause.getStackTrace();
      for (int i = 0; i < Math.min(6, st.length); i++) System.err.println("    at " + st[i]);
      code = 1;
    }
    System.exit(code);
  }

  /**
   * 拦截站源载荷自己发起的 {@link System#exit(int)}。
   *
   * <p>加固壳/转换 jar 里偶有 {@code System.exit(1)}（或第三方库的退出调用）。
   * 进程一死，常驻池里的 Cookie、解包产物和取流地址全部丢失，用户侧表现为
   * 「详情/播放突然失败，重开又要重新初始化」。这里用只关心退出的
   * SecurityManager：宿主类加载器发起的退出放行，载荷类加载器发起的退出
   * 记录调用栈并抛 SecurityException，让本次 RPC 失败但宿主继续活着。
   *
   * <p>JDK 17+ 需要 {@code -Djava.security.manager=allow}（见 Dart 侧
   * {@code jar_spider.dart} 的 JVM 参数）。安装失败只记一行日志，不影响启动。
   * {@code Runtime.halt()} 不受 SecurityManager 管辖，拦不住。
   */
  @SuppressWarnings("removal")
  static final class ExitGuard {
    private static volatile boolean installed;

    private ExitGuard() {
    }

    static void install() {
      if (installed) return;
      try {
        if (System.getSecurityManager() != null) {
          installed = true;
          return;
        }
        System.setSecurityManager(new Guard());
        installed = true;
        System.err.println("[ExitGuard] installed");
      } catch (Throwable t) {
        System.err.println("[ExitGuard] install skipped: " + t);
      }
    }

    static final class Guard extends SecurityManager {
      @Override public void checkPermission(java.security.Permission permission) {
        // 只关心退出；其它权限一律放行，避免打断载荷的反射/文件访问。
      }

      @Override public void checkPermission(java.security.Permission permission, Object context) {
      }

      @Override public void checkExit(int status) {
        Class<?>[] context = getClassContext();
        Class<?> caller = callerClassOfExit(context);
        if (isHost(caller)) return;
        String name = caller == null ? "" : caller.getName();
        report(status, name, context);
        throw new SecurityException(
            "站源载荷请求退出 JVM（exit=" + status + "，来源 " + name + "），已被拦截");
      }
    }

    /** 跳过 JDK 与守卫自身，返回真正发起退出的类。 */
    static Class<?> callerClassOfExit(Class<?>[] context) {
      if (context == null) return null;
      for (Class<?> frame : context) {
        if (frame == null) continue;
        String name = frame.getName();
        if (name.startsWith("java.lang.") || name.startsWith("java.security.")) continue;
        if (name.startsWith("SpiderHost$ExitGuard") || name.equals("SpiderHost")) continue;
        return frame;
      }
      return null;
    }

    /**
     * 宿主判定看类加载器，不看包名：载荷壳类可能伪装成
     * {@code com.github.catvod.*}，按前缀放行会漏判。
     */
    static boolean isHost(Class<?> caller) {
      if (caller == null) return true;
      ClassLoader own = ExitGuard.class.getClassLoader();
      ClassLoader loader = caller.getClassLoader();
      if (loader == null) return own == null;
      return loader == own;
    }

    private static void report(int status, String caller, Class<?>[] context) {
      try {
        System.err.println("[ExitGuard] blocked System.exit(" + status + ") from " + caller
            + " thread=" + Thread.currentThread().getName());
        int printed = 0;
        for (Class<?> frame : context) {
          if (frame == null) continue;
          String name = frame.getName();
          if (name.startsWith("java.lang.") || name.startsWith("java.security.")) continue;
          System.err.println("[ExitGuard]   at " + name);
          if (++printed >= 8) break;
        }
        System.err.flush();
      } catch (Throwable ignored) {
        // 日志失败不能影响拦截本身。
      }
    }
  }

  /**
   * 常驻服务：读 stdin JSON 行 → **提交到线程池并发执行** → 单行 JSON 信封应答（realOut 专用）。
   *
   * ★★ 2026-09-23 三轮重做（用户反馈「进源加载慢得要死、搜索更慢」）★★
   *   旧实现两个致命点：
   *     ① **串行**：一个 JVM 同时只处理一个请求 → 33 个源要么排队（慢），要么靠多开 JVM 换并行度
   *        （每个 JVM 冷启动 1~3s + 84MB，且首次搜索要同时冷启 6 个 → 磁盘/CPU/杀软齐打，越搜越慢）；
   *     ② **每请求 new 实例 + init(ext) + initApi**：绝大数 fty 蜘蛛的 init 会解析/解密 ext、
   *        建 HTTP 客户端甚至预取站点数据 —— 每次调用都重付一遍，进源/搜索自然慢。
   *   现在：线程池（24 线程并发，蜘蛛调用绝大多数时间在等网络）+ **实例池复用**
   *   （同一「类名+ext」最多 2 个实例：init 只做一次，并发调用各取一个；池满则临时实例兜底）。
   *   对齐安卓 TVBox 的 SpiderManager（那里就是一个站点一个长期存活的实例）。
   */
  private static void serve(String[] jars, PrintStream realOut) throws Exception {
    final Env env = setupEnv(jars);
    bindHostProxyLoader(env.cl);
    final com.google.gson.Gson gson = new com.google.gson.Gson();
    BufferedReader in = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
    String line;
    while ((line = in.readLine()) != null) {
      String t = line.trim();
      if (t.isEmpty()) continue;
      if ("quit".equals(t)) break;
      String reqId = "";
      String cls = "";
      String method = "";
      String[] args = new String[0];
      try {
        com.google.gson.JsonObject req = gson.fromJson(t, com.google.gson.JsonObject.class);
        reqId = req.has("id") ? req.get("id").getAsString() : "";
        cls = req.get("className").getAsString();
        method = req.get("method").getAsString();
        List<String> argList = new ArrayList<String>();
        com.google.gson.JsonArray arr = req.has("args") && req.get("args").isJsonArray() ? req.getAsJsonArray("args") : null;
        if (arr != null) for (int i = 0; i < arr.size(); i++) argList.add(arr.get(i).isJsonNull() ? "" : arr.get(i).getAsString());
        args = argList.toArray(new String[0]);
      } catch (Throwable t0) {
        writeEnvelope(realOut, gson, reqId, false, "bad request: " + t0);
        continue;
      }
      // ★ 预热探针（池 warm）：
      //   __ping__ → 只确认 env 就绪（setupEnv 已在 serve 入口完成）；
      //   __warm__ → 进一步**加载蜘蛛类并预建实例（含 init(ext)/initApi）放入实例池**，
      //              于是用户第一次进源/搜索时连类加载与 init 都不用付（args[0] = ext）。
      if ("__ping__".equals(method)) {
        writeEnvelope(realOut, gson, reqId, true, "");
        continue;
      }
      if ("__warm__".equals(method)) {
        String err = "";
        try {
          Object sp = SpiderPool.acquire(env, cls, args);
          SpiderPool.release(cls, args, sp, false);
        } catch (Throwable t0) {
          err = unwrap(t0).getClass().getName() + ": " + unwrap(t0).getMessage();
        }
        writeEnvelope(realOut, gson, reqId, err.isEmpty(), err);
        continue;
      }
// ★ Kniephos fork：主线程顺序执行（见类注释）。原实现为 WORKERS.submit(new Runnable(){…})，
      //   池化线程上加固壳家族解析不出站点基址。
      boolean ok = false;
      String data = "";
      Object sp = null;
      try {
        sp = SpiderPool.acquire(env, cls, args);
        data = dispatchMethod(sp, method, args);
        ok = true;
      } catch (Throwable t0) {
        Throwable cause = unwrap(t0);
        data = cause.getClass().getName() + ": " + cause.getMessage();
        StackTraceElement[] st = cause.getStackTrace();
        for (int i = 0; i < Math.min(4, st.length); i++) System.err.println("    at " + st[i]);
      } finally {
        // 复用实例（异常时丢弃：可能已被打断到不可用状态，下次重建更稳）
        if (sp != null) SpiderPool.release(cls, args, sp, !ok);
      }
      writeEnvelope(realOut, gson, reqId, ok, data);
    }
    WORKERS.shutdown();
  }

  /** 并发工作线程池（蜘蛛调用是「等网络」，线程数给足；守护线程不阻塞 JVM 退出） */
  private static final java.util.concurrent.ExecutorService WORKERS =
      java.util.concurrent.Executors.newFixedThreadPool(24, new java.util.concurrent.ThreadFactory() {
        @Override public Thread newThread(Runnable r) {
          Thread th = new Thread(r, "spider-call");
          th.setDaemon(true);
          return th;
        }
      });

  /** 单行信封（多线程并发写同一 stdout → 必须同步，避免两行交错成半个 JSON） */
  private static void writeEnvelope(PrintStream realOut, com.google.gson.Gson gson, String id, boolean ok, String data) {
    LinkedHashMap<String, Object> out = new LinkedHashMap<String, Object>();
    out.put("id", id);
    out.put("ok", ok);
    out.put("data", data == null ? "" : data);
    if (hostProxyPort > 0) out.put("pp", hostProxyPort); // ★ 2026-10-09：宿主代理实际端口（jar 自解链改写用）
    String s = gson.toJson(out);
    synchronized (realOut) {
      realOut.println(s);
      realOut.flush();
    }
  }

  /**
   * ★ 实例池：键 = 类名 + ext（ext 变 = 网盘 token/配置变了 → 必须换实例）。
   * 每键最多 MAX 个实例常驻；都被占用时新建「临时实例」（用完即弃，不干扰池内状态）。
   */
  private static final class SpiderPool {
    static final int MAX = 2;
    static final java.util.concurrent.ConcurrentHashMap<String, Entry> MAP =
        new java.util.concurrent.ConcurrentHashMap<String, Entry>();

    static final class Entry {
      final java.util.ArrayDeque<Object> free = new java.util.ArrayDeque<Object>();
      int made;
    }

    static String keyOf(String cls, String[] rest) {
      return cls + '\u0001' + (rest.length > 0 && rest[0] != null ? rest[0] : "");
    }

    static Object acquire(Env env, String cls, String[] rest) throws Exception {
      String key = keyOf(cls, rest);
      Entry e = MAP.get(key);
      if (e == null) {
        // 键里含 ext（可能带网盘 token，会随绑定刷新而变化）→ 给池一个上限，防长期运行积累死实例
        if (MAP.size() > 64) MAP.clear();
        Entry created = new Entry();
        Entry prev = MAP.putIfAbsent(key, created);
        e = prev != null ? prev : created;
      }
      synchronized (e) {
        if (!e.free.isEmpty()) return e.free.pollLast();
        if (e.made < MAX) {
          e.made++;
          return newSpider(env, cls, rest);
        }
      }
      return newSpider(env, cls, rest); // 池内都在忙 → 临时实例（不进池）
    }

    static void release(String cls, String[] rest, Object sp, boolean broken) {
      Entry e = MAP.get(keyOf(cls, rest));
      if (e == null) return;
      synchronized (e) {
        if (broken) {
          e.made = Math.max(0, e.made - 1); // 丢弃并允许下次重建
          return;
        }
        if (e.free.size() < MAX) e.free.addLast(sp);
      }
    }
  }

  /**
   * 新建蜘蛛实例（类加载 + new + init(Context,ext) + initApi）——**一次性路径与实例池共用**。
   * 顺序契约：宿主上下文（setupEnv）必须早于本方法。
   */
  private static Object newSpider(Env env, String cls, String[] rest) throws Exception {
    Class<?> c = Class.forName(cls, true, env.cl);
    Object sp = c.getDeclaredConstructor().newInstance();

    // init(Context, ext)
    try {
      c.getMethod("init", android.content.Context.class, String.class)
          .invoke(sp, env.app, rest.length > 0 ? rest[0] : "");
    } catch (NoSuchMethodException e) {
      try { c.getMethod("init", android.content.Context.class).invoke(sp, env.app); }
      catch (NoSuchMethodException ig) { }
    }

    // initApi(SpiderApi)
    try {
      Class<?> apiCls = Class.forName("com.github.catvod.crawler.SpiderApi", true, env.cl);
      Object api = apiCls.getDeclaredConstructor().newInstance();
      c.getMethod("initApi", apiCls).invoke(sp, api);
    } catch (ClassNotFoundException ig) {
    } catch (NoSuchMethodException ig) {
    } catch (Throwable ig) {
      System.err.println("[SpiderRunner.initApi] " + ig);
    }
    return sp;
  }

  private static Throwable unwrap(Throwable t) {
    Throwable c = t;
    while (c.getCause() != null) c = c.getCause();
    return c;
  }

  /** 运行环境（classloader + Application 单例 + 初始化后的 Init 钩子状态）。 */
  private static class Env {
    final URLClassLoader cl;
    final android.app.Application app;
    Env(URLClassLoader cl, android.app.Application app) { this.cl = cl; this.app = app; }
  }

  /**
   * 一次性环境初始化（classloader + 宿主上下文 + Init/InitOrigin/yq 开关）。
   * ★ 顺序契约：宿主上下文必须早于「加载/实例化蜘蛛类」——蜘蛛构造函数里
   *   就可能用到宿主 Context（Guard 系 BaseSpiderGuard.<init>() → Init.context()）。
   */
  private static Env setupEnv(String[] jars) throws Exception {
    android.security.keystore.DesktopKeyStoreProvider.install();
    // BouncyCastle provider（AES/CBC/PKCS7Padding，ft y 蜘蛛依赖）
    try {
      java.security.Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider());
    } catch (Throwable ig) {
      System.err.println("[SpiderRunner] BouncyCastle provider unavailable: " + ig);
    }

    List<URL> urls = new ArrayList<URL>();
    // ★ 2026-09-26 原生桥（ARM .so，见 resources/jvm/native-bridge/）：
    //   jar 内带 ARM/AArch64 .so 时，先把「native 方法改写产物目录」占位在 URL **最前**
    //   （类加载顺序覆盖原类），再建 URLClassLoader，随后用**同一个 cl** 反射调用桥门面生成改写类。
    //   必须同一个 cl：改写类引用的 NativeBridge 与桥的静态状态（unidbg 会话）要落在同一个类上，
    //   否则状态为空、所有 native 调用都会失败。
    //   ★★ 2026-09-27 修正（实测「第一次进源必空」）：URLClassLoader 对**目录 URL** 的查找
    //   **不是**每次直读磁盘（早期注释说反了）——空目录被查过一次后列表会缓存，
    //   之后写进去的 .class 在同一 JVM 内**查不到**。因此顺序必须是：
    //   先用临时 loader 做改写 → 再建正式 loader（含改写目录）。见下方实现。
    //   目录要先 mkdirs —— File.toURI() 只有对已存在目录才会带结尾斜杠（否则 URL 指向父目录）。
    File nativeJar = nativeJarOf(jars);
    File dynamicJar = nativeJar == null ? dynamicNativeJarOf(jars) : null;
    File patchedDir = null;
    if (nativeJar != null) {
      String patchRoot = System.getProperty("tvbox.native.patch");
      if (patchRoot != null && !patchRoot.trim().isEmpty()) {
        patchedDir = new File(patchRoot.trim(), nativeJar.getName() + ".patched");
        try {
          if (!patchedDir.exists() && !patchedDir.mkdirs()) throw new java.io.IOException("mkdirs failed: " + patchedDir);
          // ★★ 2026-09-27（实测「第一次进源必空」修复，勿回退）★★
          //   改写产物必须**先写好、再建正式 URLClassLoader**：反序（先建 loader 再写）时，
          //   patch 期间用 loader 解析 jar 里的类会让 URLClassLoader 对「目录 URL」缓存一次
          //   （当时还是空目录的）列表 → 改写类「写好了却加载不到」→ 同一 JVM 的首次调用
          //   落到原始 DexNative（`System.load(ARM .so)` → UnsatisfiedLinkError → 该源空结果），
          //   第二次调用（新进程，产物已在盘上）才正常 —— 用户侧就是「第一次进源必空」。
          //   这里先用「临时 loader（只含蜘蛛 jar）」做改写，随后再建正式 loader 并把
          //   正式 loader 重新 arm 给桥（见下方 armNativeBridge）。
          URLClassLoader patchLoader = new URLClassLoader(
              new URL[]{nativeJar.toURI().toURL()}, SpiderHost.class.getClassLoader());
          try {
            prepareNativeBridge(nativeJar, patchedDir, patchLoader);
          } finally {
            try { patchLoader.close(); } catch (Throwable ignored) { }
          }
        } catch (Throwable t) {
          System.err.println("[native-bridge] 准备失败，按无原生桥降级: " + t);
          // ★ 关键：只有在「状态戳缺失/不属于当前 jar」时才清产物 —— 戳存在且 jar 匹配说明
          //   这是**别的进程**刚写好的有效产物（同一只 jar 会被池并行拉起多个 JVM）；
          //   失败方一律清掉会让桥在整机永久失效（真机实测踩过）。陈旧戳由桥自己按状态键重写。
          if (stampMatchesJar(patchedDir, nativeJar)) {
            System.err.println("[native-bridge] 保留其它进程已写好的改写产物（状态戳匹配当前 jar）");
          } else {
            clearDirQuietly(patchedDir);
            deleteQuietly(new File(patchedDir.getAbsolutePath() + ".ok"));
            patchedDir = null;
          }
        }
      }
    }
    if (dynamicJar != null) {
      try {
        Class<?> facade = Class.forName("com.winbox.nativebridge.NativeBridgeMain");
        String workRoot = System.getProperty("tvbox.native.work", "");
        if (!workRoot.trim().isEmpty()) {
          URLClassLoader resolver = new URLClassLoader(
              new URL[]{dynamicJar.toURI().toURL()}, SpiderHost.class.getClassLoader());
          try {
            patchedDir = (File) facade.getMethod("prepareDynamic", File.class, File.class, ClassLoader.class)
                .invoke(null, dynamicJar, new File(workRoot, dynamicJar.getName()), resolver);
          } finally { resolver.close(); }
          if (patchedDir != null) System.err.println("[native-bridge] 动态原生库桥接已启用（库在运行时装载）");
        }
      } catch (Throwable t) {
        System.err.println("[native-bridge] 动态原生库桥接准备失败: " + unwrap(t));
      }
    }
    if (patchedDir != null) {
      urls.add(patchedDir.toURI().toURL());
    }
    for (String j : jars) urls.add(new File(j).toURI().toURL());
    URLClassLoader cl = new URLClassLoader(urls.toArray(new URL[0]), SpiderHost.class.getClassLoader());
    // 反射/ServiceLoader/蜘蛛后台线程都需要看到私有 jar，而非仅 stubs/libs。
    Thread.currentThread().setContextClassLoader(cl);
    if (nativeJar != null && patchedDir != null) {
      // 正式 loader 建好后再 arm 一次：桥的惰性初始化/类工厂要用**最终**加载器解析壳类
      armNativeBridge(nativeJar, cl);
    }
    if (dynamicJar != null && patchedDir != null) {
      Class<?> facade = Class.forName("com.winbox.nativebridge.NativeBridgeMain");
      facade.getMethod("arm", File.class, File.class, ClassLoader.class).invoke(null, dynamicJar,
          new File(System.getProperty("tvbox.native.work"), dynamicJar.getName()), cl);
    }

    // 沙箱数据根（防蜘蛛清理缓存目录）
    try {
      String base = System.getProperty("tvbox.spiderCacheDir");
      if (base != null && base.trim().length() > 0) {
        android.content.Context.setBaseDir(new File(base.trim()));
      }
    } catch (Throwable ig) { }

    // Application 单例（ActivityThread.currentApplication() 反查宿主）
    android.app.Application app = new android.app.Application();
    app.setClassLoader(cl);
    try { android.app.ActivityThread.setCurrentApplication(app); } catch (Throwable ig) { }

    // Init 钩子（须在加载蜘蛛类之前）
    try {
      Class<?> ic = Class.forName("com.github.catvod.spider.Init", true, cl);
      try { ic.getMethod("init", android.content.Context.class).invoke(null, app); }
      catch (Throwable ig) {
        Throwable cause = unwrap(ig);
        System.err.println("[Init] " + cause);
        StackTraceElement[] trace = cause.getStackTrace();
        for (int i = 0; i < Math.min(6, trace.length); i++) System.err.println("    at " + trace[i]);
      }
    } catch (ClassNotFoundException ig) { }
    try {
      Class<?> ic = Class.forName("com.github.catvod.spider.Init", true, cl);
      Object ctx = ic.getMethod("context").invoke(null);
      if (ctx == null) System.err.println("[SpiderRunner] 警告: Init.context() 为 null —— Init.init(Context) 未生效");
    } catch (Throwable ig) { /* 老版本无 context() 正常 */ }

    // InitOrigin 单例（ft y 真实实现宿主上下文）
    try {
      Class<?> ic = Class.forName("com.github.catvod.spider.InitOrigin", true, cl);
      try { ic.getMethod("init", android.content.Context.class).invoke(null, app); }
      catch (NoSuchMethodException ig) { }
      catch (Throwable ig) { System.err.println("[InitOrigin.init] " + ig); }
    } catch (ClassNotFoundException ig) { }

    // ★★ 2026-11-13（实测根因修复，勿回退）★★
    //   fty 系加固壳的四个加解密站点全部由 `merge.uA.yq`（public static boolean，默认 false）门控：
    //     ME.B (String)   @26  yq? HideUtils.encrypt      : InitOrigin.i 反射 encrypt
    //     ME.Gc(int[])    @13  yq? HideUtils.calcResult   : InitOrigin.i 反射 calcResult
    //     ME.KJ (String)  @26  yq? HideUtils.decrypt      : InitOrigin.i 反射 decrypt
    //     ME.n  (String)  @13  yq? HideUtils.tingMd5      : InitOrigin.i 反射 native_ting_md5
    //   `InitOrigin.i` 是 public static Class<?>，全 jar 只有 `InitOrigin.setClass` 一处 putstatic，
    //   而 setClass **零调用者** → i 恒为 null → 四个站点的反射端 NPE，且异常被吞成 ""
    //   → playerContent 拿不到解密后的 sToken → 播放永久卡住 / 解析失败。
    //   历史写法翻的是 `merge.cn.yq`，那是 `public static final merge.cn yq`（Runnable 单例），
    //   不是 boolean，`getType()==boolean.class` 恒假 → 静默 no-op（本行就是那个 bug）。
    //   这里翻对的字段；fty 之外（wex 系没有 merge.*）ClassNotFoundException 静默跳过。
    try {
      Class<?> uaCls = Class.forName("com.github.catvod.spider.merge.uA", true, cl);
      java.lang.reflect.Field yqF = uaCls.getField("yq");
      if (yqF.getType() == boolean.class) {
        yqF.setBoolean(null, true);
        System.err.println("[ShellShim] 已强制 com.github.catvod.spider.merge.uA.yq=true（B/Gc/KJ/n 改走 HideUtils 分支）");
      } else {
        System.err.println("[ShellShim] merge.uA.yq 不是 boolean（" + yqF.getType().getName() + "），跳过");
      }
    } catch (ClassNotFoundException ig) {
      // 非 fty 系载荷（wex 等），正常
    } catch (Throwable ig) {
      System.err.println("[ShellShim] 设置 merge.uA.yq 失败: " + ig);
    }

    // ★ 同一门控的另一半：`yq=true` 只是把四个站点从「反射 InitOrigin.i」切到 HideUtils，
    //   但要走通仍需 HideUtils 在类路径上。壳 jar 里不带 HideUtils（它由 native 侧提供），
    //   桌面版由 stubs.jar 的纯 Java 版补齐（encrypt/decrypt/calcResult/tingMd5，其中
    //   tingMd5 对应第 4 个站点的 native_ting_md5）。探测一下，缺失时明确报出来，
    //   避免再出现「NPE 被吞成空串、日志零线索」的静默失败。
    try {
      Class<?> hu = Class.forName("com.github.catvod.spider.HideUtils", true, cl);
      String[] need = {"encrypt", "decrypt", "calcResult", "tingMd5"};
      Class<?>[] sig = {String.class, String.class, int[].class, String.class};
      StringBuilder miss = new StringBuilder();
      for (int i = 0; i < need.length; i++) {
        try { hu.getDeclaredMethod(need[i], sig[i]); }
        catch (NoSuchMethodException e) { if (miss.length() > 0) miss.append(','); miss.append(need[i]); }
      }
      if (miss.length() > 0) System.err.println("[ShellShim] HideUtils 缺方法: " + miss);
    } catch (ClassNotFoundException ig) {
      System.err.println("[ShellShim] 类路径上没有 HideUtils —— merge.uA.yq=true 后四个站点会 NoClassDefFoundError");
    } catch (Throwable ig) { }

    // ★★ 2026-11-13（实测根因修复，勿回退）★★
    //   wex / AiNew* 系载荷的站点基址不走配置里的 api，而是 init() 里：
    //       merge.y0.e.J("wogg")                     → 读 <spiderCacheDir>/files/AiWex/siteconfig 的域名列表
    //       merge.y0.e.A(list, headers, 6000, sel)   → **并发竞速，谁先返回谁当选**
    //       i.a → putfield a:Ljava/lang/String       → 基址
    //   `A(...)` 只看「有没有响应」，**完全不校验 HTTP 状态码**。于是：
    //       https://www.wogg.net/        → 403，252ms（最快）→ 当选 → 下面按 403 页面解析
    //       https://woggpan.888484.xyz/  → 200，529KB，含 module-item（唯一可用）→ 落选
    //   homeContent 无 try/catch，选择器
    //       div.module-list.module-lines-list > div  → .module-item
    //   在 403 页面上匹配 0 条 → `list:[]`（7 个 class 是写死的，故只见分类不见内容）。
    //   桌面端实测：把 wogg 收敛成唯一可用域名后 len 11024 → 42518、items 0 → 120。
    //   注意 siteconfig 会被载荷自行用远端配置覆写（连只读属性都清），uA.yq 那条修复
    //   碰不到这里，所以修复必须落在「载荷读取它之前」：预检每个候选域名，只保留
    //   返回 2xx 且页面里确实有列表容器的，写回 siteconfig。全部不可用时原样不动。
    sanitizeVendorHosts(app);

    return new Env(cl, app);
  }

  /**
   * 把 `<spiderCacheDir>/files/AiWex/siteconfig` 里各厂商的域名列表收敛成**实测可用**的子集。
   *
   * 为什么必须做：载荷的基址选择是纯竞速（见上），一个 403 的旧域名只要响应够快就会
   * 盖掉健康域名，导致「分类有、内容空」或「能显示、播不了」。竞速本身在载荷里，
   * 桌面端改不了；能改的是喂给它的候选集。
   *
   * 判定：并发 HEAD/GET 每个域名，2 秒超时；2xx 且正文里出现 `module-item`
   * （首页列表容器）/ `module-item-pic` / `voddetail` 任一，才算可用。
   * 保底：若某厂商一个都不过，则该厂商的列表原样保留（绝不把候选清空 → 悬空指针）。
   */
  private static void sanitizeVendorHosts(android.content.Context app) {
    StringBuilder trace = new StringBuilder();
    try {
      // 基址真源就是 setupEnv 上面用的那个系统属性（-Dtvbox.spiderCacheDir），
      // 不依赖 Context.getBaseDir 是否存在（桌面桩里没有 getter）。
      String dir = System.getProperty("tvbox.spiderCacheDir");
      if (dir == null || dir.trim().isEmpty()) return;
      File base = new File(dir.trim());

      File cfg = new File(new File(base, "files/AiWex"), "siteconfig");
      if (!cfg.isFile() || cfg.length() <= 0 || cfg.length() > 512 * 1024) return;

      String text = new String(java.nio.file.Files.readAllBytes(cfg.toPath()),
          java.nio.charset.StandardCharsets.UTF_8).trim();
      if (text.isEmpty() || text.charAt(0) != '{') return;

      org.json.JSONObject root = new org.json.JSONObject(text);
      java.util.Iterator<String> keys = root.keys();
      List<String> names = new ArrayList<String>();
      while (keys.hasNext()) names.add(keys.next());

      // 收集所有需要探测的 (vendor, 候选列表)，**跨厂商一次性并发**。
      // 这里绝不能按厂商串行：每次 setupEnv 的耗时直接算在 home/detail 的调用超时里，
      // 串行 × N 个厂商会把调用拖过超时（实测：16:11 home 直接返回 error，无结果）。
      List<String> vendors = new ArrayList<String>();
      List<List<String>> groups = new ArrayList<List<String>>();
      List<String> all = new ArrayList<String>();
      for (String vendor : names) {
        org.json.JSONArray arr = root.optJSONArray(vendor);
        if (arr == null || arr.length() <= 1) continue;   // 单域名无从优选，跳过
        List<String> cands = new ArrayList<String>();
        for (int i = 0; i < arr.length(); i++) {
          String u = arr.optString(i, "").trim();
          if (!u.isEmpty()) cands.add(u);
        }
        if (cands.size() <= 1) continue;
        vendors.add(vendor);
        groups.add(cands);
        all.addAll(cands);
      }
      if (vendors.isEmpty()) return;

      // 预算 2.5s 总闸：探测只是"锦上添花"，宁可本轮不收敛，也不能拖慢/拖死载荷初始化。
      long t0 = System.currentTimeMillis();
      Map<String, Boolean> verdict = probeHosts(all, 2500);
      long used = System.currentTimeMillis() - t0;
      trace.append("cands=").append(all.size())
          .append(" probed=").append(verdict.size())
          .append(" used=").append(used).append("ms")
          .append(" proxy=").append(proxyDesc()).append('\n');
      System.err.println("[HostFix] cands=" + all.size() + " probed=" + verdict.size()
          + " used=" + used + "ms proxy=" + proxyDesc());
      for (String u : all) {
        Boolean v = verdict.get(u);
        String line = (v == null ? "SKIP " : (v.booleanValue() ? "OK   " : "DEAD ")) + u;
        trace.append(line).append('\n');
        System.err.println("[HostFix]   " + line);
      }

      int changed = 0;
      StringBuilder log = new StringBuilder();
      for (int gi = 0; gi < vendors.size(); gi++) {
        List<String> cands = groups.get(gi);
        List<String> ok = new ArrayList<String>();
        for (String u : cands) if (Boolean.TRUE.equals(verdict.get(u))) ok.add(u);
        if (ok.isEmpty() || ok.size() == cands.size()) continue;

        org.json.JSONArray kept = new org.json.JSONArray();
        for (String u : ok) kept.put(u);
        root.put(vendors.get(gi), kept);
        changed++;
        log.append(' ').append(vendors.get(gi)).append(": ")
            .append(cands.size()).append("->").append(ok.size());
      }

      if (changed == 0) { dumpTrace(base, trace); return; }
      java.nio.file.Files.write(cfg.toPath(),
          root.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
      System.err.println("[HostFix] siteconfig 基址预检收敛" + changed + "个厂商:" + log);
      dumpTrace(base, trace.append(" => changed=").append(changed).append(log));
    } catch (Throwable ig) {
      System.err.println("[HostFix] siteconfig 预检跳过: " + ig);
      java.io.StringWriter sw = new java.io.StringWriter();
      ig.printStackTrace(new java.io.PrintWriter(sw));
      System.err.println(sw.toString());
      try {
        String dir = System.getProperty("tvbox.spiderCacheDir");
        if (dir != null) dumpTrace(new File(dir.trim()),
            trace.append(" EX ").append(ig).append('\n').append(sw.toString()));
      } catch (Throwable ig2) { }
    }
  }

  /**
   * 探针/宿主两条链路的 stderr 都可能被上层截断（App 侧只保留最后 60 行且不入日志），
   * 因此把判定明细落盘，位置固定在 spiderCacheDir 下，便于事后核对。
   */
  private static void dumpTrace(File base, CharSequence text) {
    try {
      File out = new File(base, "hostfix.trace");
      java.nio.file.Files.write(out.toPath(),
          text.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
    } catch (Throwable ig) { }
  }

  /** 当前生效的代理描述，用于日志里对齐"探测和载荷是否同路"。 */
  private static String proxyDesc() {
    String ph = System.getProperty("https.proxyHost", System.getProperty("http.proxyHost"));
    String pp = System.getProperty("https.proxyPort", System.getProperty("http.proxyPort"));
    return (ph == null || ph.isEmpty()) ? "none" : (ph + ":" + pp);
  }

  /** 并发探测候选基址，返回 url → 是否可用。总耗时受 budgetMs 硬性约束。 */
  private static Map<String, Boolean> probeHosts(List<String> cands, long budgetMs) {
    final Map<String, Boolean> verdict = new HashMap<String, Boolean>();
    if (cands.isEmpty()) return verdict;
    ExecutorService pool = Executors.newFixedThreadPool(Math.min(12, cands.size()));
    final long deadline = System.currentTimeMillis() + budgetMs;
    try {
      Map<String, Future<Boolean>> fs = new LinkedHashMap<String, Future<Boolean>>();
      for (final String u : cands) {
        fs.put(u, pool.submit(new Callable<Boolean>() {
          public Boolean call() { return Boolean.valueOf(hostAlive(u)); }
        }));
      }
      for (Map.Entry<String, Future<Boolean>> e : fs.entrySet()) {
        long left = deadline - System.currentTimeMillis();
        Boolean v;
        try {
          v = e.getValue().get(Math.max(1, left), TimeUnit.MILLISECONDS);
        } catch (Throwable ig) {
          v = null;      // 超时/异常 → 与"未探测"同义，不做判定（保守：保留候选）
        }
        if (v != null) verdict.put(e.getKey(), v);
      }
    } finally {
      pool.shutdownNow();
    }
    return verdict;
  }

  /** 2xx 且正文含首页列表容器标记 → 该基址能真正解析出条目。 */
  private static boolean hostAlive(String url) {
    java.net.HttpURLConnection c = null;
    try {
      java.net.URL u = new URL(url);
      // 必须和载荷同路：载荷走 App 注入的 -Dhttp(s).proxyHost/Port（Dart 侧代理桥），
      // HttpURLConnection 默认只认 http.proxyHost，HTTPS 得显式给 Proxy，
      // 否则探测走直连、载荷走代理，两边结论相反（www.wogg.net 直连 200 / 代理 403）。
      java.net.Proxy proxy = java.net.Proxy.NO_PROXY;
      String ph = System.getProperty("https.proxyHost", System.getProperty("http.proxyHost"));
      String pp = System.getProperty("https.proxyPort", System.getProperty("http.proxyPort"));
      if (ph != null && !ph.isEmpty() && pp != null && !pp.isEmpty()) {
        try {
          proxy = new java.net.Proxy(java.net.Proxy.Type.HTTP,
              new java.net.InetSocketAddress(ph, Integer.parseInt(pp.trim())));
        } catch (Throwable ig) { proxy = java.net.Proxy.NO_PROXY; }
      }
      c = (java.net.HttpURLConnection) u.openConnection(proxy);
      c.setConnectTimeout(1200);
      c.setReadTimeout(1600);
      c.setInstanceFollowRedirects(true);
      c.setRequestProperty("User-Agent",
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
              + "Chrome/140.0.0.0 Safari/537.36");
      c.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*;q=0.8");
      int code = c.getResponseCode();
      if (code < 200 || code >= 300) return false;
      java.io.InputStream in = c.getInputStream();
      try {
        java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream(1 << 16);
        byte[] buf = new byte[8192];
        int n, total = 0;
        while ((n = in.read(buf)) > 0) {
          bos.write(buf, 0, n);
          total += n;
          if (total > 512 * 1024) break;      // 首页足够判断，不必读全
        }
        String html = new String(bos.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
        return html.contains("module-item") || html.contains("voddetail")
            || html.contains("module-lines-list");
      } finally {
        try { in.close(); } catch (Throwable ig) { }
      }
    } catch (Throwable ig) {
      return false;
    } finally {
      if (c != null) try { c.disconnect(); } catch (Throwable ig) { }
    }
  }

  /**
   * 正式加载器建好后把桥的整套绑定**重绑**到它（`NativeBridgeMain.rebind`）。
   * 为什么必须（实测，勿回退）：改写产物「先写后建 loader」⇒ prepare 拿到的是临时加载器，
   * 而 init 把 resolver 捕获进壳类工厂 / EnvJni host loader / `Context.getClassLoader()`；
   * 不重绑时原生侧 `Context.getClassLoader()` 与 `Init.classLoader()` 不是同一个加载器，
   * jmethodID 对不上 → `Init->classLoader()` 仿真异常 → getLoader 崩 → 该源全空。
   * 桥不在/属性缺失 → 静默跳过（该 jar 按无桥方式运行）。
   */
  private static void armNativeBridge(File jar, ClassLoader cl) {
    try {
      Class<?> facade = Class.forName("com.winbox.nativebridge.NativeBridgeMain", true, cl);
      String workRoot = System.getProperty("tvbox.native.work");
      if (workRoot == null || workRoot.trim().isEmpty()) return;
      File workDir = new File(workRoot.trim(), jar.getName());
      facade.getMethod("rebind", File.class, File.class, ClassLoader.class).invoke(null, jar, workDir, cl);
    } catch (Throwable t) {
      System.err.println("[native-bridge] 正式加载器重绑失败（按已初始化状态继续）: " + t);
    }
  }

  /**
   * 反射调用原生桥门面（com.winbox.nativebridge.NativeBridgeMain）生成 native 方法改写类。
   * 桥实现与原生运行时（unidbg）都在 cl 的 URL 里；缺任何一样都静默跳过（该 jar 按无桥方式运行）。
   * @param jar        含 ARM .so 的蜘蛛 jar（转换产物）
   * @param patchedDir 改写产物目录（**正式加载器须在改写完成后创建**，见 setupEnv 注释）
   */
  private static void prepareNativeBridge(File jar, File patchedDir, ClassLoader cl) throws Exception {
    Class<?> facade;
    try {
      facade = Class.forName("com.winbox.nativebridge.NativeBridgeMain", true, cl);
    } catch (ClassNotFoundException e) {
      return; // 未安装原生运行时 → 原样运行
    }
    String workRoot = System.getProperty("tvbox.native.work");
    if (workRoot == null || workRoot.trim().isEmpty()) return;
    File workDir = new File(workRoot.trim(), jar.getName());
    if (!workDir.exists() && !workDir.mkdirs()) throw new java.io.IOException("mkdirs failed: " + workDir);
    Object report = facade
        .getMethod("prepare", File.class, File.class, File.class, ClassLoader.class)
        .invoke(null, jar, workDir, patchedDir, cl);
    if (report != null) System.err.println("[SpiderRunner] " + report);
  }

  /**
   * 改写产物的状态戳（`<outDir>.ok`，落在 outDir 之外）里是否含当前 jar 的体积/时间。
   * 状态键形如 `<BRIDGE_REV>/<jarLength>/<jarMtime>/<soName>/<soSize>/<planHash>` —— 只比对 jar 段。
   */
  private static boolean stampMatchesJar(File outDir, File jar) {
    try {
      File stamp = new File(outDir.getAbsolutePath() + ".ok");
      if (!stamp.isFile()) return false;
      String s = new String(java.nio.file.Files.readAllBytes(stamp.toPath()), java.nio.charset.StandardCharsets.UTF_8);
      return s.contains("/" + jar.length() + "/" + jar.lastModified() + "/");
    } catch (Throwable t) {
      return false;
    }
  }

  /** 找第一个「内含 ARM/AArch64 .so」的 jar（只读 zip 条目头 20 字节判 ELF，不解压整包） */
  private static File nativeJarOf(String[] jars) {
    for (String j : jars) {
      File f = new File(j);
      if (!f.isFile()) continue;
      try (java.util.jar.JarFile jf = new java.util.jar.JarFile(f)) {
        java.util.Enumeration<java.util.jar.JarEntry> it = jf.entries();
        while (it.hasMoreElements()) {
          java.util.jar.JarEntry e = it.nextElement();
          if (e.isDirectory() || !e.getName().endsWith(".so")) continue;
          byte[] head = new byte[20];
          try (java.io.InputStream is = jf.getInputStream(e)) {
            int n = 0;
            while (n < head.length) {
              int r = is.read(head, n, head.length - n);
              if (r < 0) break;
              n += r;
            }
          }
          if (isArmElf(head)) return f;
        }
      } catch (Throwable ignore) { /* 非 zip / 读失败 → 跳过 */ }
    }
    return null;
  }

  /** JARs whose ARM library is downloaded by Java rather than embedded in assets. */
  private static File dynamicNativeJarOf(String[] jars) {
    // Use ASM reflectively; ordinary sources do not require the native runtime on their classpath.
    try {
      Class<?> bridge = Class.forName("com.winbox.nativebridge.NativeBridgeMain");
      Method detector = bridge.getMethod("hasNativeMethods", File.class);
      for (String j : jars) {
        File f = new File(j);
        if (f.isFile() && Boolean.TRUE.equals(detector.invoke(null, f))) return f;
      }
    } catch (Throwable ignored) { }
    return null;
  }

  /** ELF 头：AArch64(0xb7, ELF64) 或 ARM32(0x28, ELF32) */
  private static boolean isArmElf(byte[] d) {
    if (d.length < 20 || d[0] != 0x7f || d[1] != 'E' || d[2] != 'L' || d[3] != 'F') return false;
    int machine = (d[18] & 0xff) | ((d[19] & 0xff) << 8);
    return (d[4] == 2 && machine == 0xb7) || (d[4] == 1 && machine == 0x28);
  }

  /** 清空目录内容（保留目录），失败只打日志 */
  private static void clearDirQuietly(File dir) {
    try {
      File[] kids = dir.listFiles();
      if (kids == null) return;
      for (File k : kids) {
        if (k.isDirectory()) clearDirQuietly(k);
        if (!k.delete()) System.err.println("[native-bridge] 删除失败: " + k);
      }
    } catch (Throwable t) {
      System.err.println("[native-bridge] 清目录失败: " + t);
    }
  }

  private static void deleteQuietly(File f) {
    try {
      if (f.exists() && !f.delete()) System.err.println("[native-bridge] 删除失败: " + f);
    } catch (Throwable t) {
      System.err.println("[native-bridge] 删除失败: " + t);
    }
  }

  /**
   * 单次请求分发（一次性路径）：new 蜘蛛实例 → init → initApi → 调用方法。
   * 常驻路径走 SpiderPool（实例复用，见 serve）。
   * @param reason 失败原因容器（一次性路径传 null；serve 的失败由信封承载）
   */
  private static String dispatch(Env env, String cls, String method, String[] rest, StringBuilder reason) throws Exception {
    Object sp = newSpider(env, cls, rest);
    String result = dispatchMethod(sp, method, rest);
    return result == null ? "" : result;
  }

  /**
   * 加固壳的「网盘登录闸门」绕过。
   *
   * fty 系壳（WoGGGuard / Pan）的 `Cloud_quark.playerContent` 一进来先判断
   * 「这次的线路名是否与我上次记录的相同」：不同就调 `N0.Gd()` 校验登录态。
   * `N0.Gd()` 内部是 `SystemClock.sleep` 轮询 —— 它等的是**手机 App 扫码授权**，
   * 桌面端没有这条授权链，于是主线程永久 sleep（实测 jstack 11 分钟不动）。
   *
   * `playerContent` 开头的门控（反编译确认，字节码 0-24）：
   *   0: getstatic Cloud_quark.tF:Z   → 3: ifne 56   ← tF 为 true 直接跳过校验
   *   6: N0.F5 → isEmpty?             → 15: ifne 56  ← 账号为空也跳过
   *  18: N0.Gd()                       ← 否则调登录校验（sleep 轮询）
   *
   * 所以真正管用的是 **`Cloud_quark.tF`（public static boolean）**，把它置 true，
   * 整段校验连读都不用读。顺带把线路名 `Cloud_quark.N` / `QB.G4` 对齐到本次 flag，
   * 免得后面 80-103 那段「线路变了」又触发一次 `Gd()`。
   *
   * 写不进去（别的壳、字段被改名）就算了：该方法所有异常静默，绝不影响正常调用。
   */
  private static void skipDriveLoginGuard(Object sp, String flag) {
    try {
      // ★ 关键：真实实现（WoGG）与 `Cloud_quark` 在**不同的 ClassLoader** 里 ——
      //   WoGG 来自 converted jar，Cloud_quark 来自 `-Dtvbox.shellShimClasses` 指向的
      //   payload jar（由 shell-shim 的 DexNative 自己建 URLClassLoader）。
      //   只用 sp.getClass().getClassLoader() 会 ClassNotFound（实测静默失败、tF 从未置位）。
      //   所以这里把候选加载器都试一遍：sp 自己的 → 线程上下文 → DexNative.loader（反射取）。
      java.util.List<ClassLoader> loaders = new ArrayList<ClassLoader>();
      try { loaders.add(sp.getClass().getClassLoader()); } catch (Throwable ig) { }
      try {
        ClassLoader tc = Thread.currentThread().getContextClassLoader();
        if (tc != null) loaders.add(tc);
      } catch (Throwable ig) { }
      try {
        Class<?> dn = Class.forName("com.github.catvod.spider.DexNative", false,
            SpiderHost.class.getClassLoader());
        java.lang.reflect.Field lf = dn.getDeclaredField("loader");
        lf.setAccessible(true);
        Object l = lf.get(null);
        if (l instanceof ClassLoader) loaders.add((ClassLoader) l);
      } catch (Throwable ig) { }

      boolean flipped = false;
      // ① 主开关：Cloud_quark.tF = true
      String[] guardClasses = {"com.github.catvod.spider.Cloud_quark", "com.github.catvod.spider.Cloud_uc", "com.github.catvod.spider.Cloud_ucpan", "com.github.catvod.spider.Cloud_baidu", "com.github.catvod.spider.Cloud_115", "com.github.catvod.spider.Cloud_ali", "com.github.catvod.spider.Cloud_thunder", "com.github.catvod.spider.Cloud_guangya"};
      for (String clsName : guardClasses) {
      for (ClassLoader cl : loaders) {
        if (cl == null) continue;
        try {
          Class<?> cq = Class.forName(clsName, true, cl);
          java.lang.reflect.Field f = cq.getDeclaredField("tF");
          if (f.getType() != boolean.class) continue;
          f.setAccessible(true);
          f.setBoolean(null, true);
          if (f.getBoolean(null)) { flipped = true; break; }
        } catch (Throwable ig) {
          // 该加载器看不到 Cloud_quark（不是这个壳 / 不是 quark 系）—— 换下一个
        }
      }
      }
      if (flag == null || flag.isEmpty()) {
        if (flipped) System.err.println("[LoginGuard] 已置 tF=true（跳过网盘登录校验）");
        return;
      }
      // ② 线路名对齐：Cloud_quark.N / merge.QB.G4（同样跨加载器试）
      String[] owners = {
          "com.github.catvod.spider.Cloud_quark",
          "com.github.catvod.spider.merge.QB",
        "com.github.catvod.spider.Cloud_uc",
        "com.github.catvod.spider.Cloud_ucpan",
        "com.github.catvod.spider.Cloud_baidu",
      };
      String[] fields = {"N", "G4", "N", "N", "N""};
      for (int i = 0; i < owners.length; i++) {
        for (ClassLoader cl : loaders) {
          if (cl == null) continue;
          try {
            Class<?> c = Class.forName(owners[i], true, cl);
            java.lang.reflect.Field f = c.getDeclaredField(fields[i]);
            if (f.getType() != String.class) continue;
            f.setAccessible(true);
            f.set(null, flag);
            break;
          } catch (Throwable ig) {
            // 换下一个加载器
          }
        }
      }
      if (flipped) System.err.println("[LoginGuard] 已跳过网盘登录校验 flag=" + flag);
    } catch (Throwable ig) {
      // 任何反射问题都不影响正常取链
    }
  }

  /** 方法分发（一次性/常驻共用）。rest[0]=ext(init 已消费)，real args 从 rest[1:] 取值。 */
  private static String dispatchMethod(Object sp, String method, String[] rest) throws Exception {
    String[] r = rest.length > 0 ? Arrays.copyOfRange(rest, 1, rest.length) : new String[0];
    if ("homeContent".equals(method)) {
      return (String) sp.getClass().getMethod("homeContent", boolean.class).invoke(sp, true);
    }
    if ("homeVideoContent".equals(method)) {
      return (String) sp.getClass().getMethod("homeVideoContent").invoke(sp);
    }
    if ("categoryContent".equals(method)) {
      HashMap<String, String> extend = new HashMap<String, String>();
      if (r.length > 2 && !r[2].isEmpty()) {
        for (String kv : r[2].split("&")) {
          int eq = kv.indexOf('=');
          if (eq > 0) {
            String k = kv.substring(0, eq);
            String v = kv.substring(eq + 1);
            try { k = java.net.URLDecoder.decode(k, "UTF-8"); } catch (Throwable ig) { }
            try { v = java.net.URLDecoder.decode(v, "UTF-8"); } catch (Throwable ig) { }
            extend.put(k, v);
          }
        }
      }
      return (String) sp.getClass().getMethod("categoryContent", String.class, String.class, boolean.class, HashMap.class)
          .invoke(sp, r.length > 0 ? r[0] : "", r.length > 1 ? r[1] : "1", true, extend);
    }
    if ("detailContent".equals(method)) {
      String rawId = r.length > 0 ? r[0] : "";
      java.util.List<String> ids = (r.length > 1) ? Arrays.asList(r) : (rawId.contains("$$$") || rawId.contains("://") || rawId.startsWith("{")) ? java.util.Collections.singletonList(rawId) : Arrays.asList(rawId.split(","));
      return (String) sp.getClass().getMethod("detailContent", List.class)
          .invoke(sp, ids);
    }
    if ("searchContent".equals(method)) {
      String wd = r.length > 0 ? r[0] : "";
      try {
        return (String) sp.getClass().getMethod("searchContent", String.class, boolean.class, String.class)
            .invoke(sp, wd, false, r.length > 1 ? r[1] : "1");
      } catch (NoSuchMethodException e) {
        return (String) sp.getClass().getMethod("searchContent", String.class, boolean.class).invoke(sp, wd, false);
      }
    }
    if ("playerContent".equals(method)) {
      List<String> vips = new ArrayList<String>();
      if (r.length > 2 && r[2] != null && !r[2].isEmpty()) {
        for (String v : r[2].split(",")) if (!v.trim().isEmpty()) vips.add(v.trim());
      }
      final String flag = r.length > 0 ? r[0] : "";
      final String playId = r.length > 1 ? r[1] : "";
      skipDriveLoginGuard(sp, flag);
      return (String) sp.getClass().getMethod("playerContent", String.class, String.class, List.class)
          .invoke(sp, flag, playId, vips);
    }
    if ("liveContent".equals(method)) {
      return (String) sp.getClass().getMethod("liveContent", String.class).invoke(sp, r.length > 0 ? r[0] : "");
    }
    if ("proxy".equals(method)) {
      HashMap<String, String> params = new HashMap<String, String>();
      if (r.length > 0 && !r[0].isEmpty()) {
        try {
          Object ret0 = new com.google.gson.Gson().fromJson(r[0], new com.google.gson.reflect.TypeToken<java.util.Map<String, String>>() {}.getType());
          if (ret0 instanceof java.util.Map) params.putAll((java.util.Map<String, String>) ret0);
        } catch (Throwable ig) { }
      }
      Object ret = sp.getClass().getMethod("proxy", java.util.Map.class).invoke(sp, params);
      if (ret instanceof Object[]) {
        Object[] arr = (Object[]) ret;
        for (int k = 0; k < arr.length; k++) {
          if (arr[k] instanceof java.io.InputStream) {
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            try {
              byte[] buf = new byte[8192];
              int n;
              java.io.InputStream is = (java.io.InputStream) arr[k];
              while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            } catch (Throwable ig) { }
            arr[k] = new String(bos.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
          }
        }
        ret = arr;
      }
      return ret == null ? "" : new com.google.gson.Gson().toJson(ret);
    }
    throw new IllegalArgumentException("unknown method: " + method);
  }
}
