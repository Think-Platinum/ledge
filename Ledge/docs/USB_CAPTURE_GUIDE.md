# USB Packet Capture Guide — Xeneon Edge + iCUE on Windows

## Goal

Capture USB HID traffic between iCUE and the Xeneon Edge on a physical Windows machine. This lets us reverse-engineer the proprietary protocol for brightness control, colour profiles, and any widget rendering commands.

## What You Need

- **Physical Windows 10/11 machine** (VMs won't work — USB passthrough loses protocol-level visibility, and DisplayPort Alt Mode doesn't pass through)
- **USB-C port** on the Windows machine (or a USB-C hub that supports DP Alt Mode + data)
- **The Xeneon Edge**, connected via USB-C
- **iCUE** installed and detecting the Edge
- **Admin access** (USBPcap driver install requires it)

## Step 1: Install Wireshark with USBPcap

1. Download Wireshark from **https://www.wireshark.org/download.html** (Windows x64 Installer)
2. Run the installer
3. During installation, when prompted about additional components, **check "Install USBPcap"** — this is the critical step. USBPcap is an open-source USB packet capture driver that Wireshark bundles
4. Complete the installation
5. **Reboot** — the USBPcap kernel driver won't load until you restart

## Step 2: Install iCUE

1. Download iCUE from **https://www.corsair.com/us/en/s/icue** (or your regional Corsair site)
2. Install it but **don't launch it yet** — we want to capture the initial handshake
3. Connect the Xeneon Edge via USB-C
4. Confirm Windows sees it as a display (it should appear in Display Settings)

## Step 3: Identify the Xeneon Edge USB Device

Before capturing, find which USB root hub the Edge is on:

