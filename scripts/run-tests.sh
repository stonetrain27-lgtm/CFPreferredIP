#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v swiftc >/dev/null || { echo "swiftc is required" >&2; exit 1; }
command -v node >/dev/null || { echo "node is required" >&2; exit 1; }

# NodeBuilder uses Darwin on Apple platforms and Glibc/FoundationNetworking on Linux.
if [[ "$(uname -s)" == "Darwin" ]]; then
  cp "$ROOT/CFPreferredIP/NodeBuilder.swift" "$TMP/NodeBuilder.swift"
else
  sed -e 's/^import Darwin$/import Glibc/' -e '/^import Foundation$/a import FoundationNetworking' \
    "$ROOT/CFPreferredIP/NodeBuilder.swift" > "$TMP/NodeBuilder.swift"
fi
cp "$ROOT/tests/NodeBuilderSmokeTests.swift" "$TMP/main.swift"
swiftc "$TMP/NodeBuilder.swift" "$ROOT/CFPreferredIP/HTTPDownloadParser.swift" "$ROOT/CFPreferredIP/ScanLogic.swift" "$TMP/main.swift" -o "$TMP/nodebuilder-tests"
"$TMP/nodebuilder-tests"
if [[ "$(uname -s)" == "Darwin" ]]; then
  swiftc -typecheck "$ROOT/CFPreferredIP/NodeBuilder.swift" \
    "$ROOT/CFPreferredIP/HTTPDownloadParser.swift" "$ROOT/CFPreferredIP/CloudflareAPI.swift" \
    "$ROOT/CFPreferredIP/CloudflareDeploy.swift" "$ROOT/tests/CompileStubs.swift"
else
  # Lightweight stand-ins for Apple-only Security / Combine APIs let Linux
  # type-check the deployment logic without pretending to emulate Keychain.
  cat > "$TMP/Combine.swift" <<'SWIFT'
public protocol ObservableObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public var projectedValue: Published<Value> { self }
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
SWIFT
  cat > "$TMP/Security.swift" <<'SWIFT'
import Foundation
public typealias OSStatus = Int32
public typealias SecRandomRef = OpaquePointer
public typealias CFDictionary = NSDictionary
public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -1
public let errSecDuplicateItem: OSStatus = -2
public let kSecClass = "class"
public let kSecClassGenericPassword = "generic-password"
public let kSecAttrService = "service"
public let kSecAttrAccount = "account"
public let kSecReturnData = "return-data"
public let kSecMatchLimit = "match-limit"
public let kSecMatchLimitOne = "one"
public let kSecValueData = "value-data"
public let kSecAttrAccessible = "accessible"
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "after-first-unlock-this-device-only"
public let kSecRandomDefault: SecRandomRef? = nil
public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus { errSecItemNotFound }
public func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { errSecItemNotFound }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { errSecItemNotFound }
public func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus { errSecSuccess }
public func SecRandomCopyBytes(_ random: SecRandomRef?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> OSStatus { errSecSuccess }
SWIFT
  mkdir -p "$TMP/modules"
  swiftc -emit-module -module-name Combine "$TMP/Combine.swift" -emit-module-path "$TMP/modules/Combine.swiftmodule"
  swiftc -emit-module -module-name Security "$TMP/Security.swift" -emit-module-path "$TMP/modules/Security.swiftmodule"
  swiftc -typecheck -I "$TMP/modules" "$TMP/NodeBuilder.swift" \
    "$ROOT/CFPreferredIP/HTTPDownloadParser.swift" "$ROOT/CFPreferredIP/CloudflareAPI.swift" \
    "$ROOT/CFPreferredIP/CloudflareDeploy.swift" "$ROOT/tests/CompileStubs.swift"
fi
echo "Cloudflare deployment logic Swift type-check: passed"
node "$ROOT/tests/worker-subscription.test.mjs"
node "$ROOT/tests/worker-convert.test.mjs"
node --check "$ROOT/worker/subscription/worker.js"

# Parse every app Swift source file. This checks syntax only, not iOS SDK type-checking.
for source in "$ROOT"/CFPreferredIP/*.swift; do
  swiftc -parse "$source"
done

echo "All available local smoke checks passed. Xcode/iOS SDK and live Cloudflare checks remain separate."
