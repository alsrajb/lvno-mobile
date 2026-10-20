package com.lvno.smartclient

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

class VpnTunnelService : VpnService() {

    companion object {
        val isRunning = AtomicBoolean(false)
        val wanBytesAccumulated = AtomicLong(0L)
        val secretCacheBytesAccumulated = AtomicLong(0L)

        // قراءة وتصفير العدادات الذرية عند كل نبضة (كل دقيقتين)
        fun collectAndResetCounters(): Map<String, Long> {
            val wan = wanBytesAccumulated.getAndSet(0L)
            val cache = secretCacheBytesAccumulated.getAndSet(0L)
            return mapOf(
                "wanBytesDelta" to wan,
                "secretCacheBytesDelta" to cache
            )
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var readerThread: Thread? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == "STOP_LVNO_VPN") {
            stopTunnel()
            return START_NOT_STICKY
        }

        if (!isRunning.get()) {
            startTunnel()
        }
        return START_STICKY
    }

    private fun startTunnel() {
        val builder = Builder()
            .setSession("LVNO Smart Network")
            .setMtu(1400)
            .addAddress("10.88.0.2", 24)
            .addDnsServer("1.1.1.1")
            // توجيه النطاق الهجين الموحد 10.99.99.0/24 لمراقبة الكاش السري بدقة
            .addRoute("10.99.99.0", 24)

        vpnInterface = builder.establish()
        isRunning.set(true)

        readerThread = thread(start = true, name = "LVNO-Packet-Inspector") {
            val fd = vpnInterface?.fileDescriptor ?: return@thread
            val inputStream = FileInputStream(fd)
            val packet = ByteBuffer.allocate(32767)

            try {
                while (isRunning.get()) {
                    val length = inputStream.read(packet.array())
                    if (length > 20) {
                        inspectAndAccountIpv4Packet(packet.array(), length)
                        packet.clear()
                    } else if (length < 0) {
                        break
                    }
                }
            } catch (_: Exception) {
            } finally {
                stopTunnel()
            }
        }
    }

    /**
     * فحص رأس حزمة IPv4 (أول 20 بايت) بدون فك تشفير المحتوى لضمان سرعة المعالج
     */
    private fun inspectAndAccountIpv4Packet(raw: ByteArray, length: Int) {
        val version = (raw[0].toInt() shr 4) and 0x0F
        if (version != 4) return

        val srcOctet1 = raw[12].toInt() and 0xFF
        val srcOctet2 = raw[13].toInt() and 0xFF
        val srcOctet3 = raw[14].toInt() and 0xFF

        val dstOctet1 = raw[16].toInt() and 0xFF
        val dstOctet2 = raw[17].toInt() and 0xFF
        val dstOctet3 = raw[18].toInt() and 0xFF

        val isDstLocalBus = (dstOctet1 == 10 && dstOctet2 == 99 && dstOctet3 == 99)
        val isSrcLocalBus = (srcOctet1 == 10 && srcOctet2 == 99 && srcOctet3 == 99)

        when {
            // 1. الرفع من الهاتف إلى الخازن الشبكي 10.99.99.x (Seeding / DNS Inbox) = مجاني 100%
            isDstLocalBus -> return

            // 2. التحميل من الخازن الشبكي 10.99.99.x إلى الهاتف = كاش سري (ربح صافي للمنظومة)
            isSrcLocalBus -> secretCacheBytesAccumulated.addAndGet(length.toLong())

            // 3. حركة الإنترنت الخارجية عبر منفذ صاحب الشبكة (ether1-WAN)
            else -> wanBytesAccumulated.addAndGet(length.toLong())
        }
    }

    private fun stopTunnel() {
        isRunning.set(false)
        try {
            vpnInterface?.close()
        } catch (_: Exception) {}
        vpnInterface = null
        stopSelf()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }
}