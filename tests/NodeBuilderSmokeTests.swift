import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct IPResult {
    let ip: String
    let colo: String?
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func queryValue(_ link: String, _ key: String) -> String? {
    guard let parts = NodeBuilder.splitURL(link) else { return nil }
    return Query(parts.query).get(key)
}

// VLESS WS: only the address/name may change; existing SNI, Host and path survive.
let vless = "vless://11111111-1111-4111-8111-111111111111@edge.example.com:2053?type=ws&security=tls&sni=tls.example.com&host=ws.example.com&path=%2Fgateway#edge"
let vlessTemplates = NodeBuilder.parseTemplates(vless)
expect(vlessTemplates.count == 1, "VLESS template parses")
let oneIP = [IPResult(ip: "192.0.2.10", colo: "LAX")]
let vlessOutput = NodeBuilder.generate(templates: vlessTemplates, ips: oneIP, opts: BuildOptions(domain: "override.example.net"))
expect(vlessOutput.nodes.count == 1, "VLESS node generates")
let vlessLink = vlessOutput.nodes[0].link
expect(NodeBuilder.splitURL(vlessLink)?.host == "192.0.2.10", "VLESS address is replaced")
expect(NodeBuilder.splitURL(vlessLink)?.port == "2053", "VLESS original port is preserved")
expect(queryValue(vlessLink, "sni") == "tls.example.com", "VLESS SNI remains unchanged")
expect(queryValue(vlessLink, "host") == "ws.example.com", "VLESS Host remains unchanged")
expect(queryValue(vlessLink, "path") == "/gateway", "VLESS path remains unchanged")

// Hostname template without explicit SNI/Host: its original hostname is retained;
// the advanced fallback domain must not override it.
let hostnameWithoutExplicitSNI = "vless://11111111-1111-4111-8111-111111111111@origin.example.com:2083?type=ws&security=tls&path=%2Fkeep#hostname"
let hostnameParsed = NodeBuilder.parseTemplates(hostnameWithoutExplicitSNI)
let hostnameGenerated = NodeBuilder.generate(templates: hostnameParsed, ips: oneIP, opts: BuildOptions(domain: "advanced.example.net"))
expect(hostnameGenerated.nodes.count == 1, "hostname template generates")
expect(NodeBuilder.splitURL(hostnameGenerated.nodes[0].link)?.port == "2083", "hostname template port remains unchanged")
expect(queryValue(hostnameGenerated.nodes[0].link, "sni") == "origin.example.com", "original hostname supplies missing SNI")
expect(queryValue(hostnameGenerated.nodes[0].link, "host") == "origin.example.com", "original hostname supplies missing Host")

// IP-only template: advanced domain is used only when no domain exists in the template.
let ipTemplate = "vless://11111111-1111-4111-8111-111111111111@203.0.113.7:443?type=ws&security=tls#ip-template"
let ipParsed = NodeBuilder.parseTemplates(ipTemplate)
expect(ipParsed.first?.status == .needsDomain, "IP-only template requires a domain")
let ipGenerated = NodeBuilder.generate(templates: ipParsed, ips: oneIP, opts: BuildOptions(domain: "cdn.example.net"))
expect(ipGenerated.nodes.count == 1, "advanced domain enables IP-only template")
expect(queryValue(ipGenerated.nodes[0].link, "sni") == "cdn.example.net", "advanced domain supplies SNI")
expect(queryValue(ipGenerated.nodes[0].link, "host") == "cdn.example.net", "advanced domain supplies WS Host")
expect(queryValue(ipGenerated.nodes[0].link, "fp") == nil, "advanced fallback does not add an unrelated fingerprint")

// VMess: preserve SNI and Host while replacing add.
let vmessObject: [String: Any] = [
    "v": "2", "ps": "vmess", "add": "vmess.example.com", "port": "8443",
    "id": "11111111-1111-4111-8111-111111111111", "aid": "0", "scy": "auto",
    "net": "ws", "tls": "tls", "sni": "sni.vmess.example", "host": "host.vmess.example",
    "path": "/vmess"
]
let vmessData = try! JSONSerialization.data(withJSONObject: vmessObject, options: [.sortedKeys])
let vmess = "vmess://" + vmessData.base64EncodedString()
let vmessTemplates = NodeBuilder.parseTemplates(vmess)
expect(vmessTemplates.count == 1, "VMess template parses")
let vmessOutput = NodeBuilder.generate(templates: vmessTemplates, ips: oneIP, opts: BuildOptions(domain: "ignored.example.net"))
expect(vmessOutput.nodes.count == 1, "VMess node generates")
let vmessBody = String(vmessOutput.nodes[0].link.dropFirst("vmess://".count))
let decodedVMess = try JSONSerialization.jsonObject(with: Data(base64Encoded: vmessBody)!) as! [String: Any]
expect(decodedVMess["add"] as? String == "192.0.2.10", "VMess add is replaced")
expect(decodedVMess["port"] as? String == "8443", "VMess original port is preserved")
expect(decodedVMess["sni"] as? String == "sni.vmess.example", "VMess SNI remains unchanged")
expect(decodedVMess["host"] as? String == "host.vmess.example", "VMess Host remains unchanged")
expect(decodedVMess["path"] as? String == "/vmess", "VMess path remains unchanged")

// Common Clash YAML subset converts; unsupported Reality options are rejected, not dropped.
let clash = """
proxies:
  - name: clash-vless
    type: vless
    server: edge.example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    network: ws
    tls: true
    servername: tls.example.com
    ws-opts:
      path: /ws
      headers:
        Host: host.example.com
  - name: clash-trojan
    type: trojan
    server: edge.example.com
    port: 443
    password: secret
    network: grpc
    tls: true
    grpc-opts:
      grpc-service-name: tunnel
  - name: clash-ss
    type: ss
    server: edge.example.com
    port: 8388
    cipher: aes-128-gcm
    password: secret
"""
let normalized = try SubscriptionFetcher.normalize(clash)
let clashTemplates = NodeBuilder.parseTemplates(normalized)
expect(clashTemplates.count == 3, "three supported Clash proxies convert")
expect(clashTemplates.contains(where: { $0.kind == .vless && $0.domain == "tls.example.com" }), "Clash VLESS SNI is preserved")

let reality = """
proxies:
  - name: reality
    type: vless
    server: edge.example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    network: tcp
    tls: true
    reality-opts:
      public-key: abc
      short-id: 1234
"""
var rejectedReality = false
do { _ = try SubscriptionFetcher.normalize(reality) } catch { rejectedReality = true }
expect(rejectedReality, "unsupported Reality configuration is rejected")


let trojanNoTLS = """
proxies:
  - name: trojan-plain
    type: trojan
    server: edge.example.com
    port: 443
    password: "abc#def"
    tls: false
"""
let trojanPlainLinks = try SubscriptionFetcher.normalize(trojanNoTLS)
let trojanPlain = NodeBuilder.parseTemplates(trojanPlainLinks)
expect(trojanPlain.count == 1, "quoted # in password is preserved")
expect(queryValue(trojanPlain[0].raw, "security") == "none", "Trojan tls=false remains non-TLS")

let unknownClashField = """
proxies:
  - name: unknown
    type: socks5
    server: edge.example.com
    port: 1080
    udp: true
"""
var rejectedUnknown = false
do { _ = try SubscriptionFetcher.normalize(unknownClashField) } catch { rejectedUnknown = true }
expect(rejectedUnknown, "unsupported Clash fields are rejected instead of dropped")

// Global output cap must hold even with many templates and IPs.
let manyTemplates = Array(repeating: vlessTemplates[0], count: 5)
let manyIPs = (1...20).map { IPResult(ip: "192.0.2.\($0)", colo: "LAX") }
let capped = NodeBuilder.generate(templates: manyTemplates, ips: manyIPs, opts: BuildOptions(), maxNodes: 20)
expect(capped.nodes.count == 20, "generation never exceeds 20 nodes")


// Strict HTTP download framing parser: body bytes are counted without headers/chunk markers.
let contentLengthResponse = "HTTP/1.1 200 OK\r\ncf-ray: test-ray\r\nContent-Length: 5\r\n\r\nhello"
var contentLengthParser = HTTPDownloadResponseParser()
expect(contentLengthParser.append(Data(contentLengthResponse.utf8)), "valid Content-Length response is accepted")
expect(contentLengthParser.payloadBytes == 5, "Content-Length counts only payload bytes")
expect(contentLengthParser.finish(validateCompleteResponse: true), "complete Content-Length response passes")

let fragmentedResponse = "HTTP/1.1 200 OK\r\nSeRvEr: cloudflare\r\nContent-Length: 5\r\n\r\nhello"
let fragmentedData = Data(fragmentedResponse.utf8)
var fragmentedParser = HTTPDownloadResponseParser()
expect(fragmentedParser.append(Data(fragmentedData.prefix(17))), "partial HTTP header is buffered")
expect(fragmentedParser.append(Data(fragmentedData.dropFirst(17))), "fragmented response completes parsing")
expect(fragmentedParser.payloadBytes == 5 && fragmentedParser.finish(validateCompleteResponse: true), "case-insensitive header parsing works")

var missingEdgeParser = HTTPDownloadResponseParser()
expect(!missingEdgeParser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)), "non-Cloudflare origin response is rejected")
var compressedParser = HTTPDownloadResponseParser()
expect(!compressedParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Encoding: gzip\r\n\r\nhello".utf8)), "compressed body is rejected")
var badTransferParser = HTTPDownloadResponseParser()
expect(!badTransferParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8)), "unsupported transfer coding is rejected")
var conflictingParser = HTTPDownloadResponseParser()
expect(!conflictingParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n".utf8)), "chunked plus Content-Length is rejected")
var duplicateLengthParser = HTTPDownloadResponseParser()
expect(duplicateLengthParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 5\r\ncontent-length: 5\r\n\r\nhello".utf8)), "identical duplicate Content-Length is accepted")
expect(duplicateLengthParser.finish(validateCompleteResponse: true), "identical duplicate lengths complete")
var conflictLengthParser = HTTPDownloadResponseParser()
expect(!conflictLengthParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 5, 6\r\n\r\nhello".utf8)), "conflicting Content-Length values are rejected")
var invalidLengthParser = HTTPDownloadResponseParser()
expect(!invalidLengthParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: nope\r\n\r\nhello".utf8)), "non-numeric Content-Length is rejected")
var redirectParser = HTTPDownloadResponseParser()
expect(!redirectParser.append(Data("HTTP/1.1 302 Found\r\ncf-ray: x\r\nContent-Length: 0\r\n\r\n".utf8)), "redirect response is rejected")

let chunkedResponse = "HTTP/1.1 200 OK\r\nserver: cloudflare\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
var chunkedParser = HTTPDownloadResponseParser()
expect(chunkedParser.append(Data(chunkedResponse.utf8)), "valid chunked response is accepted")
expect(chunkedParser.payloadBytes == 5 && chunkedParser.chunkedComplete, "chunk framing bytes are excluded")
expect(chunkedParser.finish(validateCompleteResponse: true), "complete chunked response passes")

let chunkedTrailerResponse = "HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Test: yes\r\n\r\n"
var trailerParser = HTTPDownloadResponseParser()
expect(trailerParser.append(Data(chunkedTrailerResponse.utf8)), "chunked response with trailer is accepted")
expect(trailerParser.chunkedComplete && trailerParser.payloadBytes == 3, "chunked trailer terminator is recognized")

let partialChunkedResponse = "HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n5\r\nhe"
var partialChunkedParser = HTTPDownloadResponseParser()
expect(partialChunkedParser.append(Data(partialChunkedResponse.utf8)), "partial final chunk is buffered")
expect(partialChunkedParser.payloadBytes == 5 && partialChunkedParser.finish(validateCompleteResponse: false), "timed partial chunked sample counts complete and received partial payload bytes")
var truncatedChunkedParser = HTTPDownloadResponseParser()
_ = truncatedChunkedParser.append(Data(partialChunkedResponse.utf8))
expect(!truncatedChunkedParser.finish(validateCompleteResponse: true), "truncated completed chunked response is rejected")
var badChunkSizeParser = HTTPDownloadResponseParser()
expect(!badChunkSizeParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n".utf8)), "invalid chunk size is rejected")
var badChunkCRLFParser = HTTPDownloadResponseParser()
expect(!badChunkCRLFParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX".utf8)), "invalid chunk terminator is rejected")

var truncatedLengthParser = HTTPDownloadResponseParser()
_ = truncatedLengthParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 6\r\n\r\nhello".utf8))
expect(!truncatedLengthParser.finish(validateCompleteResponse: true), "truncated Content-Length response is rejected")
var timedLengthParser = HTTPDownloadResponseParser()
_ = timedLengthParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 6\r\n\r\nhello".utf8))
expect(timedLengthParser.finish(validateCompleteResponse: false), "timed partial Content-Length sample can be measured")
var emptyBodyParser = HTTPDownloadResponseParser()
_ = emptyBodyParser.append(Data("HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 0\r\n\r\n".utf8))
expect(!emptyBodyParser.finish(validateCompleteResponse: true), "empty response body is not a speed sample")
var hugeHeaderParser = HTTPDownloadResponseParser()
expect(!hugeHeaderParser.append(Data(String(repeating: "A", count: HTTPDownloadResponseParser.maximumHeaderBytes + 1).utf8)), "oversized HTTP header is rejected")
var headerAndBodyParser = HTTPDownloadResponseParser()
let largeInitialBody = "HTTP/1.1 200 OK\r\ncf-ray: x\r\nContent-Length: 65000\r\n\r\n" + String(repeating: "a", count: 65000)
expect(headerAndBodyParser.append(Data(largeInitialBody.utf8)), "large first packet with small header is accepted")
expect(headerAndBodyParser.payloadBytes == 65000, "large initial packet body bytes are counted")

print("NodeBuilder and HTTP parser smoke tests: passed")

// Previously generated suffixes are stripped so re-replacing does not stack names.
expect(NodeBuilder.baseName("edge-LAX-1") == "edge", "colo suffix is stripped")
expect(NodeBuilder.baseName("edge-LAX-1-HKG-2_2053") == "edge", "stacked suffixes and port are stripped")
expect(NodeBuilder.baseName("plain-name") == "plain-name", "ordinary names are untouched")

// Multiple CF ports: merged by default, kept per port with keepPorts, and named apart.
let multiPortText = """
vless://11111111-1111-4111-8111-111111111111@a.example.com:443?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fp#n
vless://11111111-1111-4111-8111-111111111111@a.example.com:2053?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fp#n
"""
expect(NodeBuilder.parseTemplates(multiPortText).count == 1, "ports merge by default")
let keptPorts = NodeBuilder.parseTemplates(multiPortText, keepPorts: true)
expect(keptPorts.count == 2, "keepPorts keeps one template per port")
let keptOutput = NodeBuilder.generate(templates: keptPorts, ips: oneIP, opts: BuildOptions())
expect(keptOutput.nodes.count == 2 && keptOutput.nodes[0].name != keptOutput.nodes[1].name, "per-port nodes have distinct names")
expect(NodeBuilder.splitURL(keptOutput.nodes[1].link)?.port == "2053", "per-port node keeps its own port")

// Truncation is reported.
let cappedAgain = NodeBuilder.generate(templates: manyTemplates, ips: manyIPs, opts: BuildOptions(), maxNodes: 20)
expect(cappedAgain.truncated, "truncation flag is set when the cap cuts nodes")

// Address is a different (preferred) domain and SNI is missing: SNI comes from Host, not the address.
let preferredDomain = "vless://11111111-1111-4111-8111-111111111111@www.visa.com.sg:443?type=ws&security=tls&host=worker.example.com&path=%2Fp#pd"
let pdGenerated = NodeBuilder.generate(templates: NodeBuilder.parseTemplates(preferredDomain), ips: oneIP, opts: BuildOptions())
expect(queryValue(pdGenerated.nodes[0].link, "sni") == "worker.example.com", "missing SNI is filled from Host, not the preferred address")

// Speed/latency can be put into node names, and re-replacing strips them again.
let statsTemplates = NodeBuilder.parseTemplates("vless://11111111-1111-4111-8111-111111111111@a.example.com:443?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fp#stats")
let statsGenerated = NodeBuilder.generate(templates: statsTemplates, ips: oneIP, opts: BuildOptions(),
                                          statsLabel: { _ in "12.3MB/s 45ms" })
expect(statsGenerated.nodes.first?.name.hasSuffix(" 12.3MB/s 45ms") == true, "stats label is appended to node name")
expect(NodeBuilder.baseName("edge-LAX-1_443 12.3MB/s 45ms") == "edge", "stats suffix is stripped on re-replace")
expect(NodeBuilder.baseName("edge-LAX-1 8.0MB/s 120ms") == "edge", "stats suffix without port is stripped")

// =====================================================================
// ScanLogic.swift：综合分、排行榜整理、网段判断、邻近抽样、测速方案、测速地址健康度
// =====================================================================

// ---- 综合分 ----
let nowDate = Date()
let bigButLaggy = LeaderboardScore.value(speed: 20, latency: 300, loss: 0, testedAt: nowDate)
let steadyFast = LeaderboardScore.value(speed: 15, latency: 40, loss: 0, testedAt: nowDate)
expect(steadyFast > bigButLaggy, "15MB/s@40ms outranks 20MB/s@300ms")
expect(LeaderboardScore.value(speed: nil, latency: 10, loss: 0, testedAt: nowDate) == 0, "no speed scores zero")
expect(LeaderboardScore.value(speed: 0, latency: 10, loss: 0, testedAt: nowDate) == 0, "zero speed scores zero")
expect(LeaderboardScore.value(speed: 10, latency: 40, loss: 0.25, testedAt: nowDate)
       < LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nowDate), "packet loss lowers the score")
let freshScore = LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nowDate)
expect(LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nowDate.addingTimeInterval(-10 * 86400)) < freshScore,
       "old results score lower")
expect(LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nowDate.addingTimeInterval(-86400)) == freshScore,
       "results within 3 days are not penalised")
expect(LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nil) < freshScore, "results without a time are slightly penalised")
let veryOld = LeaderboardScore.value(speed: 10, latency: 40, loss: 0, testedAt: nowDate.addingTimeInterval(-365 * 86400))
expect(veryOld >= freshScore * 0.5 - 0.0001, "age penalty floors at 50%")

// ---- 排行榜整理 ----
func hip(_ ip: String, _ speed: Double?, net: String?, loss: Double? = nil, ageDays: Double = 0) -> HistoryIP {
    HistoryIP(id: UUID(), ip: ip, tcpLatency: 40, httpsLatency: 40, colo: "LAX", speed: speed, lossRate: loss,
              testedAt: Date().addingTimeInterval(-ageDays * 86400).timeIntervalSince1970, network: net)
}
let sameIP = LeaderboardStore.normalized([hip("1.1.1.1", 5, net: "wifi"), hip("1.1.1.1", 9, net: "wifi")])
expect(sameIP.count == 1 && sameIP[0].speed == 9, "same IP on the same network keeps the last record")
let twoNets = LeaderboardStore.normalized([hip("1.1.1.1", 5, net: "wifi"), hip("1.1.1.1", 9, net: "cellular")])
expect(twoNets.count == 2, "same IP on different networks is kept separately")
let junk = LeaderboardStore.normalized([hip("1.1.1.2", 0, net: "wifi"), hip("1.1.1.3", nil, net: "wifi"), hip("999.1.1.1", 5, net: "wifi")])
expect(junk.isEmpty, "zero-speed, missing-speed and invalid IPs are dropped")
let legacy = LeaderboardStore.normalized([hip("1.1.1.4", 5, net: nil), hip("1.1.1.4", 7, net: "wifi"), hip("1.1.1.5", 6, net: nil)])
expect(legacy.count == 2, "legacy untagged record is dropped when the IP has a tagged one")
expect(legacy.contains { $0.ip == "1.1.1.5" && $0.network == nil }, "legacy untagged record is kept otherwise")
var many: [HistoryIP] = []
for i in 0..<130 { many.append(hip("10.0.\(i / 250).\(i % 250 + 1)", Double(i + 1), net: "wifi")) }
let capped100 = LeaderboardStore.normalized(many)
expect(capped100.count == 100, "each network keeps at most 100 records")
expect((capped100.compactMap { $0.speed }.min() ?? 0) >= 31, "the 100 best records are the ones kept")

let mergedBoard = LeaderboardStore.merged(existing: [hip("2.2.2.2", 3, net: "wifi")],
                                          scanned: [hip("2.2.2.3", 8, net: nil), hip("2.2.2.4", 0, net: nil)],
                                          network: "cellular", now: nowDate)
expect(mergedBoard.count == 2, "merge skips results without speed")
expect(mergedBoard.first { $0.ip == "2.2.2.3" }?.network == "cellular", "merged results are tagged with the current network")
expect(abs((mergedBoard.first { $0.ip == "2.2.2.3" }?.testedAt ?? 0) - nowDate.timeIntervalSince1970) < 1, "merged results get the test time")

let boardForWifi = LeaderboardStore.visible([hip("3.3.3.1", 5, net: "wifi"), hip("3.3.3.2", 9, net: "cellular"),
                                             hip("3.3.3.3", 7, net: nil)], network: "wifi")
expect(boardForWifi.map { $0.ip } == ["3.3.3.3", "3.3.3.1"], "wifi sees wifi and legacy records, best score first")

// ---- 网络类型文案 ----
expect(NetworkKey.label("wifi") == "Wi-Fi" && NetworkKey.label("cellular") == "蜂窝网络", "network labels")
expect(NetworkKey.label("unknown") == "未知网络", "unknown network label")

// ---- 网段判断 ----
expect(CIDR.fullyCovers24("104.16.0.0/20", of: "104.16.5.9"), "/20 covers a /24 inside it")
expect(!CIDR.fullyCovers24("104.16.0.0/20", of: "104.17.0.1"), "/20 does not cover an outside IP")
expect(!CIDR.fullyCovers24("104.16.5.0/28", of: "104.16.5.9"), "ranges smaller than /24 never cover a whole /24")
expect(CIDR.fullyCovers24("104.16.0.0/24", of: "104.16.0.200"), "/24 covers itself")
expect(!CIDR.fullyCovers24("not-a-range", of: "104.16.0.1"), "garbage range is rejected")
expect(CIDR.canonicalIP("2606:4700:0:0:0:0:0:1") == "2606:4700::1", "IPv6 is canonicalised")
expect(CIDR.isValid("104.16.0.0/20") && !CIDR.isValid("104.16.0.0/40"), "CIDR validation")

// ---- 邻近抽样 ----
var counter = 0
let neighbors = NeighborSampler.extraIPs(
    seeds: ["104.16.5.9", "104.16.5.77", "2606:4700::1"], ranges: ["104.16.0.0/20"],
    known: ["104.16.5.9", "104.16.5.77"], perSubnet: 3,
    random: { range in counter += 1; return range.lowerBound + counter % range.count })
expect(neighbors.count == 3, "three new IPs for the single /24")
expect(neighbors.allSatisfy { $0.hasPrefix("104.16.5.") }, "new IPs stay inside the seed /24")
expect(Set(neighbors).count == 3 && !neighbors.contains("104.16.5.9") && !neighbors.contains("104.16.5.77"),
       "new IPs are unique and not already tested")
expect(NeighborSampler.extraIPs(seeds: ["8.8.8.8"], ranges: ["104.16.0.0/20"], known: []).isEmpty,
       "seeds outside the selected ranges are ignored")
expect(NeighborSampler.extraIPs(seeds: ["104.16.5.9"], ranges: ["104.16.5.0/28"], known: []).isEmpty,
       "small ranges are never sampled beyond their size")
expect(NeighborSampler.extraIPs(seeds: ["2606:4700::1"], ranges: ["2606:4700::/32"], known: []).isEmpty,
       "IPv6 seeds are ignored")

// ---- 测速方案 ----
expect(ScanPreset.allCases.count == 3, "three scan presets")
expect(ScanPreset.standard.httpsTopN == 300 && ScanPreset.standard.speedTopN == 30 && ScanPreset.standard.speedSeconds == 8,
       "standard preset matches the old defaults")
expect(ScanPreset.matching(httpsTopN: 300, speedTopN: 30, speedSeconds: 8, samplePerRange: 24, refineNeighbors: false) == .standard,
       "standard values are recognised")
expect(ScanPreset.matching(httpsTopN: 301, speedTopN: 30, speedSeconds: 8, samplePerRange: 24, refineNeighbors: false) == nil,
       "a tweaked value matches no preset")
expect(!ScanPreset.fast.refineNeighbors && !ScanPreset.standard.refineNeighbors && ScanPreset.precise.refineNeighbors,
       "only the precise preset turns on neighbour sampling")

// ---- 测速地址健康度 ----
let health = DownloadHealth()
var tripped = false
for _ in 0..<7 { tripped = health.recordFailure() || tripped }
expect(!tripped && !health.useFallback, "7 failures do not ask for a host check")
expect(health.recordFailure(), "the 8th consecutive failure asks for a host check")
expect(!health.useFallback, "a failure streak alone never switches to the fallback")
health.activateFallback()
expect(health.useFallback, "the fallback turns on once the caller confirms the host is down")
for _ in 0..<8 { health.recordFallbackResult(success: false) }
expect(!health.useFallback, "the fallback gives up after 8 failures of its own")
health.activateFallback()
expect(!health.useFallback, "a fallback that gave up is not reactivated")
health.reset()
health.activateFallback()
expect(health.useFallback, "reset allows the fallback again")
health.reset()
var trippedAgain = false
for _ in 0..<5 { trippedAgain = health.recordFailure() || trippedAgain }
health.recordSuccess()
for _ in 0..<5 { trippedAgain = health.recordFailure() || trippedAgain }
expect(!trippedAgain, "a success resets the failure streak")

// =====================================================================
// NodeBuilder 的共享小函数：入口目标、模板挑选、订阅来源判断
// =====================================================================
let targetTemplates = NodeBuilder.parseTemplates("vless://11111111-1111-4111-8111-111111111111@1.2.3.4:2053?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fp#n")
let entry = NodeBuilder.entryTarget(from: targetTemplates, ownDomain: "")
expect(entry?.domain == "a.example.com" && entry?.port == 2053 && entry?.path == "/p", "entry target uses the template domain, port and path")
let workersDevTemplates = NodeBuilder.parseTemplates("vless://11111111-1111-4111-8111-111111111111@1.2.3.4:443?type=ws&security=tls&sni=w.workers.dev&host=w.workers.dev&path=%2F#n")
expect(NodeBuilder.entryTarget(from: workersDevTemplates, ownDomain: "my.example.com")?.domain == "my.example.com",
       "workers.dev entry is replaced by the user's own domain")
let noDomainTemplates = NodeBuilder.parseTemplates("vless://11111111-1111-4111-8111-111111111111@1.2.3.4:443?type=ws&security=tls&path=%2F#n")
expect(NodeBuilder.entryTarget(from: noDomainTemplates, ownDomain: "") == nil, "no domain means no entry target")

let twoPorts = NodeBuilder.parseTemplates("""
vless://11111111-1111-4111-8111-111111111111@a.example.com:2053?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fa#a
vless://11111111-1111-4111-8111-111111111111@a.example.com:443?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Fb#b
""")
expect(twoPorts.count == 2, "two distinct templates parse")
let onlyOne = NodeBuilder.pickTemplates(twoPorts, opts: BuildOptions(), onePerIP: true)
expect(onlyOne.used.count == 1 && onlyOne.used[0].port == "443" && onlyOne.eligibleCount == 2, "one-per-IP prefers port 443")
expect(NodeBuilder.pickTemplates(twoPorts, opts: BuildOptions(), onePerIP: false).used.count == 2, "all templates are used when one-per-IP is off")

expect(NodeBuilder.isOwnSubscription("https://sub.example.com/secretkey", ownPath: "secretkey", ownHosts: ["Sub.Example.com"]),
       "own subscription is recognised by host and path")
expect(!NodeBuilder.isOwnSubscription("https://sub.example.com/other", ownPath: "secretkey", ownHosts: ["sub.example.com"]),
       "a different path is not the own subscription")
expect(!NodeBuilder.isOwnSubscription("https://sub.example.com/secretkey", ownPath: nil, ownHosts: ["sub.example.com"]),
       "no stored path means not own")
expect(NodeBuilder.sourceDomain(subURL: "https://node.example.com/k", ownSubscription: false) == "node.example.com", "custom domain source")
expect(NodeBuilder.sourceDomain(subURL: "https://x.workers.dev/k", ownSubscription: false) == "", "workers.dev is not used as a domain override")
expect(NodeBuilder.sourceDomain(subURL: "https://node.example.com/k", ownSubscription: true) == "", "own subscription host is never an override")

print("scan logic tests: passed")
