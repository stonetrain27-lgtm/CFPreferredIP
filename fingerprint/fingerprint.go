// Package fingerprint provides a Chrome-fingerprinted (uTLS) WebSocket
// entry check: some Cloudflare entry IPs reject non-browser TLS
// fingerprints, which the iOS native TLS stack cannot disguise.
package fingerprint

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"
)

// EntryCheck dials ip:port, performs a Chrome-fingerprinted TLS handshake
// with SNI = domain, sends a WebSocket upgrade request for path and returns
// the HTTP status code of the response (101 when the entry is alive).
// Negative values mean the check never got an HTTP response:
// -1 dial, -2 preset, -3 handshake, -4 write, -5 read, -6 malformed status line.
func EntryCheck(ip string, port int32, domain string, path string, timeoutMs int32) int32 {
	return EntryCheckWithHost(ip, port, domain, domain, path, timeoutMs)
}

// EntryCheckWithHost uses sni only for the TLS handshake and host only for
// the HTTP/1.1 WebSocket Upgrade Host header. They are often different.
func EntryCheckWithHost(ip string, port int32, sni string, host string, path string, timeoutMs int32) int32 {
	if path == "" {
		path = "/"
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 6 * time.Second
	}
	dialer := &net.Dialer{Timeout: timeout}
	raw, err := dialer.Dial("tcp", net.JoinHostPort(ip, fmt.Sprint(port)))
	if err != nil {
		return -1
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(timeout))

	spec, err := utls.UTLSIdToSpec(utls.HelloChrome_Auto)
	if err != nil {
		return -2
	}
	// The entry check speaks HTTP/1.1 (WebSocket upgrade); keep Chrome's
	// fingerprint but do not offer h2, or the edge may negotiate ALPN h2
	// and kill the HTTP/1.1 request.
	for _, ext := range spec.Extensions {
		if alpn, ok := ext.(*utls.ALPNExtension); ok {
			alpn.AlpnProtocols = []string{"http/1.1"}
		}
	}
	conn := utls.UClient(raw, &utls.Config{ServerName: sni, NextProtos: []string{"http/1.1"}}, utls.HelloCustom)
	if err := conn.ApplyPreset(&spec); err != nil {
		return -2
	}
	if err := conn.Handshake(); err != nil {
		return -3
	}

	keyBytes := make([]byte, 16)
	_, _ = rand.Read(keyBytes)
	key := base64.StdEncoding.EncodeToString(keyBytes)
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Mozilla/5.0\r\n\r\n", path, host, key)
	if _, err := conn.Write([]byte(req)); err != nil {
		return -4
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return -5
	}
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return -6
	}
	var code int
	if _, err := fmt.Sscanf(parts[1], "%d", &code); err != nil {
		return -6
	}
	return int32(code)
}
