# mic_watch

Überwacht das macOS-Mikrofon und steuert eine USB-Lampe auf einem Raspberry Pi per HTTP –
als "On Air"-Anzeige vor der Bürotür.

## Architektur

```
┌─────────────────┐          HTTP           ┌──────────────────┐
│  Mac             │  ── /on  ──────────▶   │  Raspberry Pi    │
│  mic_watch.swift │  ── /off ──────────▶   │  pi_server.mjs   │
│  (Polling 500ms) │                        │  ↕ uhubctl       │
└─────────────────┘                         │  ↕ USB-Lampe 💡  │
                                            └──────────────────┘
```

## Voraussetzungen

**Mac (Sender):**
- macOS 12+
- Swift (vorinstalliert mit Xcode / Command Line Tools)

**Raspberry Pi (Empfänger):**
- Raspberry Pi OS (Bookworm / Bullseye)
- Node.js 18+
- uhubctl
- USB-LED-Lampe (ohne Schalter, leuchtet sofort bei Strom)

## Schnellstart

### 1. Raspberry Pi einrichten

**Option A: SD-Karte am Mac vorbereiten (empfohlen)**

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) herunterladen
2. **Raspberry Pi OS Lite** auf SD-Karte flashen
   - Im Imager unter "OS anpassen": SSH aktivieren, WLAN konfigurieren, Hostname `onair` setzen
3. SD-Karte auswerfen, neu einstecken, dann:

```bash
bash prepare_sd.sh
```

4. SD-Karte in den Pi, Strom an, ~5 Minuten warten – fertig.

**Option B: Manuell per SSH**

```bash
git clone <repo-url> ~/mic_watch
cd ~/mic_watch
bash pi_setup.sh
```

Beide Wege installieren Node.js, uhubctl, deployen den Server nach `/opt/mic_watch`
und erstellen einen systemd-Service der automatisch startet.

### 2. USB-Lampe testen

```bash
# USB-Hubs und Ports anzeigen
sudo uhubctl

# Lampe ein
sudo uhubctl -l 1-1 -a on

# Lampe aus
sudo uhubctl -l 1-1 -a off
```

Der `-l` Parameter (Location) hängt vom Pi-Modell ab. Die Ausgabe von `sudo uhubctl`
zeigt alle verfügbaren Hubs. Bei Bedarf den Wert in `/opt/mic_watch/.env` anpassen.

### 3. Mac konfigurieren

IP des Raspberry Pi ermitteln (z.B. `hostname -I` auf dem Pi), dann in `.env` eintragen:

```bash
cp .env.example .env
```

```
PI_HOST=192.168.1.42
PI_PORT=8080
POLL_INTERVAL=0.5
```

### 4. Watcher starten

```bash
swift mic_watch.swift
```

Sobald ein Programm das Mikrofon nutzt (Zoom, Teams, FaceTime, ...), geht die Lampe am Pi an.

## Konfiguration

### Mac (.env)

| Variable        | Beschreibung                          | Default      |
|-----------------|---------------------------------------|--------------|
| `PI_HOST`       | Hostname oder IP des Raspberry Pi     | `localhost`          |
| `PI_PORT`       | HTTP-Port des Pi-Servers              | `8080`               |
| `POLL_INTERVAL` | Polling-Intervall in Sekunden         | `0.5`                |
| `SESSION_DIR`   | Verzeichnis für tagesbasierte Session-CSVs | `~/Library/Application Support/mic_watch/sessions` |

### Raspberry Pi (/opt/mic_watch/.env)

| Variable        | Beschreibung                           | Default                          |
|-----------------|----------------------------------------|----------------------------------|
| `PI_HOST`       | Bind-Adresse des Servers               | `0.0.0.0`                        |
| `PI_PORT`       | HTTP-Port                              | `8080`                           |
| `LAMP_CMD_ON`   | Shell-Befehl: Lampe ein               | `sudo uhubctl -l 1-1 -a on`     |
| `LAMP_CMD_OFF`  | Shell-Befehl: Lampe aus               | `sudo uhubctl -l 1-1 -a off`    |

Ohne `LAMP_CMD_ON`/`LAMP_CMD_OFF` läuft der Server im Simulator-Modus (keine Hardware).

## Lokales Testen (ohne Pi)

Beide Skripte auf dem Mac starten – der Server läuft im Simulator-Modus:

