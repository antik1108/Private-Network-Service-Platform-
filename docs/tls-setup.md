# TLS Setup, Certificate & Trust

## How it is set up (Phase 2)

- **CA:** Vansh's local mkcert CA (`mkcert vansh@MacBook-Pro-13.local`), the same CA used in Phase 1. Its public certificate is committed as [`tls/teamX-root-ca.crt`](../tls/teamX-root-ca.crt). The CA private key never leaves Mac 2.
- **Edge certificate:** [`tls/app.teamX.test.crt`](../tls/app.teamX.test.crt). SAN `DNS:app.teamX.test, DNS:api.teamX.test`, valid 22 Nov 2026 – 22 Feb 2029. Issued on Mac 2 with:
  ```bash
  mkcert -cert-file app.teamX.test.crt -key-file app.teamX.test.key app.teamX.test api.teamX.test
  ```
  (`scripts/deploy.sh --tls` does this and distributes the files.)
- **Key:** `~/cn-project/tls/app.teamX.test.key` (mode 600) on Mac 2 **and** on Mac 3/4. The standby edge must present the same certificate for the same name (Extension E). Keys are gitignored. Phase 1 broke precisely because the key lived inside the git checkout and was lost on re-clone.
- **nginx:** `listen 443 ssl; http2 on; ssl_protocols TLSv1.2 TLSv1.3;` (see [`nginx/nginx.conf.template`](../nginx/nginx.conf.template)).

## Trust on each client Mac

```bash
sudo scripts/phase2/client-setup.sh        # adds the CA to the System keychain (+ sets DNS)
# or only the trust step:
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain tls/teamX-root-ca.crt
```
This must be run **at the Mac itself**: over SSH, macOS refuses with `The authorization was denied since no user interaction was possible`. Without trust you can still verify properly against the CA with `curl --cacert tls/teamX-root-ca.crt …`. Never use `-k` in the demo.

## Verify

```bash
curl -v https://app.teamX.test/api/status 2>&1 | grep -E 'ALPN|subject|issuer|verify|HTTP/'
openssl s_client -connect app.teamX.test:443 -servername app.teamX.test -CAfile tls/teamX-root-ca.crt -verify_return_error </dev/null | grep -E 'Verify return|Protocol'
```
Expected: `SSL certificate verify ok`, `ALPN: server accepted h2`, `HTTP/2 200`, `Verify return code: 0 (ok)`.

## Handshake to explain (see `evidence/phase2/captures/phase1-full-flow-lan.pcapng`)

TLS 1.2 (stream 0): ClientHello (SNI `app.teamx.test`, cipher list, ALPN) → ServerHello + **Certificate** → ServerKeyExchange (ECDHE params) + ServerHelloDone → ClientKeyExchange + ChangeCipherSpec + Finished → ChangeCipherSpec + Finished → encrypted Application Data.
TLS 1.3 (stream 2): ClientHello (with key share) → ServerHello, and everything after it, including the Certificate, is encrypted. That's why we capture with `--tls-max 1.2` to show the certificate.
