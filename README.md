# Latency Monitor Pro 🚀🏹

A native macOS network performance monitor specifically optimized for high-frequency applications like financial trading (ATAS, etc.).

## 📥 Direct Download

For those who just want to run the app without compiling:
- **[Download Latency Monitor (macOS)](./release/Latency%20Monitor.zip)**
- After downloading, unzip the file and move `Latency Monitor.app` to your **Applications** folder.
- *Note: If macOS prevents opening, right-click the app and select 'Open' to bypass Gatekeeper.*

## 🧪 Key Features

- **App Latency (TCP Handshake)**: Measures the real-world responsive lag experienced by your software.
- **Deep Latency (TCP Check)**: Establishes a secondary, independent testing channel to "see" through VPN tunnels and verify true physical route time.
- **Auto-Tracking (Jitter Engine)**: Automatically identifies and focuses on the most active data feed in real-time.
- **Smart Provider Detection**: Identifies traffic from major providers like **dxFeed**, **Rithmic**, **Tradovate**, and **CQG**.
- **Minimalist View**: A collapsible UI that shrinks the window into a tiny, numbers-only dashboard.
- **Always on Top**: Toggle to keep the monitor floating above your charts.

## 🏗 Build & Run

To build the application bundle from source, run:

```bash
./scripts/build_and_install.sh
```

## ⚖️ Disclaimer & License

**EXPERIMENTAL SOFTWARE**: This tool is provided for informational purposes only. © 2026 TraderJan. All rights reserved.
