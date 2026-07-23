# ClaudeTouchBar

> 🚧 **Beta**: progetto personale in fase sperimentale, costruito e testato su un
> singolo Mac (MacBook Pro 13" M1). Usa API private non documentate da Apple che
> potrebbero rompersi con futuri aggiornamenti macOS — vedi "Note tecniche" sotto.
> Nessuna garanzia, contributi/segnalazioni benvenuti.

Assistente Claude che vive sulla Touch Bar del MacBook Pro: icona persistente nella
Control Strip, sempre visibile qualunque app tu stia usando. Fai domande (scritte o
dettate) o fai analizzare uno screenshot, e la risposta scorre direttamente sulla
Touch Bar — niente finestre, niente comparsa sullo schermo o in registrazioni
(la Touch Bar è un pannello hardware separato dal display).

Usa la CLI `claude` già autenticata su questo Mac (nessuna chiave API/costo aggiuntivo).

Non usa API pubbliche documentate da Apple per l'aggancio alla Control Strip
(`NSTouchBarItem addSystemTrayItem:` + `DFRFoundation`, la stessa tecnica di app
come Pock o BetterTouchTool): per questo **non è distribuibile sul Mac App Store**.
È firmata con un certificato locale stabile (vedi "Firma del codice" sotto) così i
permessi macOS (Registrazione schermo) restano validi tra una build e l'altra.

## Uso

Tre modi per iniziare:
- Tocca l'icona 🤖 nella Control Strip → scegli 💬 (chat), 📸 (screenshot), 🎤 (dettatura)
- **⌥ Option+Spazio** ovunque → apre subito la chat
- **⇧⌥ Shift+Option+Spazio** ovunque → screenshot diretto, nessuna domanda

Per la chat, scrivi con la tastiera fisica (il testo scorre sulla Touch Bar mentre
digiti) e premi Invio. La risposta scorre come ticker; da lì puoi continuare con 💬
o 📸 senza tornare al menu principale. La conversazione mantiene il contesto tra una
domanda e l'altra.

## Build e avvio

```bash
./scripts/build-app.sh   # compila e crea ClaudeTouchBar.app
open ClaudeTouchBar.app
```

## Avvio automatico al login

Apri **Impostazioni di Sistema → Generali → Elementi login**, aggiungi
`ClaudeTouchBar.app` (dopo averlo spostato es. in `/Applications` o tenendolo qui).

## Firma del codice

L'app è firmata con un'identità locale stabile ("ClaudeTouchBar Local Signing"),
creata una volta sola e marcata come attendibile nel Keychain di questo Mac
(cartella `signing/`, in `.gitignore` — contiene il certificato, non versionata).
Firmare sempre con questa identità (non ad-hoc `-`) è quello che permette ai
permessi di sistema (Registrazione schermo) di restare validi dopo ogni ricompilazione.

## Note tecniche

- Nessun App Sandbox, nessun entitlement: serve accesso pieno per usare le API private.
- Gli screenshot vengono salvati in `~/Claude/.touchbar-cache/` (l'unica cartella che
  la CLI `claude` può leggere) e cancellati subito dopo essere stati analizzati.
- Le domande girano con `--safe-mode` (niente CLAUDE.md/hook/plugin/MCP di terze parti)
  e una sessione dedicata (`--session-id`/`--resume`), isolata dalle chat manuali.
- Le scorciatoie globali usano Carbon `RegisterEventHotKey` — non serve il permesso
  di Accessibilità/Input Monitoring che servirebbe con un monitor eventi NSEvent.
- Le API private (`DFRElementSetControlStripPresenceForIdentifier`,
  `addSystemTrayItem:`, `presentSystemModalTouchBar:systemTrayItemIdentifier:`)
  non sono garantite da Apple e potrebbero cambiare con futuri aggiornamenti macOS.
