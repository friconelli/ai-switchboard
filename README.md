# AI Switchboard

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

## Contesti e aree di lavoro

- **Contesti** (Personale, Studiogusto): indipendenti dagli account. Il contesto di una chat si ricava dalla sua cartella: le aree in `~/Chat AI/<contesto>/` appartengono a quel contesto, i progetti in `~/projects` hanno un contesto assegnabile (predefinito Studiogusto), il resto è “Da assegnare”. Si può forzare il contesto di singole chat.
- **Aree di lavoro**: cartelle in `~/Chat AI/<contesto>/<area>` per le chat che non riguardano un repo, create dall'app con `CLAUDE.md`, `risorse/` e `output/`. Da qui si avviano nuove chat in Warp.
- **Sposta in…**: sposta una o più chat in un'area o in un progetto. Riscrive come testo il `cwd` originale e i percorsi della cartella di supporto, verifica il risultato, sposta tutto in `~/.claude/projects/<cartella codificata>/` e manda l'originale nel Cestino (il nome codificato è il percorso con ogni carattere non alfanumerico sostituito da `-`).
- **Memoria**: i file di memoria si spostano tra progetti/aree aggiornando entrambi i `MEMORY.md`.

Configurazione in `~/Library/Application Support/AISwitchboard/config.json`.

## Come trova gli account

`~/.claude` (predefinito) più ogni `~/.claude-*` che contiene `.claude.json`. Lo storico è condiviso se `projects` è un symlink a `~/.claude/projects`.

## Warp

Con **Apertura diretta** attiva (pagina Account) l'app aggiunge a `~/.zshrc` un blocco delimitato da `# >>> AI Switchboard >>>` (salvando prima una copia in `~/.ai-switchboard/zshrc.backup`). “Riprendi” e “Nuova chat” scrivono il comando in `~/.ai-switchboard/launch/<id>.zsh` con la cartella sulla prima riga e aprono una scheda Warp lì: al primo prompt il blocco esegue il comando di quella cartella (solo se più recente di 30 secondi, una volta per scheda). Disattivandola il blocco viene rimosso.

Senza apertura diretta: incolla il comando nella scheda con ⌘V+Invio (serve il permesso Accessibilità) oppure lo lascia negli appunti. Senza Warp usa Terminale.

## Build

```bash
./Scripts/build_app.sh --install
swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

Richiede macOS 14+ e Xcode.
