package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import okhttp3.Dns;

/**
 * TVBox / CatVod 蜘蛛基类（Android 宿主侧实现）。
 *
 * <p>加固壳 jar 的 classes.dex 里只有转发用的 stub（BaseSpiderGuard + 若干 *Guard），
 * 它们继承本类；native 解包后加载的真实实现同样继承本类。TVBox 里这个类由宿主 APK
 * 提供，因此它必须编译进本 APK 的 dex、由 AppClassLoader 加载，否则壳类加载器在解析
 * 父类时会抛
 * {@code java.lang.ClassNotFoundException: com.github.catvod.spider.XxxGuard}
 * （后续再查会变成 {@code NoClassDefFoundError: Class not found using the boot class loader}）。
 *
 * <p>这里只给出标准的空实现：壳的 stub 会覆盖并转发到真实实现，所以这些方法不会
 * 被真正调用；但签名必须与 dex 中的 invoke 指令完全一致（尤其 categoryContent 的
 * HashMap、searchContent 的两个重载）。
 */
public abstract class Spider {

    public Spider() {
    }

    public void init(Context context) {
    }

    public void init(Context context, String extend) {
    }

    public void initApi(SpiderApi api) {
    }

    public String homeContent(boolean filter) {
        return "";
    }

    public String homeVideoContent() {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter,
                                  HashMap<String, String> extend) {
        return "";
    }

    public String detailContent(List<String> ids) {
        return "";
    }

    public String searchContent(String key, boolean quick) {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) {
        return "";
    }

    public String playerContent(String flag, String id, List<String> vipFlags) {
        return "";
    }

    public String liveContent(String url) {
        return "";
    }

    public String action(String action) {
        return "";
    }

    public boolean isVideoFormat(String url) {
        return false;
    }

    public boolean manualVideoCheck() {
        return false;
    }

    public void cancelByTag() {
    }

    public void destroy() {
    }

    public Object[] proxy(Map<String, String> params) {
        return null;
    }

    public Object[] proxyLocal(Map<String, String> params) {
        return null;
    }

public static Dns safeDns() { return Dns.SYSTEM; }
}
