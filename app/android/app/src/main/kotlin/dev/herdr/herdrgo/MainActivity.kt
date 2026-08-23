package dev.herdr.herdrgo

import com.easytier.jni.EasyTierJNI
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.herdr/easytier")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startInstance" -> {
                            val config = call.argument<String>("config")
                                ?: throw IllegalArgumentException("missing config")
                            checkRc(EasyTierJNI.runNetworkInstance(config))
                            result.success(null)
                        }
                        "stopInstance" -> {
                            val instanceName = call.argument<String>("instanceName")
                                ?: throw IllegalArgumentException("missing instanceName")
                            val all = EasyTierJNI.listInstances(10)
                                ?.let { JSONObject(it).keys().asSequence().toList() }
                                .orEmpty()
                            // 只停目标实例、retain 其余；目标不存在时 retain 全部，
                            // 等价 no-op（静默成功）。
                            checkRc(
                                EasyTierJNI.retainNetworkInstance(
                                    (all - instanceName).toTypedArray()
                                )
                            )
                            result.success(null)
                        }
                        "currentVirtualIp" -> {
                            val instanceName = call.argument<String>("instanceName")
                                ?: throw IllegalArgumentException("missing instanceName")
                            result.success(collectInstanceInfo(instanceName))
                        }
                        "callJsonRpc" -> {
                            val service = call.argument<String>("service")
                                ?: throw IllegalArgumentException("missing service")
                            val method = call.argument<String>("method")
                                ?: throw IllegalArgumentException("missing method")
                            val payload = call.argument<String>("payload")
                                ?: throw IllegalArgumentException("missing payload")
                            // 失败时 JNI 抛 RuntimeException，由外层转成
                            // PlatformException；响应原样回传给 Dart 解析。
                            result.success(EasyTierJNI.callJsonRpc(service, method, payload))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("easytier", e.message, null)
                }
            }
    }

    // 从 collectNetworkInfos 的 JSON 里取出指定实例的条目，保持
    // {"map": {"<name>": <info>}} 形状回传，解析仍在 Dart 侧；
    // collectNetworkInfos 返回 null 时原样回 null。
    private fun collectInstanceInfo(instanceName: String): String? {
        val infos = EasyTierJNI.collectNetworkInfos(10) ?: return null
        val map = JSONObject(infos).optJSONObject("map") ?: return null
        val info = map.opt(instanceName) ?: return null
        return JSONObject().put("map", JSONObject().put(instanceName, info)).toString()
    }

    // JNI 失败时一般会先抛 RuntimeException；少数路径只回 -1，这里兜底转成异常。
    private fun checkRc(rc: Int) {
        if (rc != 0) {
            throw RuntimeException(EasyTierJNI.getLastError() ?: "easytier call failed: $rc")
        }
    }
}
