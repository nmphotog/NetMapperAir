# NetMapper Air

iPhone and iPad version of [NetMapper](https://github.com/nmphotog/NetMapper). Scans your Wi-Fi subnet and lists devices with IP, name and response time, plus a radial map view.

## Run
1. Open `NetMapperAir.xcodeproj` in Xcode 15 or later (iOS 16+).
2. Select the NetMapperAir target → Signing & Capabilities → choose your Team (and change the bundle ID if needed).
3. Run on your iPhone/iPad. Allow Local Network access when asked, then scan again.

## Notes
- iOS doesn't allow apps to read MAC addresses or the ARP table, so devices are found only by probing common TCP ports. Devices that ignore all of them won't appear.
- Only the Wi-Fi (en0) subnet is scanned; subnets larger than /22 are limited to your /24.
