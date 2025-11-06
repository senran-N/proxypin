package com.network.proxy.vpn

import android.os.ParcelFileDescriptor
import android.util.Log
import com.network.proxy.ProxyVpnService.Companion.MAX_PACKET_LEN
import com.network.proxy.vpn.socket.ClientPacketWriter
import com.network.proxy.vpn.socket.SocketNIODataService
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InterruptedIOException
import java.net.InetSocketAddress
import java.nio.ByteBuffer


/**
 * VPN线程，负责处理VPN接收到的数据包
 * @author wanghongen
 */
class ProxyVpnThread(
    vpnInterface: ParcelFileDescriptor,
    proxyHost: String,
    proxyPort: Int,
) : Thread("Vpn thread") {
    companion object {
        const val TAG = "ProxyVpnThread"
    }

    @Volatile
    private var running = false

    private val vpnReadChannel = FileInputStream(vpnInterface.fileDescriptor).channel

    // 此VPN接收的来自上游服务器的数据包
    private val vpnWriteStream = FileOutputStream(vpnInterface.fileDescriptor)
    private val vpnPacketWriter = ClientPacketWriter(vpnWriteStream)
    private val vpnPacketWriterThread = Thread(vpnPacketWriter)

    // Background service & task for non-blocking socket
    private val nioService = SocketNIODataService(vpnPacketWriter)
    private val dataServiceThread = Thread(nioService, "Socket NIO thread")

    private val manager = ConnectionManager.instance.apply {
        //流量转发到代理地址
        this.proxyAddress = InetSocketAddress(proxyHost, proxyPort)
    }

    private val handler = ConnectionHandler(manager, nioService, vpnPacketWriter)

    private var currentThread: Thread? = null

    override fun run() {
        Log.i(TAG, "Vpn thread starting")
        currentThread = currentThread()
        dataServiceThread.start()
        vpnPacketWriterThread.start()

        val readBuffer = ByteBuffer.allocate(MAX_PACKET_LEN)
        running = true
        while (running) {
            try {
                val length = vpnReadChannel.read(readBuffer)

                when {
                    length > 0 -> {
                        try {
                            readBuffer.flip()
                            handler.handlePacket(readBuffer)
                        } catch (e: Exception) {
                            val errorMessage = (e.message ?: e.toString())
                            Log.e(TAG, errorMessage, e)
                        } finally {
                            readBuffer.clear()
                        }
                    }
                    length == 0 -> {
                        // No data available; yield briefly
                        sleep(50)
                    }
                    else -> {
                        // length == -1: EOF, underlying FD closed
                        Log.i(TAG, "VPN read EOF, channel closed")
                        running = false
                        break
                    }
                }
            } catch (e: InterruptedException) {
                Log.i(TAG, "Sleep interrupted: " + e.message)
            } catch (e: InterruptedIOException) {
                Log.i(TAG, "Read interrupted: " + e.message)
            } catch (e: java.io.IOException) {
                // Typical when ParcelFileDescriptor is closed: Bad file descriptor
                Log.e(TAG, e.message ?: e.toString(), e)
                running = false
                break
            } catch (e: Exception) {
                val errorMessage = (e.message ?: e.toString())
                Log.e(TAG, errorMessage, e)
                if (!vpnReadChannel.isOpen) {
                    Log.i(TAG, "VPN read channel closed")
                    running = false
                    break
                }
            }
        }

        Log.i(TAG, "Vpn thread stop")
    }

    @Synchronized
    fun stopThread() {
        if (running) {
            running = false
            nioService.shutdown()
            dataServiceThread.interrupt()

            vpnPacketWriter.shutdown()
            vpnPacketWriterThread.interrupt()
            currentThread?.interrupt()
            try { vpnReadChannel.close() } catch (_: Exception) {}
            try { vpnWriteStream.close() } catch (_: Exception) {}
        }
    }

}
