package com.lvno.smartclient

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lvno.smartclient/vpn"
    private val VPN_REQUEST_CODE = 9910
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val prepareIntent = VpnService.prepare(this)
                        if (prepareIntent != null) {
                            pendingResult = result
                            startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
                        } else {
                            launchVpnService()
                            result.success(true)
                        }
                    }
                    "stopVpn" -> {
                        val stopIntent = Intent(this, VpnTunnelService::class.java).apply {
                            action = "STOP_LVNO_VPN"
                        }
                        startService(stopIntent)
                        result.success(true)
                    }
                    "collectTelemetry" -> {
                        val counters = VpnTunnelService.collectAndResetCounters()
                        result.success(counters)
                    }
                    "addManualBytes" -> {
                        // يسمح لمحرك الكاش في Dart بتسجيل البايتات المحملة مباشرة عبر HTTP
                        val wan = (call.argument<Number>("wan")?.toLong()) ?: 0L
                        val cache = (call.argument<Number>("cache")?.toLong()) ?: 0L
                        VpnTunnelService.wanBytesAccumulated.addAndGet(wan)
                        VpnTunnelService.secretCacheBytesAccumulated.addAndGet(cache)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchVpnService() {
        val intent = Intent(this, VpnTunnelService::class.java)
        startService(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                launchVpnService()
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}