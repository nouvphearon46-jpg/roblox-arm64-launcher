
Roblox ARM64 Launcher (v1.1 – Early Testing Release)

⚠️ Experimental / Early Release Notice:
I built this launcher myself to run Roblox in full-screen PC mode on ARM64 Linux boards (like Raspberry Pi 5 and Orange Pi 5). It is brand new for ARM processors and is not stable or perfect yet. Because I only own an x86 pcright now and do not have a physical ARM board to test on, I am looking for ARM64 developers and board owners to help test it and report bugs!

What It Does

• Direct-to-Game Full Screen: Runs the official Android Roblox client inside a stripped-down, Google-free VANILLA Waydroid container wrapped in gamescope with mouse-locking.
• No Android Clutter: Hides the Android home screen and system icons, leaving only a single custom black-and-white Roblox icon in your app menu.
• No Google Account Required: Uses Aurora Store in anonymous mode to download and update the official ARM64 Roblox APKs automatically.
• Zero Background Bloat: Locks CPU/GPU/DDR governors to performance while playing and shuts the entire container down when you exit.

How to Install & Test (Debian / Ubuntu / Armbian / Raspberry Pi OS)

bash
curl -fLO https://github.com
sudo apt update && sudo apt install -y ./roblox-arm64-launcher.deb
roblox-launcher setup
roblox-launcher play

Use code with caution.

How You Can Help Improve It

Since this is an early test build, please open a GitHub Issue and share:
1. Which ARM board and OS you tested on (e.g., Raspberry Pi 5, Orange Pi 5, Armbian, Ubuntu).
2. Any errors during setup or play (such as gamescope or GPU driver issues).
3. The output of your diagnostic report:bash
roblox-launcher doctor
Use code with caution.
