# PowerLevel

Ultra-lightweight native macOS menu bar battery monitor written in pure Swift (`AppKit` + `IOKit`, zero dependencies).

## Supported Hardware
- **Corsair HS80 MAX Wireless** (`0x1B1C:0x0A97`, Bragi HID protocol)
- **Logitech Bolt Receiver** (`0x046D:0xC548`, HID++ 2.0 Unified Battery `0x1004` — e.g. MX Master 3S, MX Keys Mini for Mac)

## Highlights
- ~215 KB compiled binary, ~15 MB physical RAM footprint, 0% idle CPU
- Native monochrome SF Symbols (`headphones`, `computermouse`, `keyboard`) with uniform sizing and monospaced digits
- Polls every 5 minutes (with 60s timer coalescing) + instant updates on hardware push notifications and wake from sleep
- Built-in **Launch at Login** toggle (`~/Library/LaunchAgents/com.powerlevel.app.plist`)

## Build & Install

```bash
./scripts/bundle.sh
cp -R build/PowerLevel.app /Applications/PowerLevel.app
open /Applications/PowerLevel.app
```
