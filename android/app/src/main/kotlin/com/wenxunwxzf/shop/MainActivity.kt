package com.wenxunwxzf.shop

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
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
import java.util.UUID
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

    // ==================== 一体机内置秤（商米/天波等） ====================
    //
    // 一体机自带秤没有统一 SDK：商米、天波等厂商多数通过系统广播把重量抛出来，
    // 各家 action / extra key 不统一，这里把市面上常见的都监听一遍，
    // 谁先发就用谁；用户也可以用键盘口秤作为兜底。
    // 收到重量后通过 wenxun/scale 通道回传（单位：克或千克，Dart 侧换算）。

    private var scaleChannel: MethodChannel? = null
    private var scaleReceiver: BroadcastReceiver? = null

    private val scaleActions = arrayOf(
        "com.sunmi.weigh.WEIGHT_DATA",
        "com.sunmi.weigh.action.WEIGHT",
        "com.sunmi.weigh.WEIGHT",
        "com.sunmi.weight",
        "com.sunmi.scaleservice.WEIGHT",
        "android.intent.action.SUNMI_WEIGHT",
        "com.woyou.weigh.WEIGHT",
        "com.telpo.weigh.WEIGHT"
    )

    private val scaleKeys = arrayOf(
        "weight", "weight_data", "weightValue", "Weight", "WEIGHT", "value", "data"
    )

    /** 开始监听内置秤广播；返回是否注册成功（非一体机也返回 true，只是收不到数据） */
    private fun startScale(): Boolean {
        if (scaleReceiver != null) return true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val v = extractWeight(intent ?: return) ?: return
                runOnUiThread {
                    runCatching { scaleChannel?.invokeMethod("weight", v) }
                }
            }
        }
        val filter = IntentFilter()
        scaleActions.forEach { runCatching { filter.addAction(it) } }
        val ok = runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
        }.isSuccess
        if (ok) scaleReceiver = receiver
        return ok
    }

    private fun stopScale() {
        scaleReceiver?.let { runCatching { unregisterReceiver(it) } }
        scaleReceiver = null
    }

    /** 从广播里抠出重量数值（兼容 int/long/double/float/String 及 "12.5kg" 文本） */
    private fun extractWeight(intent: Intent): Double? {
        val bundle = intent.extras ?: return null
        for (k in scaleKeys) {
            val raw = runCatching { bundle.get(k) }.getOrNull() ?: continue
            val d = when (raw) {
                is Double -> raw
                is Float -> raw.toDouble()
                is Int -> raw.toDouble()
                is Long -> raw.toDouble()
                is Short -> raw.toDouble()
                is String -> raw.trim().replace(Regex("[^0-9.\\-]"), "").toDoubleOrNull()
                else -> null
            }
            if (d != null && d >= 0) return d
        }
        return null
    }

    override fun onDestroy() {
        stopScale()
        if (sunmiBound) runCatching { unbindService(sunmiConn) }
        super.onDestroy()
    }

    /** 蓝牙运行时权限弹窗结果 */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4201) {
            btPermGranted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            btPermLatch?.countDown()
        }
    }

    // ==================== 蓝牙小票打印机（经典蓝牙 SPP） ====================
    //
    // 便携蓝牙小票机走 SPP 串口协议（UUID 00001101）：
    // list = 已配对设备（标注是否打印机型）
    // scan = 扫描附近蓝牙设备（12 秒），配合 pair 完成 App 内配对
    // print = 连接 SPP socket 写 ESC/POS 字节流

    private val btSppUuid: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private val btAdapter: BluetoothAdapter?
        get() = runCatching {
            (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        }.getOrNull()

    private fun btPermissions(): Array<String> {
        val out = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            out.add(Manifest.permission.BLUETOOTH_CONNECT)
            out.add(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            out.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return out.toTypedArray()
    }

    private fun hasBtPermission(): Boolean {
        // API 22 及以下清单权限自动授予
        if (Build.VERSION.SDK_INT < 23) return true
        return btPermissions().all {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    }

    /** 阻塞等待用户授权（Flutter 权限弹窗），结果经 onRequestPermissionsResult 唤醒 */
    private var btPermLatch: CountDownLatch? = null
    private var btPermGranted: Boolean = false

    private fun awaitBtPermission(timeoutSec: Long = 60): Boolean {
        if (hasBtPermission()) return true
        val latch = CountDownLatch(1)
        btPermLatch = latch
        btPermGranted = false
        runOnUiThread { requestPermissions(btPermissions(), 4201) }
        if (!latch.await(timeoutSec, TimeUnit.SECONDS)) return false
        return btPermGranted
    }

    private fun isPrinterDevice(d: BluetoothDevice): Boolean {
        if (d.type == BluetoothDevice.DEVICE_TYPE_LE) return false // 纯 BLE 设备不走 SPP
        // 部分小票机蓝牙类型不规范：设备类是打印机 或 名字带打印关键词 都算
        val name = runCatching { d.name }.getOrNull()?.uppercase() ?: ""
        val nameHit = listOf(
            "PRINT", "打印", "POS-", "XP-", "58MM", "80MM",
            "GP-", "HM-", "SNBC", "CNB", "ZJIANG", "RONGTA"
        ).any { name.contains(it) }
        val cls = runCatching { d.bluetoothClass }.getOrNull()
        val clsHit = cls == null ||
            cls.majorDeviceClass == BluetoothClass.Device.Major.IMAGING
        return clsHit || nameHit
    }

    private fun btDeviceMap(d: BluetoothDevice, paired: Boolean): Map<String, Any> {
        val name = runCatching { d.name }.getOrNull() ?: ""
        val printer = isPrinterDevice(d)
        return mapOf(
            "id" to d.address,
            "name" to if (name.isEmpty()) "蓝牙设备 ${d.address}" else name,
            "kind" to if (printer) "spp" else "other",
            "paired" to paired
        )
    }

    private fun btList(): List<Map<String, Any>> {
        val adapter = btAdapter ?: throw Exception("本机没有蓝牙模块")
        if (!hasBtPermission()) throw Exception("未授权蓝牙权限")
        return adapter.bondedDevices
            .filter { isPrinterDevice(it) }
            .map { btDeviceMap(it, true) }
            .sortedBy { it["name"] as String }
    }

    private fun btScan(): List<Map<String, Any>> {
        val adapter = btAdapter ?: throw Exception("本机没有蓝牙模块")
        if (!awaitBtPermission()) throw Exception("未授权蓝牙权限，无法扫描")
        if (!adapter.isEnabled) throw Exception("蓝牙未开启，请先到系统设置打开蓝牙")
        val paired = adapter.bondedDevices.map { it.address }.toSet()
        val found = LinkedHashMap<String, BluetoothDevice>()
        val latch = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action == BluetoothDevice.ACTION_FOUND) {
                    val d = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                    if (d != null && isPrinterDevice(d)) found[d.address] = d
                }
            }
        }
        val finishReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) { latch.countDown() }
        }
        val f1 = IntentFilter(BluetoothDevice.ACTION_FOUND)
        val f2 = IntentFilter(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, f1, Context.RECEIVER_EXPORTED)
            registerReceiver(finishReceiver, f2, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, f1)
            @Suppress("DEPRECATION")
            registerReceiver(finishReceiver, f2)
        }
        try {
            if (adapter.isDiscovering) adapter.cancelDiscovery()
            adapter.startDiscovery()
            // 最多等 13 秒扫描结束
            latch.await(13, TimeUnit.SECONDS)
        } finally {
            runCatching { unregisterReceiver(receiver) }
            runCatching { unregisterReceiver(finishReceiver) }
            runCatching { adapter.cancelDiscovery() }
        }
        return found.values.map { btDeviceMap(it, it.address in paired) }
    }

    private fun btPair(address: String): Boolean {
        val adapter = btAdapter ?: throw Exception("本机没有蓝牙模块")
        if (!awaitBtPermission()) throw Exception("未授权蓝牙权限")
        val d = adapter.getRemoteDevice(address) ?: throw Exception("未找到设备：$address")
        if (d.bondState == BluetoothDevice.BOND_BONDED) return true
        val latch = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val state = intent?.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1) ?: -1
                if (state == BluetoothDevice.BOND_BONDED || state == BluetoothDevice.BOND_NONE) {
                    latch.countDown()
                }
            }
        }
        val f = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, f, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, f)
        }
        try {
            val ok = runCatching { d.createBond() }.getOrDefault(false)
            if (!ok) throw Exception("发起配对失败（设备可能不在范围内）")
            if (!latch.await(30, TimeUnit.SECONDS)) throw Exception("配对超时，请重试")
            return d.bondState == BluetoothDevice.BOND_BONDED
        } finally {
            runCatching { unregisterReceiver(receiver) }
        }
    }

    private fun btPrint(address: String, bytes: ByteArray) {
        val adapter = btAdapter ?: throw Exception("本机没有蓝牙模块")
        if (!awaitBtPermission()) throw Exception("未授权蓝牙权限")
        adapter.cancelDiscovery()
        val d = adapter.getRemoteDevice(address) ?: throw Exception("未找到蓝牙打印机：$address")
        val socket: BluetoothSocket = runCatching {
            d.createRfcommSocketToServiceRecord(btSppUuid)
        }.getOrElse { throw Exception("蓝牙串口创建失败：${it.message}") }
        socket.connect() // 超时约 12 秒，连不上抛 IOException
        try {
            val out = socket.outputStream
            var offset = 0
            while (offset < bytes.size) {
                val len = minOf(1024, bytes.size - offset)
                out.write(bytes, offset, len)
                out.flush()
                offset += len
                Thread.sleep(15) // 老机器缓冲小，分块匀速发
            }
            Thread.sleep(120) // 等打印机收完
        } finally {
            runCatching { socket.close() }
        }
    }

    // ==================== Flutter MethodChannel ====================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 进页就开始绑商米打印服务（非商米设备 bind 失败无副作用）
        bindSunmi()

        // 一体机内置秤（商米等）：由 Dart 侧按需 start/stop
        val scaleCh = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wenxun/scale")
        scaleChannel = scaleCh
        scaleCh.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(runCatching { startScale() }.getOrDefault(false))
                "stop" -> {
                    runCatching { stopScale() }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 蓝牙小票打印机
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wenxun/bt_printer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> {
                        Thread {
                            try {
                                runOnUiThread { result.success(btList()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("BT", e.message, null) }
                            }
                        }.start()
                    }
                    "scan" -> {
                        Thread {
                            try {
                                runOnUiThread { result.success(btScan()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("BT", e.message, null) }
                            }
                        }.start()
                    }
                    "pair" -> {
                        Thread {
                            try {
                                val addr = call.argument<String>("address") ?: ""
                                val ok = btPair(addr)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("BT", e.message, null) }
                            }
                        }.start()
                    }
                    "requestPermission" -> {
                        Thread {
                            val ok = runCatching { awaitBtPermission() }.getOrDefault(false)
                            runOnUiThread { result.success(ok) }
                        }.start()
                    }
                    "print" -> {
                        Thread {
                            try {
                                val addr = call.argument<String>("address") ?: ""
                                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                                btPrint(addr, bytes)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("BT", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

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
