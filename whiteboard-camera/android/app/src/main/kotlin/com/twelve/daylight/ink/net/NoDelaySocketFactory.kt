package com.twelve.daylight.ink.net

import java.net.InetAddress
import java.net.Socket
import javax.net.SocketFactory

/** OkHttp leaves Nagle on; every ink chunk must leave now (SPEC D49). */
object NoDelaySocketFactory : SocketFactory() {
    private fun tuned(s: Socket): Socket = s.apply { tcpNoDelay = true }

    override fun createSocket(): Socket = tuned(Socket())
    override fun createSocket(host: String, port: Int): Socket = tuned(Socket(host, port))
    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket = tuned(Socket(host, port, localHost, localPort))
    override fun createSocket(host: InetAddress, port: Int): Socket = tuned(Socket(host, port))
    override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress, localPort: Int): Socket = tuned(Socket(address, port, localAddress, localPort))
}
