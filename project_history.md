# Latency Monitor Pro: Technical History 📜

This document preserves the development journey, key design decisions, and technical solutions implemented during the creation of the Latency Monitor Pro for macOS.

## 🏁 The Starting Point
The project began as a port of a **PowerShell-based Windows script**. The goal was to create a native, premium macOS application using Swift and SwiftUI that could provide real-time latency metrics for financial trading platforms (e.g., ATAS).

## 🛠 Technical Hurdles & Solutions

### 1. Network Monitoring without Root
**Challenge**: Traditional network monitoring often requires `sudo` or packet-capture privileges.
**Solution**: I leveraged the native macOS `lsof -iTCP -sTCP:ESTABLISHED` command to track socket connections without requiring administrative privileges, ensuring a seamless user experience.

### 2. Smart Process Grouping
**Challenge**: High-performance apps often spawn multiple PIDs or separate processes for UI and Data.
**Solution**: Implemented a grouping engine that uses `ps` to fetch full command names, automatically aggregating all connections under a single user-friendly application name (e.g., grouping all "Antigravity" instances into one entry).

### 3. The "Deep Ping" Evolution
**Challenge**: Standard ICMP (Ping) is often blocked by AWS or obscured by VPN tunnels like NordVPN.
**Solution**: Developed a dual-latency system:
- **App Latency**: Measures the handshake of the active trading connection.
- **Deep Latency**: Originally ICMP, but switched to a **TCP Handshake check** to reliably "see through" VPNs and work across cloud-provider restrictions.

### 4. Provider Detection Engine
**Challenge**: Users need to know exactly which data feed is being measured.
**Solution**: Built a lookup engine that identifies specific IP ranges and ports associated with major trading providers:
- **dxFeed**: Detecting AWS and proprietary hostname patterns.
- **Rithmic**: Monitoring specific 645x port ranges.
- **Tradovate & CQG**: Integration of known enterprise host patterns.

## 🎨 UI/UX Design Decisions

### 1. Minimalist "Numbers Only" View
- **Problem**: Users wanted a way to hide the technical connection list to save screen real estate.
- **Solution**: Implemented a **Dynamic Resizing Window**. When switched to Compact Mode, the window physically contracts its height to 140pts, showing only the critical latency numbers and the provider badge.

### 2. Aesthetic Alignment
- **Right-Alignment**: Specifically requested to match the user's preferred workspace layout.
- **TJ Branding**: Created a custom macOS squircle icon using minimalist design principles (inspired by NotebookLM) with discreet "TJ" branding.

## 🚀 Infrastructure & Deployment
- **Automated Bundling**: Created a `build_and_install.sh` script to handle Swift compilation, icon setting, and `.app` packaging.
- **Release Channel**: Added a synchronous `release/` folder within the Git repo to allow direct downloads of the pre-compiled binary.
- **GitHub Integration**: Setup using the `gh` CLI for professional version control.

---
*© 2026 TraderJan. Created in collaboration with Antigravity.*
