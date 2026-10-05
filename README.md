# WindowUP! — finestre sempre in primo piano (macOS, M2 Max)

App nativa macOS (arm64) che ti permette di **fissare sopra** delle schede web:
mentre navighi su Chrome/Safari ti tieni aperta **WhatsApp come quadratino piccolo,
spostabile e ridimensionabile**, e così via per Gmail, Calendar, YouTube, ChatGPT…

L'app è **già compilata e in esecuzione**: `WindowUP.app` in questa cartella.

## Uso (30 secondi)

1. L'app si apre con la finestra **Gestore** + un esempio **WhatsApp 400×400** già pinnato.
2. Fai login su WhatsApp Web col QR **una sola volta**: resta memorizzato (WKWebView persistente).
3. Trascina il pannello **dalla barra del titolo** per spostarlo, trascina **gli angoli** per ridimensionarlo.
4. Nel Gestore (tab **Siti Web**):
   - **Preset rapidi**: WhatsApp, Telegram, Gmail, Calendar, YouTube, ChatGPT, Spotify, Google.
   - **App attive**: un box con le app aperte sul Mac (OpenCode, Sublime Text, Packet Tracer…) — un click la porta davanti e il watchdog "tieni davanti" la riporta sopra ogni secondo (sperimentale, richiede Accessibilità).
   - **Nuova finestra pinnata**: incolla un URL qualsiasi + scegli la misura (Quadrato/Piccolo/Medio/Grande).
   - Per ogni finestra: Mostra/Nascondi, opacità, larghezza/altezza, `Extra-sopra`, `Tutti gli Spaces`.
5. Menu comandi: `⌘N` nuova finestra, `⇧⌘M` mostra tutte, `⇧⌘H` nascondi tutte.

### Dettagli utili

- **Sempre sopra**: livello `.floating` di default; attiva `Extra-sopra (fullscreen)` per livello `.screenSaver` (sta sopra anche alle app a tutto schermo).
- **Spaces**: `Visibile in tutti gli Spaces` = segue il desktop; disattivalo per legarla a uno Space.
- **Toolbar di ogni pannello**: indietro/avanti/reload, barra indirizzi, ⚙️ con opacità + misure rapide.
- **Persistenza**: le finestre vengono salvate e riaperte al riavvio.
- **Login**: cookie/localStorage persistiti in `WKWebsiteDataStore.default`, quindi Gmail/WhatsApp restano loggati.

## App native: Terminale, VS Code, ecc. (tab "App e Finestre")

Oltre ai siti web, WindowUP! gestisce le **finestre delle app reali** con la stessa tecnica di Floaty:

- **App attive** (tab Siti Web): un box con le app aperte sul Mac — un click porta l'app davanti e crea uno **sticker live sempre-sopra** (~15fps via ScreenCaptureKit). Click sullo sticker = torni alla finestra vera.
- **Sticker live**: pannelli flottanti con il flusso video della finestra (funziona anche se coperta), opacità, click-through, Extra-sopra. Dal pannello: **Vai alla finestra** per interagire con l'originale.
- **Apri app**: pulsanti rapidi per Terminale, VS Code, Note, Monitoraggio Attività + "Scegli app…" + "Attiva".

> Limite onesto: macOS 15/26 **blocca** il vero always-on-top interattivo cross-process (verificato: `CGSSetWindowLevel` su finestre altrui è no-op). L'anteprima live nel proprio pannello è l'approccio stabile senza SIP. Per interagire si usa il pulsante "Vai alla finestra".

**Permessi necessari** (l'app li indica da sola nel tab):
- **Registrazione schermo** (Privacy e Sicurezza): necessaria per titoli e anteprime. Senza, la lista mostra le app ma senza titoli e le anteprime restano vuote.
- **Accessibilità** (consigliata): per portare le app in primo piano con "Attiva".

## Verdetto tecnico (testato su questo Mac, non teoria)

- `CGSSetWindowLevel` su finestra altrui: ritorna successo, **pixel identici prima/dopo** (test con screenshot + hash). Non fa nulla.
- `AXRaise`: accettato, nessun effetto visivo. `CGSOrderWindow`: errore.
- Floaty e simili usano **mirror ScreenCaptureKit**, non pin vero (lo dicono loro).
- Pin vero interattivo = solo yabai + SIP allentato (guida nel tab App e Finestre).

Per sicurezza macOS **non permette** di incorporare in modo interattivo la finestra di *un'altra app nativa*
(es. l'app WhatsApp dal Mac App Store) dentro la propria finestra, né di forzarla "always on top" con API pubbliche.

Per questo WindowUP! usa le **versioni web** (`web.whatsapp.com`, `web.telegram.org`, `mail.google.com`…),
che sono complete e interattive. È l'approccio corretto e stabile.
Per le app native (Terminale, VS Code…) c'è il tab **App e Finestre**: **Terminale integrato** (vero, sempre sopra),
**sticker live** stile Floaty, anteprime + Vai alla finestra — vedi sopra.

## Installazione stabile

```bash
# Copia in Applicazioni (consigliato)
cp -R "WindowUP.app" /Applications/
open /Applications/WindowUP.app
```

Al primo avvio con firma ad-hoc, se macOS blocca: tasto destro su `WindowUP.app` → Apri → Apri.

## Ricompilare / modificare

Serve Xcode (testato con Xcode 26.2, macOS su M2 Max, target macOS 13+).

```bash
cd "/Users/liamdimarzio/Documents/programmi/WindowUP!"
# Debug
xcodebuild -project WindowUP.xcodeproj -scheme WindowUP -configuration Debug build
# Release + copia fresca
xcodebuild -project WindowUP.xcodeproj -scheme WindowUP -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/WindowUP-*/Build/Products/Release/WindowUP.app ./WindowUP.app
```

Oppure apri `WindowUP.xcodeproj` in Xcode e premi `⌘R`.

Struttura codice (`WindowUP/`):

- `WindowUPApp.swift` — entrypoint + AppDelegate (ripristino sessione)
- `ContentView.swift` — Gestore a tab: Siti Web + App e Finestre, Settings
- `PanelManager.swift` — crea/gestisce/salva gli `NSPanel` web
- `WindowPinning.swift` — elenco finestre altrui (CGWindowList), apertura/attivazione app, permessi
- `MirrorManager.swift` — anteprime live view-only delle app native in pannelli flottanti
- `AppWindowsView.swift` — tab App e Finestre (apri app, anteprime, permessi)
- `FloatingPanel.swift` — `NSPanel` always-on-top, spostabile/ridimensionabile
- `FloatingWebView.swift` — `WKWebView` con User-Agent Safari + toolbar
- `Models.swift` — `PinnedItem`, preset, misure

## Troubleshooting

- **WhatsApp dice "browser non supportato"**: risolto via User-Agent Safari desktop. Se ricapita, ricarica con `⟳` nel pannello.
- **Non sta sopra un'app a fullscreen**: attiva `Extra-sopra` nelle impostazioni del pannello (⚙️).
- **Dopo il riavvio chiede di nuovo il QR**: hai cancellato i dati web di sistema o cambiato `WKWebsiteDataStore` — normalmente non succede.
- **Firma**: build ad-hoc (`CODE_SIGN_IDENTITY = -`, sandbox disattivata, solo `network.client`). Per distribuire: imposta un Team in Xcode.
