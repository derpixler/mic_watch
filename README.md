# mic_watch

Überwacht das macOS-Mikrofon und steuert eine OnAir-Lampe auf einem Raspberry Pi per HTTP.

## Voraussetzungen

- macOS 12+
- Swift (vorinstalliert mit Xcode / Command Line Tools)
- Node.js 18+ (nur für den Pi-Simulator)

## Konfiguration

```bash
cp .env.example .env
```

| Variable        | Beschreibung                          | Default      |
|-----------------|---------------------------------------|--------------|
| `PI_HOST`       | Hostname oder IP des Raspberry Pi     | `localhost`  |
| `PI_PORT`       | HTTP-Port (Watcher + Simulator)       | `8080`       |
| `POLL_INTERVAL` | Polling-Intervall in Sekunden         | `0.5`        |

Umgebungsvariablen überschreiben `.env`-Werte.

## Starten

### Mikrofon-Watcher

```bash
swift mic_watch.swift
```

### Pi-Simulator (lokales Testing)

```bash
node pi_simulator.mjs
```

### Beides zusammen (zwei Terminals)

```bash
# Terminal 1
node pi_simulator.mjs

# Terminal 2
swift mic_watch.swift
```

## ON AIR Display (Echo Show / Browser)

Der Simulator liefert unter `http://<PI_HOST>:<PI_PORT>/` eine Fullscreen-Webseite:

- **Mikrofon aktiv** – roter Hintergrund, grosser "ON AIR"-Schriftzug
- **Mikrofon inaktiv** – schwarzer Bildschirm

Updates kommen per Server-Sent Events (SSE) in Echtzeit, kein Reload noetig.

### Echo Show einrichten

1. *"Alexa, open Silk"*
2. URL eingeben: `http://<PI_HOST>:<PI_PORT>/`
3. Fertig – die Seite bleibt offen (Keep-Alive-Audio ist eingebettet)

### Im Desktop-Browser testen

```
open http://localhost:5001/
```

## Tests

```bash
# Unit-Tests (Simulator-Routen)
node --test test_simulator.mjs

# Integrationstest (startet Simulator automatisch)
bash test_integration.sh
```

## Projektstruktur

```
mic_watch.swift        # Mikrofon-Watcher (CoreAudio + HTTP)
pi_simulator.mjs       # Raspberry Pi HTTP-Simulator + ON AIR Display
test_simulator.mjs     # Unit-Tests für den Simulator
test_integration.sh    # Smoke-/Integrationstest
.env                   # Lokale Konfiguration (nicht committen)
.env.example           # Konfigurationsvorlage
```

## LaunchAgent (Autostart)

Datei `~/Library/LaunchAgents/de.micwatch.plist` anlegen:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>de.micwatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/swift</string>
        <string>/Users/renereimann/Development/mic_watch/mic_watch.swift</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/micwatch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/micwatch.err</string>
</dict>
</plist>
```

```bash
# Aktivieren
launchctl load ~/Library/LaunchAgents/de.micwatch.plist

# Deaktivieren
launchctl unload ~/Library/LaunchAgents/de.micwatch.plist

# Logs prüfen
tail -f /tmp/micwatch.log
```
