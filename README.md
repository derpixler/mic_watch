# mic_watch

Überwacht das macOS-Mikrofon und schaltet eine **Shelly AZ Plug** (oder kompatibles Relay) per HTTP –
als „On Air“-Anzeige (z. B. Lampe an der Steckdose).

## Architektur

```
┌─────────────────┐          HTTP GET           ┌──────────────────┐
│  Mac             │  relay/0?turn=on/off  ───▶  │  Shelly AZ Plug  │
│  mic_watch.swift │                             │  (WLAN)          │
│  (Polling)       │                             └──────────────────┘
└─────────────────┘
```

## Voraussetzungen

- macOS 12+
- Swift (Xcode oder Command Line Tools)
- Shelly AZ Plug im gleichen WLAN wie der Mac (2,4 GHz), lokale HTTP-API aktiv

## Schnellstart

1. Shelly per App einrichten, **IP-Adresse** notieren (Router oder Shelly-App).

2. Konfiguration:

```bash
cp .env.example .env
```

`.env` anpassen:

```
SHELLY_IP=192.168.1.100
POLL_INTERVAL=0.5
```

3. Manuell testen:

```bash
curl "http://192.168.1.100/relay/0?turn=on"
curl "http://192.168.1.100/relay/0?turn=off"
```

4. Watcher starten:

```bash
swift mic_watch.swift
```

Sobald ein Programm das Mikrofon nutzt (Zoom, Teams, FaceTime, …), schaltet die Shelly ein.

## Konfiguration (.env)

| Variable         | Beschreibung                                      | Default |
|------------------|---------------------------------------------------|---------|
| `SHELLY_IP`      | IP-Adresse des Shelly im LAN (**Pflicht**)        | –       |
| `POLL_INTERVAL`  | Abfrageintervall in Sekunden                      | `0.5`   |
| `SESSION_DIR`    | Verzeichnis für tagesbasierte Session-CSVs        | siehe unten |

Ohne `SHELLY_IP` beendet sich der Watcher mit einer Fehlermeldung.

## Session-Log (Telefonat-Protokoll)

Jede Mikrofon-Nutzung wird tagesbasiert in CSV-Dateien aufgezeichnet:

- **Verzeichnis:** `~/Library/Application Support/mic_watch/sessions/` (Standard)
- **Dateien:** `2026-03-19.csv`, `2026-03-20.csv`, …

```csv
start,end,duration_min
2026-03-19T11:30:04Z,2026-03-19T11:45:12Z,15.1
```

Der Pfad ist per `SESSION_DIR` in `.env` konfigurierbar. Beenden mit SIGTERM/SIGINT schließt eine laufende Session sauber.

## Projektstruktur

```
mic_watch.swift        # Mac: Mikrofon-Watcher (CoreAudio + HTTP → Shelly)
.env / .env.example    # Konfiguration
```

## Mac Autostart (LaunchAgent)

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
launchctl load ~/Library/LaunchAgents/de.micwatch.plist
```

**Neustart nach Änderungen:** Ein laufender Job lädt `.env` und `mic_watch.swift` nicht automatisch neu. Nach Anpassungen an der plist, am Skript oder an `.env` den Dienst neu starten:

```bash
# Variante A: entladen und wieder laden
launchctl unload ~/Library/LaunchAgents/de.micwatch.plist
launchctl load ~/Library/LaunchAgents/de.micwatch.plist
```

```bash
# Variante B: Job beenden und neu starten (bei KeepAlive)
launchctl kickstart -k gui/$(id -u)/de.micwatch
```

Deaktivieren:

```bash
launchctl unload ~/Library/LaunchAgents/de.micwatch.plist
```

Logs live (stdout + stderr, wie in der plist oben):

```bash
tail -f /tmp/micwatch.log /tmp/micwatch.err
```

Nur Standardausgabe:

```bash
tail -f /tmp/micwatch.log
```

## Hardware

### Shelly AZ Plug

WLAN-Steckdose mit lokaler HTTP-API:

- Einschalten: `GET http://<IP>/relay/0?turn=on`
- Ausschalten: `GET http://<IP>/relay/0?turn=off`

Lampe oder „On Air“-Leuchte an die Steckdose – kein Raspberry Pi nötig.

- [Amazon (Beispiel)](https://www.amazon.de/dp/B0CQPCX7RN) · Shelly Shop
