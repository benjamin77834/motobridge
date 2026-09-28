package com.motobridge.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

/** Estado de conexión del transporte (equivalente a TransportState en iOS). */
enum class TransportState { NOT_CONNECTED, CONNECTING, CONNECTED }

/**
 * Transporte multiplataforma por red local (UDP + NSD/mDNS), compatible con el
 * modo Universal de MotoBridge iOS. Implementa PROTOCOL.md.
 *
 * - Publica y descubre el servicio "_motobridge._udp".
 * - Regla de conexión por nombre (el "menor" inicia).
 * - Envía/recibe datagramas UDP con MotoBridgePacket.
 */
class LocalNetworkTransport(
    private val context: Context,
    private val localName: String
) {
    companion object {
        const val SERVICE_TYPE = "_motobridge._udp."
        private const val TAG = "MotoBridgeNet"
    }

    // Callbacks hacia la capa superior.
    var onState: ((TransportState) -> Unit)? = null
    var onEvent: ((String) -> Unit)? = null
    /** (peerId, pcmBytes) — el peerId permite mezclar por emisor en el grupo. */
    var onAudio: ((String, ByteArray) -> Unit)? = null
    var onPeer: ((String?) -> Unit)? = null

    private val nsd: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var socket: DatagramSocket? = null
    private var localPort: Int = 0
    private var running = false

    /** Un peer del grupo (dirección UDP). */
    private data class Peer(val name: String, val address: InetAddress, val port: Int)

    /** Peers del grupo, por nombre. Concurrente porque se accede desde varios hilos. */
    private val peers = java.util.concurrent.ConcurrentHashMap<String, Peer>()

    /** Máximo de peers (común con Apple/iOS). 5 = grupo de 6 contándote. */
    private val maxPeers = 5

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // MARK: - Control

    fun start() {
        if (running) return
        running = true
        // Socket UDP en un puerto libre.
        val s = DatagramSocket()
        socket = s
        localPort = s.localPort
        startReceiveLoop(s)
        registerService(localPort)
        startDiscovery()
        onState?.invoke(TransportState.NOT_CONNECTED)
        emit("Publicando y buscando en red local (puerto $localPort)")
    }

    fun stop() {
        if (!running) return
        running = false
        try { registrationListener?.let { nsd.unregisterService(it) } } catch (_: Exception) {}
        try { discoveryListener?.let { nsd.stopServiceDiscovery(it) } } catch (_: Exception) {}
        registrationListener = null
        discoveryListener = null
        socket?.close()
        socket = null
        peers.clear()
        onPeer?.invoke(null)
        onState?.invoke(TransportState.NOT_CONNECTED)
        emit("Detenido")
    }

    /** Envía un bloque PCM a TODOS los peers del grupo. */
    fun sendAudio(pcm: ByteArray, length: Int) {
        val s = socket ?: return
        if (peers.isEmpty()) return
        val packet = MotoBridgePacket.encodeAudio(pcm, length)
        for (p in peers.values) {
            try {
                s.send(DatagramPacket(packet, packet.size, p.address, p.port))
            } catch (e: Exception) {
                Log.w(TAG, "send error to ${p.name}: ${e.message}")
            }
        }
    }

    private fun addPeer(name: String, address: InetAddress, port: Int) {
        if (peers.containsKey(name)) return
        if (peers.size >= maxPeers) { emit("Grupo lleno, ignorando $name"); return }
        peers[name] = Peer(name, address, port)
        onState?.invoke(TransportState.CONNECTED)
        onPeer?.invoke(peers.keys.joinToString(", "))
        emit("✅ Conectado con $name (grupo: ${peers.size})")
    }

    // MARK: - Registro (publicar servicio)

    private fun registerService(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = localName
            serviceType = SERVICE_TYPE
            setPort(port)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                emit("Servicio publicado: ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                emit("Fallo al publicar servicio ($errorCode)")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registrationListener = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    // MARK: - Descubrimiento

    private fun startDiscovery() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                emit("Fallo al buscar ($errorCode)")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName == localName) return // yo mismo
                emit("Encontrado ${info.serviceName}")
                // Regla de conexión: el nombre "menor" inicia; el otro espera.
                if (localName < info.serviceName) {
                    resolveAndConnect(info)
                } else {
                    emit("Esperando conexión de ${info.serviceName}")
                    // Igual resolvemos para conocer su dirección si nos llega audio.
                    resolveOnly(info)
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                if (peers.remove(info.serviceName) != null) {
                    if (peers.isEmpty()) onState?.invoke(TransportState.NOT_CONNECTED)
                    onPeer?.invoke(peers.keys.joinToString(", ").ifEmpty { null })
                    emit("Peer perdido ${info.serviceName}")
                }
            }
        }
        discoveryListener = listener
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun resolveAndConnect(info: NsdServiceInfo) {
        onState?.invoke(TransportState.CONNECTING)
        nsd.resolveService(info, resolveListener(connect = true))
    }

    private fun resolveOnly(info: NsdServiceInfo) {
        nsd.resolveService(info, resolveListener(connect = false))
    }

    private fun resolveListener(connect: Boolean) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
            emit("Resolve falló ${info.serviceName} ($errorCode)")
        }
        override fun onServiceResolved(info: NsdServiceInfo) {
            addPeer(info.serviceName, info.host, info.port)
            if (connect) {
                // Saludo vacío para que el otro conozca nuestra dirección.
                val hello = MotoBridgePacket.encodeAudio(ByteArray(0), 0)
                try {
                    socket?.send(DatagramPacket(hello, hello.size, info.host, info.port))
                } catch (_: Exception) {}
            }
        }
    }

    // MARK: - Recepción

    private fun startReceiveLoop(s: DatagramSocket) {
        thread(isDaemon = true, name = "motobridge-udp-rx") {
            val buf = ByteArray(4096)
            while (running && !s.isClosed) {
                try {
                    val dp = DatagramPacket(buf, buf.size)
                    s.receive(dp)
                    // Adoptar al emisor si aún no está en el grupo (el lado que
                    // "espera" descubre así la dirección del que le habla).
                    val key = "${dp.address.hostAddress}:${dp.port}"
                    if (peers.values.none { it.address == dp.address && it.port == dp.port }) {
                        addPeer(key, dp.address, dp.port)
                    }
                    val audio = MotoBridgePacket.decodeAudio(dp.data, dp.length)
                    if (audio != null && audio.isNotEmpty()) {
                        onAudio?.invoke(key, audio)  // key identifica al emisor para mezclar
                    }
                } catch (e: Exception) {
                    if (running) Log.w(TAG, "recv error: ${e.message}")
                }
            }
        }
    }

    private fun emit(text: String) {
        Log.i(TAG, text)
        onEvent?.invoke(text)
    }
}