1. Open **Device Manager** (Win+X → Device Manager)
2. Look under **Human Interface Devices** for entries related to "XENEON EDGE" or Corsair
3. Also check **Universal Serial Bus controllers** — note which root hub the Edge is connected to
4. Alternative: open a command prompt and run:
   ```
   USBPcapCMD.exe -d
   ```
   (USBPcapCMD is installed alongside Wireshark, typically in `C:\Program Files\USBPcap\`)
   This lists all USB devices by root hub, making it easy to find the Edge

**Device identifiers to look for:**
- **Corsair control interface**: VID `1B1C`, PID `1D0D` — this is the iCUE HID channel
- **TouchScreen**: VID `27C0`, PID `0859` — the touch controller (less relevant for iCUE capture)

## Step 4: Capture — Initial iCUE Handshake

This capture shows how iCUE initialises communication with the Edge.

1. Open **Wireshark** (run as Administrator for best results)
2. In the capture interface list, you'll see **USBPcap1**, **USBPcap2**, etc. — one per USB root hub
3. Select the USBPcap interface for the root hub where the Edge is connected (if unsure, select all USBPcap interfaces)
4. Click **Start Capture** (shark fin icon)
5. **Now launch iCUE** — let it detect and initialise the Edge
6. Wait for iCUE to fully load and show the Edge in its device list
7. **Stop the capture** (red square)
8. **Save** as `01_icue_init.pcapng` (File → Save As)

## Step 5: Capture — Brightness Control

1. With iCUE running and the Edge connected, start a **new capture** in Wireshark
2. In iCUE, navigate to the Edge's settings
3. **Change the brightness** — slowly drag the slider from current value to minimum, wait 2 seconds, then drag to maximum
4. Stop the capture
5. Save as `02_brightness.pcapng`

## Step 6: Capture — Colour Settings

1. Start a new capture
2. In iCUE, change **colour temperature** or **colour profile** settings for the Edge
3. If available, adjust individual R/G/B gain values
4. Stop and save as `03_colour.pcapng`

## Step 7: Capture — Other Settings

Repeat the capture-action-save pattern for any other iCUE features:

- `04_widget_screens.pcapng` — If iCUE shows widget/dashboard options for the Edge, switch between them
- `05_firmware_info.pcapng` — Navigate to firmware version or device info pages
- `06_power_states.pcapng` — If there's a standby/sleep option in iCUE

**Tip**: Do ONE action per capture. This makes it much easier to correlate packets with specific commands.

## Step 8: Filtering and Analysis

### Basic Filtering

In Wireshark, use these display filters to focus on the Corsair device:

```
# Filter by Corsair vendor ID
usb.idVendor == 0x1b1c

# Filter by the specific control interface
usb.idVendor == 0x1b1c && usb.idProduct == 0x1d0d

# Show only HID reports (SET_REPORT / GET_REPORT)
usb.transfer_type == 0x02 && (usb.setup.bRequest == 0x09 || usb.setup.bRequest == 0x01)

# Show only interrupt transfers (HID input/output reports)
usb.transfer_type == 0x01

# Filter by specific USB device address (replace X.Y with actual values)
usb.addr == "X.Y.0"
```

### Finding the Device Address

1. In the capture, look for USB enumeration packets at the start
2. Find the device with VID `1B1C` and PID `1D0D`
3. Note the bus and device number (shown in the Source/Destination columns, e.g., `1.5.0`)
4. Use `usb.addr == "1.5.0"` to filter all traffic to/from that device

### What to Look For

**HID Output Reports** (computer → device) are the commands iCUE sends. Look for:
- **Report ID** (first byte of the data) — different report IDs likely map to different command types
- **Consistent patterns** — when changing brightness, the same report structure will repeat with different values
- **Byte positions** — correlate slider positions with changing bytes in the report

**HID Input Reports** (device → computer) are responses/state. Look for:
- Status acknowledgments after commands
- Periodic status reports (firmware version, current settings)

### Practical Analysis Tips

1. **Diff captures**: Compare two brightness captures at different levels — the changing bytes are the brightness value
2. **Look at report lengths**: Corsair HID reports are typically 64 or 65 bytes (64-byte payload + optional report ID prefix)
3. **Check for the Corsair protocol header**: Many Corsair devices use a common protocol structure with command type in the first few bytes
4. **Export as hex**: Right-click a packet → Copy → Bytes → Hex Stream — useful for sharing/comparing

## Step 9: Export and Share

For each capture, export the interesting packets:

1. Apply your filter to isolate the Corsair device traffic
2. File → Export Specified Packets → save as a filtered pcapng
3. Also useful: File → Export Packet Dissections → As Plain Text (for readable logs)

Place capture files in `Testing/captures/` in the Ledge repository (they'll be gitignored due to size, but keep them locally for reference).

## Troubleshooting

### "No USBPcap interfaces in Wireshark"
- Ensure USBPcap was selected during Wireshark installation
- Reboot after installation
- Run Wireshark as Administrator
- Check Windows services: USBPcap service should be running

### "Too much traffic / can't find the device"
- Use `USBPcapCMD.exe -d` to identify the exact root hub
- Capture on just that one USBPcap interface, not all of them
- Apply filters immediately after capture

### "iCUE doesn't detect the Edge"
- Ensure the USB-C cable supports data (some cables are charge-only)
- Try a different USB-C port
- Check if the Edge shows up in Device Manager under HID devices
- iCUE may need a firmware update for the Edge — let it update if prompted

### "Capture shows only URB_BULK transfers, no HID"
- The Corsair control interface might use bulk transfers instead of interrupt. This is fine — the protocol analysis approach is the same, just filter by `usb.transfer_type == 0x03` for bulk

## What We're Looking For (Priority Order)

1. **Brightness control** — the single most useful thing to reverse-engineer. Should be a simple value in an HID output report
2. **Colour balance / temperature** — likely a set of RGB gain values
3. **Initialisation handshake** — what iCUE sends on first contact (device identification, firmware query)
4. **Widget/screen content** — whether iCUE sends pixel data or just configuration commands for built-in widget layouts
5. **Power state control** — standby/wake commands (useful for our sleep/lock compliance)
