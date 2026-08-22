package dev.herdr.herdr_web

import com.easytier.jni.EasyTierForwarder
import com.easytier.jni.EasyTierJNI
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                            checkRc(EasyTierJNI.retainNetworkInstance(emptyArray()))
                            result.success(null)
                        }
                        "currentVirtualIp" ->
                            // 原样返回 collectNetworkInfos 的 JSON，解析在 Dart 侧。
                            result.success(EasyTierJNI.collectNetworkInfos(10))
                        "startForwarder" -> {
                            val instanceName = call.argument<String>("instanceName")
                                ?: throw IllegalArgumentException("missing instanceName")
                            val targetIp = call.argument<String>("targetIp")
                                ?: throw IllegalArgumentException("missing targetIp")
                            val targetPort = call.argument<Int>("targetPort")
                                ?: throw IllegalArgumentException("missing targetPort")
                            result.success(
                                EasyTierForwarder.start(instanceName, targetIp, targetPort)
                            )
                        }
                        "stopForwarder" -> {
                            val localPort = call.argument<Int>("localPort")
                                ?: throw IllegalArgumentException("missing localPort")
                            EasyTierForwarder.stop(localPort)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("easytier", e.message, null)
                }
            }
    }

    // JNI 失败时一般会先抛 RuntimeException；少数路径只回 -1，这里兜底转成异常。
    private fun checkRc(rc: Int) {
        if (rc != 0) {
            throw RuntimeException(EasyTierJNI.getLastError() ?: "easytier call failed: $rc")
        }
    }
}
