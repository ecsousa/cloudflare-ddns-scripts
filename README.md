# cf-ddns

Small cross-platform (Windows/macOS) self-contained app that keeps a Cloudflare A record synced to your machine’s current IPv4. It checks your default-route interface every 30s, compares against the last local IP (Cloudflare is only read on startup), and updates the record with a 60s TTL when it changes. Proxied flag is preserved.

## Download
Grab the latest binaries from the GitHub Releases page (Assets section):
  - `cf-ddns-win-x64.exe`
  - `cf-ddns-macos-x64` (Intel)
  - `cf-ddns-macos-arm64` (Apple Silicon)

Make sure the binary is executable (`chmod +x cf-ddns-macos-*` on macOS).

## Usage
Set your environment variables:
```
CLOUDFLARE_API_TOKEN=<token with DNS edit rights>
# optionally one of:
# CLOUDFLARE_ZONE_ID=<zone id>
# CLOUDFLARE_ZONE_NAME=<zone, e.g., example.com>
```
Run:
```
./cf-ddns-<platform> <hostname>
```

## macOS launchd (daemon)
1) Copy binary somewhere stable, e.g. `/usr/local/bin/cf-ddns`:
```
sudo install -m 755 cf-ddns-macos-arm64 /usr/local/bin/cf-ddns   # Apple Silicon
# or: sudo install -m 755 cf-ddns-macos-x64 /usr/local/bin/cf-ddns   # Intel
```
2) Copy and edit the plist template:
```
cp macos-cf-ddns.plist ~/Library/LaunchAgents/com.example.cf-ddns.plist
# edit ProgramArguments and EnvironmentVariables for your path/hostname/token
```
3) Load and start:
```
launchctl load -w ~/Library/LaunchAgents/com.example.cf-ddns.plist
```
Logs: `/tmp/cf-ddns.log`, `/tmp/cf-ddns.err`. Disable with `launchctl unload -w ...`.

## Windows service (NSSM)
1) Place `cf-ddns-win-x64.exe` in a stable path, e.g. `C:\cf-ddns\cf-ddns.exe`.
2) Install NSSM (https://nssm.cc/download) and run:
```
nssm install cf-ddns "C:\cf-ddns\cf-ddns.exe" <hostname>
```
3) In the NSSM GUI:
   - Set `AppDirectory` to `C:\cf-ddns`.
   - On the Environment tab add:
     - `CLOUDFLARE_API_TOKEN=...`
     - optionally `CLOUDFLARE_ZONE_ID=...` or `CLOUDFLARE_ZONE_NAME=...`
4) Start the service:
```
nssm start cf-ddns
```
Check with `nssm status cf-ddns`, stop with `nssm stop cf-ddns`.

## Notes
- Poll interval: 30s; TTL: 60s (Cloudflare minimum).
- Cloudflare DNS is read once on startup; afterwards changes are driven by local IP changes only.
- Proxied flag is preserved when updating.
