package com.wenxunwxzf.shop

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.IBinder
import woyou.aidlservice.jiuiv5.ICallback
import woyou.aidlservice.jiuiv5.IWoyouService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    private val permAction = "com.wenxunwxzf.shop.USB_PERMISSION"

    // ==================== 商米内置打印机（AIDL 打印服务） ====================

    private var sunmiService: IWoyouService? = null
    private var sunmiBound = false
    private val sunmiLock = Object()

    private val sunmiConn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            synchronized(sunmiLock) {
                sunmiService = IWoyouService.Stub.asInterface(service)
                sunmiLock.notifyAll()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            synchronized(sunmiLock) {
                sunmiService = null
                sunmiBound = false
            }
        }
    }

    /** 尝试绑定商米打印服务（V2/L2K/T2/D3 等机型均用 woyou.aidlservice.jiuiv5） */
    private fun bindSunmi(): Boolean {
        if (sunmiBound) return true
        val intent = Intent("woyou.aidlservice.jiuiv5.IWoyouService")
        intent.setPackage("woyou.aidlservice.jiuiv5")
        val ok = runCatching { bindService(intent, sunmiConn, Context.BIND_AUTO_CREATE) }.getOrDefault(false)
        if (ok) sunmiBound = true
        return ok
    }

    /** 等待商米打印服务连接（最多 timeoutMs） */
    private fun awaitSunmi(timeoutMs: Long): IWoyouService? {
        if (!sunmiBound && !bindSunmi()) return null
        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(sunmiLock) {
            while (sunmiService == null) {
                val remain = deadline - System.currentTimeMillis()
                if (remain <= 0) return null
                sunmiLock.wait(remain)
            }
            return sunmiService
        }
    }

    private fun sunmiPrint(bytes: ByteArray) {
        val svc = awaitSunmi(3000) ?: throw Exception("商米打印服务连接失败（确认是商米收银机且打印服务正常）")
        val latch = CountDownLatch(1)
        val okFlag = arrayOf(true)
        val cb = object : ICallback.Stub() {
            override fun onRunResult(isSuccess: Boolean) { okFlag[0] = isSuccess; latch.countDown() }
            override fun onReturnString(result: String?) { latch.countDown() }
            override fun onRaiseException(code: Int, msg: String?) {
                okFlag[0] = false; latch.countDown()
            }
        }
        // 分块发送，避免超长小票超出 Binder 缓冲区（1MB 限制）
        var offset = 0
        val chunk = 32768
        while (offset < bytes.size) {
            val len = minOf(chunk, bytes.size - offset)
            val part = bytes.copyOfRange(offset, offset + len)
            svc.sendRAWData(part, cb)
            offset += len
        }
        // 等待最后一次回调确认打印完成
        if (!latch.await(30, TimeUnit.SECONDS)) throw Exception("打印超时（请检查打印机纸张）")
        if (!okFlag[0]) throw Exception("打印机执行失败（缺纸/过热/开盖）")
    }

    override fun onDestroy() {
        if (sunmiBound) runCatching { unbindService(sunmiConn) }
        super.onDestroy()
    }

    // ==================== Flutter MethodChannel ====================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 进页就开始绑商米打印服务（非商米设备 bind 失败无副作用）
        bindSunmi()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wenxun/usb_printer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> {
                        try {
                            val list = listPrinters().toMutableList()
                            // 商米内置打印机：绑定成功即加入列表（排在最前）
                            if (awaitSunmiNonBlocking(1500)) {
                                list.add(0, mapOf(
                                    "name" to "商米内置打印机",
                                    "kind" to "sunmi",
                                    "hasPermission" to true
                                ))
                            }
                            result.success(list)
                        } catch (e: Exception) {
                            result.error("USB", e.message, null)
                        }
                    }
                    "requestPermission" -> {
                        Thread {
                            try {
                                val kind = call.argument<String>("kind") ?: ""
                                if (kind == "sunmi") {
                                    if (awaitSunmi(5000) == null) throw Exception("商米打印服务连接失败")
                                } else {
                                    val vid = call.argument<Int>("vid") ?: 0
                                    val pid = call.argument<Int>("pid") ?: 0
                                    ensurePermission(vid, pid)
                                }
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("USB", e.message, null) }
                            }
                        }.start()
                    }
                    "print" -> {
                        Thread {
                            try {
                                val kind = call.argument<String>("kind") ?: ""
                                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                                if (kind == "sunmi") {
                                    sunmiPrint(bytes)
                                } else {
                                    val vid = call.argument<Int>("vid") ?: 0
                                    val pid = call.argument<Int>("pid") ?: 0
                                    usbPrint(vid, pid, bytes)
                                }
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("USB", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 非阻塞探测商米服务（用于列表展示） */
    private fun awaitSunmiNonBlocking(timeoutMs: Long): Boolean {
        if (sunmiService != null) return true
        if (!sunmiBound && !bindSunmi()) return false
        return synchronized(sunmiLock) {
            if (sunmiService == null) {
                try { sunmiLock.wait(timeoutMs) } catch (_: InterruptedException) {}
            }
            sunmiService != null
        }
    }

    private fun usbManager(): UsbManager = getSystemService(Context.USB_SERVICE) as UsbManager

    /** 枚举带打印接口（class 7）或 Bulk OUT 端点的 USB 设备 */
    private fun printerDevices(): List<UsbDevice> {
        val out = mutableListOf<UsbDevice>()
        for (d in usbManager().deviceList.values) {
            var hit = false
            for (i in 0 until d.interfaceCount) {
                if (d.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_PRINTER) { hit = true; break }
            }
            if (!hit) {
                // 部分小票打印机用厂商自定义接口类(0xFF)，按 Bulk OUT 端点兜底
                outer@ for (i in 0 until d.interfaceCount) {
                    val itf = d.getInterface(i)
                    for (j in 0 until itf.endpointCount) {
                        val ep = itf.getEndpoint(j)
                        if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                            ep.direction == UsbConstants.USB_DIR_OUT) { hit = true; break@outer }
                    }
                }
            }
            if (hit) out.add(d)
        }
        return out
    }

    private fun listPrinters(): List<Map<String, Any>> =
        printerDevices().map {
            mapOf(
                "name" to (it.productName ?: "USB打印机(VID ${it.vendorId})"),
                "vid" to it.vendorId,
                "pid" to it.productId,
                "kind" to "usb",
                "hasPermission" to usbManager().hasPermission(it)
            )
        }

    private fun ensurePermission(vid: Int, pid: Int) {
        val manager = usbManager()
        val device = printerDevices().firstOrNull { it.vendorId == vid && it.productId == pid }
            ?: throw Exception("未找到 USB 打印机，请确认已用数据线连接并开机")
        if (manager.hasPermission(device)) return

        val latch = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) { latch.countDown() }
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, IntentFilter(permAction), Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, IntentFilter(permAction))
            }
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(this, 0, Intent(permAction).setPackage(packageName), flags)
            manager.requestPermission(device, pi)
            if (!latch.await(60, TimeUnit.SECONDS)) throw Exception("USB 授权超时，请重试")
            if (!manager.hasPermission(device)) throw Exception("USB 权限被拒绝，无法打印")
        } finally {
            runCatching { unregisterReceiver(receiver) }
        }
    }

    private fun usbPrint(vid: Int, pid: Int, bytes: ByteArray) {
        ensurePermission(vid, pid)
        val manager = usbManager()
        val device = printerDevices().firstOrNull { it.vendorId == vid && it.productId == pid }
            ?: throw Exception("未找到 USB 打印机")
        val connection = manager.openDevice(device) ?: throw Exception("无法打开 USB 设备")
        var endpoint: UsbEndpoint? = null
        var useInterface: UsbInterface? = null
        for (i in 0 until device.interfaceCount) {
            val itf = device.getInterface(i)
            for (j in 0 until itf.endpointCount) {
                val ep = itf.getEndpoint(j)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    ep.direction == UsbConstants.USB_DIR_OUT) {
                    endpoint = ep; useInterface = itf; break
                }
            }
            if (endpoint != null) break
        }
        if (endpoint == null || useInterface == null) {
            connection.close(); throw Exception("未找到打印输出端点（该设备可能不是小票打印机）")
        }
        if (!connection.claimInterface(useInterface, true)) {
            connection.close(); throw Exception("无法占用 USB 接口")
        }
        try {
            var offset = 0
            val chunk = 16384
            while (offset < bytes.size) {
                val len = minOf(chunk, bytes.size - offset)
                val n = connection.bulkTransfer(endpoint, bytes, offset, len, 3000)
                if (n < 0) throw Exception("小票数据发送失败（请检查打印机电源与纸仓）")
                offset += n
                if (n == len) Thread.sleep(15)
            }
        } finally {
            connection.releaseInterface(useInterface)
            connection.close()
        }
    }
}
