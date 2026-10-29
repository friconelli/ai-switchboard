# Claude Deck

App macOS (SwiftUI) per orchestrare Claude Code con più account (`claude-fede`, `claude-gusto`, …).

## Funzionalità

- **Chat**: tutte le conversazioni di `~/.claude/projects` con titolo, progetto, account usati, numero di messaggi e dimensione. Ricerca per titolo o nel contenuto (grep), filtri per progetto e account, anteprima della conversazione.
  - **Riprendi** in Warp (o Terminale) scegliendo l'account: `CLAUDE_CONFIG_DIR=… claude --resume <id>` nella cartella giusta.
  - **Rinomina**: scrive gli stessi record di `/rename` (`custom-title`, `agent-name`).
  - **Unisci** 2+ chat (ordine modificabile, nome, progetto di destinazione, riapertura immediata). Per ogni chat prende la conversazione effettiva (catena `parentUuid` dall'ultimo messaggio), salta i messaggi già presenti (chat derivate), toglie il confine di compattazione delle chat successive alla prima trasformandone il riassunto in un messaggio normale, collega tutto in un unico filo, copia tool-results/sub-agenti e file-history aggiornando i percorsi. Il risultato viene verificato (uuid unici, una sola catena) prima di essere salvato; solo allora le chat originali vanno nel Cestino.
  - **Elimina**: sposta nel Cestino la chat e la sua cartella (tool results, subagent). Bloccato se la chat è aperta.
- **Sessioni attive**: processi Claude in esecuzione per account (al lavoro / in attesa), con chiusura.
- **Account**: email, piano, modello, plugin, prompt di oggi, ultimo uso, stato dello storico condiviso; nuova chat in una cartella a scelta.
- **Memoria**: file `memory/*.md` per progetto, modificabili e salvabili.

## Come trova gli account

`~/.claude` (predefinito) più ogni `~/.claude-*` che contiene `.claude.json`. Lo storico è condiviso se `projects` è un symlink a `~/.claude/projects`.

## Warp

Apre una scheda Warp nella cartella della chat e vi incolla il comando (serve il permesso Accessibilità per Claude Deck; senza, il comando resta negli appunti). Senza Warp usa Terminale.

## Build

```bash
./Scripts/build_app.sh --install
swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

Richiede macOS 14+ e Xcode.
