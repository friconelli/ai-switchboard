# AI Switchboard

App macOS (SwiftUI) per orchestrare Claude Code con più account (`claude-fede`, `claude-gusto`, …).

## Funzionalità

- **Chat**: tutte le conversazioni di `~/.claude/projects` con titolo, progetto, account usati, numero di messaggi e dimensione. Ricerca per titolo o nel contenuto (grep), filtri per progetto e account, anteprima della conversazione.
  - **Riprendi** in Warp (o Terminale) scegliendo l'account: `CLAUDE_CONFIG_DIR=… claude --resume <id>` nella cartella giusta.
  - **Rinomina**: scrive gli stessi record di `/rename` (`custom-title`, `agent-name`).
  - **Unisci** 2+ chat (ordine modificabile, nome, progetto di destinazione, riapertura immediata). Per ogni chat prende la conversazione effettiva (catena `parentUuid` dall'ultimo messaggio), salta i messaggi già presenti (chat derivate), toglie il confine di compattazione delle chat successive alla prima trasformandone il riassunto in un messaggio normale, collega tutto in un unico filo, copia tool-results/sub-agenti e file-history aggiornando i percorsi. Il risultato viene verificato (uuid unici, una sola catena) prima di essere salvato; solo allora le chat originali vanno nel Cestino.
  - **Dividi** una chat lunga in più chat, una per argomento (✂︎ nella barra o "Dividi in argomenti…"). La storia completa viene ricostruita anche oltre le compattazioni e tagliata in turni (un tuo messaggio + tutto quello che fa Claude fino al successivo), così le chiamate ai tool restano con i loro risultati. I turni si assegnano agli argomenti a mano (tasti 1–9, ⇧-clic per gli intervalli) o con "Proponi", che chiede a Claude Haiku (`claude -p --no-session-persistence`, nessun tool) di raggrupparli. Un turno può stare in più argomenti. Ogni argomento diventa una chat con il suo titolo e la sua cartella; facoltativamente parte con un riassunto del contesto originale scritto da Haiku nel formato delle compattazioni di Claude Code. Tutte le chat vengono verificate prima di essere salvate; l'originale va nel Cestino solo se è andato tutto bene (opzione disattivabile).
  - **Snellisci** una o più chat sul posto (stesso ID, stessa voce in /resume), categoria per categoria con il risparmio stimato in MB e token: dati tecnici (log `api-request*`, metadati ripetuti, promemoria automatici, rami annullati), screenshot/immagini/PDF letti dai tool, output lunghi (oltre 4.000 caratteri resta inizio e fine), output superati da una rilettura identica, ragionamenti interni (tranne l'ultimo turno); facoltativi le immagini incollate e la storia prima dell'ultima compattazione. Le chiamate ai tool restano sempre, con risultato accorciato; i messaggi tolti vengono scavalcati ricollegando i figli. La copia viene verificata (stessa conversazione per Claude, stesso ordine, tool call e risultati appaiati) prima di sostituire l'originale, che va nel Cestino.
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

Se l'apertura diretta non è attiva, al primo “Riprendi” l'app chiede di attivarla (“Attiva e apri”) oppure apre la scheda lasciando il comando negli appunti. Il vecchio metodo con ⌘V simulato è stato tolto: con la firma ad-hoc il permesso Accessibilità si perde a ogni build. Senza Warp usa Terminale.

## Build

```bash
./Scripts/build_app.sh --install
swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

Richiede macOS 14+ e Xcode.
