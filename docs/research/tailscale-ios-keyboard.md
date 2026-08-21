# Tailscale Connectivity From an iOS Custom Keyboard

Research date: 2026-08-20

## Conclusion

An iOS custom keyboard with **Allow Full Access** enabled should be able to make an HTTPS request to Ronin through an active Tailscale packet tunnel. Apple makes network access conditional on the keyboard declaring `RequestsOpenAccess = true` and the user enabling Allow Full Access. Tailscale describes its iOS Network Extension as securing traffic from all applications without application changes, while Apple documents that matching routes in a packet-tunnel configuration are sent through that tunnel. Together, those sources support the expected route:

```text
keyboard extension URLSession
  -> iOS system routing
  -> active Tailscale Network Extension
  -> Ronin tailnet address
  -> Tailscale Serve HTTPS
  -> transcription service on Ronin loopback
```

Neither Apple nor Tailscale explicitly guarantees this combination for a *third-party custom keyboard extension*. Treat it as a strong expectation, not a settled fact, until an on-device prototype completes the test matrix below. [Apple: routing VPN traffic](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic) [Tailscale: its iOS Network Extension secures traffic from applications](https://tailscale.com/blog/go-linker)

There is a separate, definitive Apple constraint: a custom keyboard extension has no microphone access, including with Full Access. The keyboard can perform network requests, insert returned text through `textDocumentProxy`, and coordinate with its containing app, but it cannot itself produce Captured Audio. The Recording Session therefore has to occur on another Apple-permitted surface. This is not a Tailscale limitation and a transport prototype cannot remove it. [Apple: custom keyboard extension limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

## Required keyboard permission

The keyboard target must declare the following under `NSExtensionAttributes`:

```xml
<key>RequestsOpenAccess</key>
<true/>
```

The user must then enable **Allow Full Access** for the keyboard in iOS Settings. Without both conditions, the extension sandbox has no network access. Open access also permits the keyboard and containing app to use a shared App Group container. [Apple: RequestsOpenAccess](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/requestsopenaccess) [Apple: configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)

This permission is all-or-nothing from the user's perspective. The keyboard must display a useful local state when Full Access is disabled, but it cannot contact Ronin in that state.

## Tailscale routing on iOS

Tailscale on iOS runs as a Network Extension. Apple packet tunnels install included routes into the system routing table; traffic matching those routes is passed to the tunnel provider. Tailscale's first-party description says its iOS extension secures traffic from applications without those applications changing their networking code. A normal `URLSession` request to a tailnet destination should therefore follow the active Tailscale route. [Apple: packet tunnel provider](https://developer.apple.com/documentation/networkextension/packet-tunnel-provider) [Apple: routing VPN traffic](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic) [Tailscale: iOS Network Extension](https://tailscale.com/blog/go-linker)

Tailscale VPN On Demand can keep the tunnel active across restarts or crashes. It can also connect when iOS observes a request for a hostname ending in `*.ts.net`. Other VPN software can disable Tailscale On Demand because iOS allows only one VPN app to have On Demand enabled at a time. The companion app cannot assume the tunnel is active merely because general Internet connectivity exists. [Tailscale: VPN On Demand for iOS](https://tailscale.com/docs/features/client/ios-vpn-on-demand)

Unresolved until prototype: the sources do not explicitly say that a keyboard-extension process participates in Tailscale routing or triggers the `*.ts.net` On Demand hostname rule. Both behaviors must be tested on the personal iPhone and current iOS/Tailscale versions.

## Addressing and name resolution

Use Ronin's full MagicDNS name as the sole service authority:

```text
https://ronin.<tailnet-name>.ts.net
```

Do not use the short `ronin` hostname as the HTTPS authority. Tailscale can issue a trusted certificate for the full `machine-name.tailnet-name.ts.net` name, but not for a bare machine name. MagicDNS automatically registers each node's machine name and is enabled by default for tailnets; its device-local Quad100 resolver answers tailnet names. A `*.ts.net` endpoint can also participate in the iOS VPN On Demand hostname rule. [Tailscale: HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates) [Tailscale: DNS](https://tailscale.com/docs/reference/dns-in-tailscale) [Tailscale: Quad100 resolver](https://tailscale.com/docs/reference/quad100) [Tailscale: VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)

Ronin also has a stable `100.x.y.z` address. Tailscale documents that a node keeps that address while it remains registered; removal, reset/reinstallation, loss of its node key, or an administrator change can replace it. A direct IP is useful for diagnostics and access-policy selectors, but it is a poor application URL because the public HTTPS certificate is issued to the full MagicDNS name. [Tailscale: IP assignment and stability](https://tailscale.com/docs/concepts/ip-and-dns-addresses)

Set Ronin's Tailscale machine name deliberately and treat changes to that name or the tailnet name as endpoint migrations.

## HTTPS and the Ronin listener

WireGuard already authenticates and encrypts communication between tailnet nodes, but the iOS URL Loading System independently applies App Transport Security (ATS) to apps and app extensions. `URLSession` expects HTTPS with a valid certificate and TLS configuration. Do not add an ATS cleartext exception merely because the connection is inside Tailscale. [Apple: App Transport Security](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) [Tailscale: HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates)

The simplest Ronin exposure is:

1. Bind the transcription HTTP service only to `127.0.0.1:<port>`.
2. Use **Tailscale Serve**, not Funnel, to expose that loopback service at Ronin's HTTPS MagicDNS URL.
3. Enable tailnet HTTPS certificates. This discloses the selected machine name and tailnet DNS name in public certificate-transparency records, but does not make the service publicly reachable.
4. Restrict TCP 443 to the personal iPhone in the tailnet policy.

Tailscale Serve is tailnet-only, provisions HTTPS for the MagicDNS name, applies tailnet access rules, and can proxy to a loopback service. Funnel is the public exposure feature and must remain disabled for this service. [Tailscale: Serve](https://tailscale.com/docs/features/tailscale-serve) [Tailscale: HTTPS certificate disclosure](https://tailscale.com/docs/how-to/set-up-https-certificates)

## Authorization: reachability is necessary but insufficient

Tailscale authenticates a *node*, not the Hex keyboard process. Every network-capable app on the iPhone uses the same Tailscale node identity. Tailnet reachability therefore proves that the request came through an allowed Tailscale device; it does not prove that Hex generated the request.

Use two authorization layers:

1. **Tailnet policy:** grant only the personal iPhone access to Ronin TCP 443. An exact phone Tailscale IP, preferably named by a `hosts` alias, can be a source selector. Ronin can likewise be a destination alias. Remove or narrow any broader rule that already permits the connection: Tailscale grants are additive, so a narrow grant does not override a broader one. [Tailscale: grants syntax and source selectors](https://tailscale.com/docs/reference/syntax/grants) [Tailscale: device visibility](https://tailscale.com/docs/concepts/device-visibility)
2. **Application credential:** require a random, per-install credential on every API request. Provision it out of band during personal setup, never commit or log it, and store it in a Keychain access group shared by the containing app and keyboard extension. Apple documents that targets from the same development team can share Keychain items through a common access group, and that App Groups can also serve as Keychain access groups. [Apple: sharing Keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)

For the first personal deployment, a 256-bit random bearer token over HTTPS is the simplest application credential. It protects the service from other tailnet nodes that are accidentally granted access and from unrelated apps on the same phone that do not possess the token.

### What device identity is available

The Ronin side can map a request's Tailscale source IP to a node ID, machine name, addresses, owner/tags, and granted capabilities through `tailscaled` LocalAPI. `tailscale whois` exposes the same mapping for diagnostics. This identity is cryptographically grounded in the source node's WireGuard keys. [Tailscale: identity in secure connections](https://tailscale.com/docs/concepts/tailscale-identity) [Tailscale: `whois` fields](https://tailscale.com/docs/reference/tailscale-cli#whois) [Tailscale LocalAPI source](https://github.com/tailscale/tailscale/blob/main/ipn/localapi/localapi.go)

Tailscale Serve can instead add authenticated user identity headers and selected application-capability headers before proxying to the loopback backend, stripping client-supplied copies to prevent spoofing. The identity headers identify the Tailscale *user*, not the exact user-owned device. If these headers authorize requests, the backend must remain loopback-only so callers cannot bypass Serve and forge them. [Tailscale: Serve identity and capability headers](https://tailscale.com/docs/features/tailscale-serve) [Tailscale: custom application capabilities](https://tailscale.com/docs/features/access-control/grants/grants-app-capabilities)

There is no documented first-party API through which a third-party keyboard extension can obtain or sign with the Tailscale app's node identity. Do not make the client present a claimed Tailscale device ID. Determine identity on Ronin from the authenticated connection, or use Serve capabilities, and use the separate application credential to identify Hex itself.

## Request authentication and replay behavior

HTTPS prevents passive observers from capturing a bearer token or request in transit. A bearer token alone does not prevent reuse if the token or an entire authenticated request is obtained from a compromised endpoint, diagnostic log, or other TLS termination point.

Use this staged design:

- **Initial personal version:** HTTPS + exact-iPhone tailnet grant + random bearer token. Add a client-generated request ID and make transcription submission idempotent for a short retention window so a timeout/retry cannot run the same Dictation twice. Never place credentials or Captured Audio in URLs or logs.
- **If explicit cryptographic replay resistance becomes a requirement:** MAC each request using the shared Keychain secret. Cover the HTTP method, authority, path, body digest, creation/expiry timestamps, and a cryptographically random single-use nonce. Ronin must reject requests outside a narrow clock window and reject a nonce already seen within that window. RFC 9421 defines HTTP message signatures/MACs, `created`, `expires`, and `nonce`, and specifically identifies nonce uniqueness plus bounded signature age as replay controls. It also states that signatures do not replace TLS. [RFC 9421: HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html) [RFC 2104: HMAC](https://www.rfc-editor.org/info/rfc2104/)

Do not invent the stronger signature scheme ad hoc during MVP implementation. Either implement a narrowly documented RFC 9421 profile with test vectors or keep the simpler bearer-token boundary and state that it does not provide application-layer replay proof.

## Exact fail-closed behavior

Fail closed at both ends:

### Ronin

- Bind the backend only to loopback.
- Expose it only with Tailscale Serve; never configure Funnel and never publish a second public/LAN listener.
- Permit only the phone-to-Ronin HTTPS path in tailnet grants.
- Reject missing or invalid application credentials with no transcription work performed.
- If using Serve identity or capability headers, reject requests when the required value is absent; never trust those headers on a directly reachable backend.

### iOS client

- Configure exactly one server origin: Ronin's HTTPS MagicDNS FQDN. Do not define an Internet hostname, raw LAN address, Apple dictation, cloud ASR, or on-device fallback.
- Treat only a complete, authenticated 2xx response carrying a valid Final Transcript as success.
- On DNS failure, route failure, TLS failure, timeout, connection loss, 401/403, malformed response, or Ronin error, leave the Text Destination unchanged and show an unavailable/error state.
- Do not silently queue Captured Audio for later delivery. A user-initiated retry is a new action; a bounded transport retry to the same tailnet origin must reuse the same idempotency key.
- General network reachability is not proof that Tailscale or Ronin is ready. The authenticated request itself is the readiness test.

If Tailscale is disabled, the private route is absent and the service has no non-tailnet listener, so the request cannot succeed. If the `*.ts.net` VPN On Demand rule brings Tailscale up first, success is still through Tailscale and satisfies this boundary. Another active VPN, a bad On Demand rule, Ronin being offline, a denied grant, or a failed certificate all produce the same fail-closed client outcome. [Tailscale: VPN On Demand behavior and limitations](https://tailscale.com/docs/features/client/ios-vpn-on-demand) [Tailscale: Serve is tailnet-only](https://tailscale.com/docs/features/tailscale-serve)

## Required on-device prototype

The prototype is a transport probe, not a full dictation implementation. It must use the real personal iPhone, a keyboard-extension target, the current Tailscale iOS client, and a minimal HTTPS health endpoint on Ronin.

| Condition | Expected result |
| --- | --- |
| Full Access off; Tailscale connected | Keyboard request is denied by the extension sandbox. |
| Full Access on; Tailscale already connected; Wi-Fi | HTTPS health request succeeds through Serve. |
| Full Access on; Tailscale already connected; cellular | HTTPS health request succeeds through Serve. |
| Full Access on; tunnel disconnected; `*.ts.net` On Demand configured | Determine whether a keyboard-originated request activates Tailscale and measure cold-start latency. |
| Full Access on; Tailscale manually disabled | Request fails; no public or local fallback runs. |
| Another VPN active | Request fails if that VPN has displaced Tailscale. |
| Ronin offline or grant denied | Request fails and leaves the Text Destination unchanged. |
| Invalid application credential | Ronin returns 401/403 without accepting a transcription job. |
| Valid repeated request ID | Ronin does not perform duplicate transcription work. |

For every successful request, record on Ronin whether the observed source maps to the expected iPhone node and whether Serve supplies the expected user/capability headers. Also test whether the keyboard extension remains alive for an upload duration representative of Captured Audio; Apple does not promise unlimited extension execution time.

## Decision for the Wayfinder map

Proceed with Tailscale as the only network path, using Full Access, `URLSession`, Ronin's HTTPS MagicDNS FQDN, Tailscale Serve in front of a loopback-only service, an exact-iPhone tailnet grant, and a separate per-install application credential. Do not claim the keyboard-to-Tailscale route or VPN On Demand activation as resolved until the transport probe passes on the actual phone. Treat keyboard microphone access as impossible under Apple's documented custom-keyboard API and solve the Recording Session handoff in the iOS interaction architecture, not in this network layer.
