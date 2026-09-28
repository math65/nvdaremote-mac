## NVDA Remote 0.2 (build 4) — 2026-09-28

This is the first public version of NVDA Remote for Mac. It lets you control a Windows PC running NVDA straight from your Mac: you type on your Mac keyboard, and you hear NVDA speak on your Mac, with its beeps and sounds. The app was made with VoiceOver users in mind, and it works just as well if you use it by sight.

### What you can do

- **Connect in a moment.** Click the link NVDA gives you with "Copy link", or type the key yourself. The public server nvdaremote.com works out of the box, and your recent connections are kept for next time.
- **Hear the PC on your Mac.** NVDA's speech comes out of your Mac, in the voice and language NVDA asks for, and it stops as soon as NVDA interrupts itself. You can set the speech rate in Settings.
- **Switch the keyboard with one shortcut.** Press Control-Command-R to type on the PC, and again to come back to the Mac. A high beep means the PC has the keyboard, a low beep means the Mac has it. While you control the PC, every key goes there, VoiceOver commands included.
- **Share the clipboard.** Text copied on the PC lands in your Mac clipboard. Press Control-Command-C to send what you copied on the Mac to the PC.
- **Read NVDA in braille.** If your braille display is a HID model, such as a Brailliant BI X, NVDA takes it over while you control the PC, routing keys and braille keyboard included. VoiceOver gets it back when you return to the Mac.
- **Keep it out of the way.** The app can live in the menu bar, in the Dock, or both.

### New since 0.1

- **Automatic updates.** The app now checks for new versions on its own and installs them when you agree. You can also check at any time from the app menu or the menu bar icon. If you like trying things early, turn on beta versions in Settings, General.
- **Contact the developer from the app.** Help, then Contact the Developer, lets you report a problem, suggest an idea or ask a question. A problem report includes a few technical details to help, but never your channel key or the address of your own server.
- **An icon of its own**, and easier reading for everyone: text that was too pale is darker, explanations that only VoiceOver used to read now show on screen, and shortcuts appear the usual Mac way.

### Before you start

- A Mac with macOS 14 Sonoma or later, and NVDA 2025.1 or later on the PC, with Remote Access turned on.
- To control the PC, allow NVDA Remote under both Accessibility and Input Monitoring, in System Settings, Privacy & Security. The app asks for them from its Keyboard settings.

### Good to know

- Some of NVDA's finer speech details are not followed yet: changes of pitch or volume inside a sentence, and spelling out characters.
- Braille works with HID displays only for now.

### Download

[NVDA-Remote-0.2-4.zip](https://github.com/math65/nvdaremote-mac/releases/download/v0.2/NVDA-Remote-0.2-4.zip)

Unzip it and move NVDA Remote to your Applications folder. The app is signed and checked by Apple. From now on, it will tell you itself when a new version is out.