```bash
# Terminal 1 – Server (Simulator)
node pi_simulator.mjs

# Terminal 2 – Watcher
swift mic_watch.swift

# Browser – ON AIR Display
open http://localhost:5001/
```

## Session-Log (Telefonat-Protokoll)

Jede Mikrofon-Nutzung wird tagesbasiert in CSV-Dateien aufgezeichnet:

- **Verzeichnis:** `~/Library/Application Support/mic_watch/sessions/` (Standard)
- **Dateien:** `2026-03-19.csv`, `2026-03-20.csv`, …

```csv
start,end,duration_min
2026-03-19T11:30:04Z,2026-03-19T11:45:12Z,15.1
2026-03-19T14:02:00Z,2026-03-19T14:18:33Z,16.6
```

Spalten: **Start** (ISO 8601), **Ende**, **Dauer in Minuten**.

```bash
# Heutige Sessions
cat ~/Library/Application\ Support/mic_watch/sessions/$(date +%Y-%m-%d).csv

# Gesamtdauer heute (benötigt awk)
awk -F, 'NR>1{s+=$3}END{printf "%.1f min\n",s}' ~/Library/Application\ Support/mic_watch/sessions/$(date +%Y-%m-%d).csv

# Alle Sessions eines Tages
ls ~/Library/Application\ Support/mic_watch/sessions/
```

Der Pfad ist per `SESSION_DIR` in `.env` konfigurierbar. Wird der Prozess per Signal
beendet (SIGTERM/SIGINT), wird eine laufende Session sauber geschlossen.

## ON AIR Web-Display

Der Server liefert unter `http://<PI_HOST>:<PI_PORT>/` eine Fullscreen-Webseite:

- **Mikrofon aktiv** – roter Hintergrund, grosser "ON AIR"-Schriftzug
- **Mikrofon inaktiv** – schwarzer Bildschirm

Updates kommen per Server-Sent Events (SSE) in Echtzeit.

## Tests

```bash
# Unit-Tests (Server-Routen)
node --test test_simulator.mjs

# Integrationstest (startet Server automatisch)
bash test_integration.sh
```

## Projektstruktur

```
mic_watch.swift        # Mac: Mikrofon-Watcher (CoreAudio + HTTP)
sessions/YYYY-MM-DD.csv  # Mac: Tagesbasierte Session-Logs (in SESSION_DIR)
pi_simulator.mjs       # Server: HTTP + SSE + Lampensteuerung
pi_setup.sh            # Pi: Manuelles Setup-Skript (per SSH)
pi_firstboot.sh        # Pi: Automatisches Setup beim ersten Boot
prepare_sd.sh          # Mac: SD-Karte für den Pi vorbereiten
test_simulator.mjs     # Unit-Tests für den Server
test_integration.sh    # Smoke-/Integrationstest
.env                   # Lokale Konfiguration (nicht committen)
.env.example           # Konfigurationsvorlage
```

## Pi-Verwaltung

```bash
# Service-Status
sudo systemctl status mic-watch

# Logs (live)
sudo journalctl -u mic-watch -f

# Neustart nach Config-Änderung
sudo systemctl restart mic-watch

# Lampe manuell testen
curl http://localhost:8080/on
curl http://localhost:8080/off
curl http://localhost:8080/status
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
# Aktivieren
launchctl load ~/Library/LaunchAgents/de.micwatch.plist

# Deaktivieren
launchctl unload ~/Library/LaunchAgents/de.micwatch.plist

# Logs
tail -f /tmp/micwatch.log
```

## Hardware

### Empfohlene USB-Lampe

Eine einfache USB-LED ohne Schalter und ohne Akku, die sofort leuchtet wenn Strom anliegt:

- **USB LED Mini Stick rot** (~3-5 EUR, Amazon/eBay)
- Alternativ: USB-Notebooklampe (flexibel, biegbar)

Wichtig: Kein eingebauter Schalter, kein Akku, kein Sensor – nur "Strom an = Licht an".

### Hinweis zu uhubctl

Beim Raspberry Pi 4 werden alle USB-Ports gleichzeitig geschaltet (ganged power switching).
Wenn andere USB-Geräte angeschlossen sind, einen USB-Hub mit Per-Port-Switching verwenden.
Kompatible Hubs: https://github.com/mvp/uhubctl#compatible-usb-hubs
