# AI Switchboard

App macOS (SwiftUI) per gestire le chat di Claude Code, anche con più account: cercarle, riprenderle, unirle, dividerle, snellirle, organizzarle in aree di lavoro e partire con chat già informate dallo storico.

## Installazione

1. Scarica `AISwitchboard.zip` dall'[ultima release](https://github.com/friconelli/ai-switchboard/releases/latest), aprilo e trascina **AISwitchboard.app** in Applicazioni.
2. L'app non è firmata con un certificato Apple, quindi al primo avvio macOS la blocca: apri **Impostazioni di Sistema → Privacy e sicurezza** e, in fondo, premi **Apri comunque** accanto ad AISwitchboard (in alternativa, da Terminale: `xattr -dr com.apple.quarantine /Applications/AISwitchboard.app`). Serve solo la prima volta: gli aggiornamenti scaricati dall'app non lo richiedono.
3. Al primo avvio la **configurazione guidata** chiede gli account Claude (quelli già presenti o nuovi, con login), le cartelle delle chat e dei progetti, i contesti e le prime aree di lavoro. Si riapre da Account → *Configurazione guidata…*.

Requisiti: macOS 14+, [Claude Code](https://claude.com/claude-code) installato. [Warp](https://www.warp.dev) consigliato (altrimenti usa Terminale).

## Aggiornamenti

L'app controlla all'avvio (al massimo ogni 6 ore) l'ultima release su GitHub; se ce n'è una nuova lo segnala in fondo alla barra laterale. **Aggiorna e riavvia** scarica `AISwitchboard.zip`, verifica che sia AI Switchboard con la versione attesa, sostituisce l'app (la vecchia va nel Cestino) e la riapre. Controllo manuale da *AI Switchboard → Controlla aggiornamenti…* o dalla pagina Account, dove si può disattivare il controllo automatico.

Per pubblicare una versione: `Scripts/release.sh 1.2.0 "Note di rilascio"` (imposta la versione, compila, crea lo zip e la release con `gh`).

## Funzionalità

- **Chat**: tutte le conversazioni di `~/.claude/projects` con titolo, progetto, account usati, numero di messaggi e dimensione. Ricerca per titolo o nel contenuto (grep), filtri per progetto e account, anteprima della conversazione.
  - **Riprendi** in Warp (o Terminale) scegliendo l'account: `CLAUDE_CONFIG_DIR=… claude --resume <id>` nella cartella giusta.
  - **Rinomina**: scrive gli stessi record di `/rename` (`custom-title`, `agent-name`).
  - **Unisci** 2+ chat (ordine modificabile, nome, progetto di destinazione, riapertura immediata). Per ogni chat prende la conversazione effettiva (catena `parentUuid` dall'ultimo messaggio), salta i messaggi già presenti (chat derivate), toglie il confine di compattazione delle chat successive alla prima trasformandone il riassunto in un messaggio normale, collega tutto in un unico filo, copia tool-results/sub-agenti e file-history aggiornando i percorsi. Il risultato viene verificato (uuid unici, una sola catena) prima di essere salvato; solo allora le chat originali vanno nel Cestino.
  - **Dividi** una chat lunga in più chat, una per argomento (✂︎ nella barra o "Dividi in argomenti…"). La storia completa viene ricostruita anche oltre le compattazioni e tagliata in turni (un tuo messaggio + tutto quello che fa Claude fino al successivo), così le chiamate ai tool restano con i loro risultati. I turni si assegnano agli argomenti a mano (tasti 1–9, ⇧-clic per gli intervalli) o con "Proponi", che chiede a Claude Haiku (`claude -p --no-session-persistence`, nessun tool) di raggrupparli. Un turno può stare in più argomenti. Ogni argomento diventa una chat con il suo titolo e la sua cartella; facoltativamente parte con un riassunto del contesto originale scritto da Haiku nel formato delle compattazioni di Claude Code. Tutte le chat vengono verificate prima di essere salvate; l'originale va nel Cestino solo se è andato tutto bene (opzione disattivabile).
  - **Snellisci** una o più chat sul posto (stesso ID, stessa voce in /resume), categoria per categoria con il risparmio stimato in MB e token: dati tecnici (log `api-request*`, metadati ripetuti, promemoria automatici, rami annullati), screenshot/immagini/PDF letti dai tool, output lunghi (oltre 4.000 caratteri resta inizio e fine), output superati da una rilettura identica, ragionamenti interni (tranne l'ultimo turno); facoltativi le immagini incollate e la storia prima dell'ultima compattazione. Le chiamate ai tool restano sempre, con risultato accorciato; i messaggi tolti vengono scavalcati ricollegando i figli. La copia viene verificata (stessa conversazione per Claude, stesso ordine, tool call e risultati appaiati) prima di sostituire l'originale, che va nel Cestino.
  - **Descrizioni**: Claude Haiku scrive una o due frasi su cosa contiene ogni chat e a che punto è (5 chat per richiesta, cache in `descriptions.json`, rigenerate quando la chat ha almeno 3 messaggi in più). Compaiono nella lista, nella chat aperta e nella ricerca; disattivabili da Account.
- **Nuova chat guidata**: scrivi la richiesta, Haiku sceglie fino a 5 chat collegate (in base a titoli e descrizioni), la cartella, il titolo e il modello; poi scrive un contesto con solo ciò che serve. L'app crea una chat che parte da quel contesto (stesso formato di un riassunto di compattazione) e la avvia in Warp con `--resume <id> '<richiesta>'`.
- **Consigli**: consumo dai token registrati a ogni risposta (token equivalenti: input + scrittura cache ×1,25 + lettura cache ×0,1 + output ×5), grafico settimanale per modello, chat da snellire o dividere, modello consigliato per ogni chat in base all'uso degli strumenti. Opzione per riprendere/avviare le chat con il modello consigliato (`--model`).
  - **Elimina**: sposta nel Cestino la chat e la sua cartella (tool results, subagent). Bloccato se la chat è aperta.
- **Sessioni attive**: processi Claude in esecuzione per account (al lavoro / in attesa), con chiusura.
- **Account**: email, piano, modello, plugin, prompt di oggi, ultimo uso, stato dello storico condiviso; nuova chat in una cartella a scelta.
- **Memoria**: file `memory/*.md` per progetto, modificabili e salvabili.

## Contesti e aree di lavoro

- **Contesti** (scelti nella configurazione guidata, es. Personale, Lavoro): indipendenti dagli account. Il contesto di una chat si ricava dalla sua cartella: le aree in `<cartella chat>/<contesto>/` appartengono a quel contesto, i progetti nella cartella dei progetti hanno un contesto assegnabile (con un predefinito facoltativo), il resto è “Da assegnare”. Si può forzare il contesto di singole chat.
- **Aree di lavoro**: cartelle in `~/Chat AI/<contesto>/<area>` per le chat che non riguardano un repo, create dall'app con `CLAUDE.md`, `risorse/` e `output/`. Da qui si avviano nuove chat in Warp.
- **Sposta in…**: sposta una o più chat in un'area o in un progetto. Riscrive come testo il `cwd` originale e i percorsi della cartella di supporto, verifica il risultato, sposta tutto in `~/.claude/projects/<cartella codificata>/` e manda l'originale nel Cestino (il nome codificato è il percorso con ogni carattere non alfanumerico sostituito da `-`).
- **Memoria**: i file di memoria si spostano tra progetti/aree aggiornando entrambi i `MEMORY.md`.

Configurazione in `~/Library/Application Support/AISwitchboard/config.json`.

## Come trova gli account

`~/.claude` (predefinito) più ogni `~/.claude-*` che contiene `.claude.json`. Lo storico è condiviso se `projects` è un symlink a `~/.claude/projects`: gli account aggiunti dalla configurazione guidata lo creano (opzione attiva di default), così l'app e `/resume` vedono le chat di tutti gli account. **Aggiungi account** crea `~/.claude-<nome>` e apre Claude in quella configurazione per il login; da terminale si usa con `CLAUDE_CONFIG_DIR=~/.claude-<nome> claude`.

## Warp

Con **Apertura diretta** attiva (pagina Account) l'app aggiunge a `~/.zshrc` un blocco delimitato da `# >>> AI Switchboard >>>` (salvando prima una copia in `~/.ai-switchboard/zshrc.backup`). “Riprendi” e “Nuova chat” scrivono il comando in `~/.ai-switchboard/launch/<id>.zsh` con la cartella sulla prima riga e aprono una scheda Warp lì: al primo prompt il blocco esegue il comando di quella cartella (solo se più recente di 30 secondi, una volta per scheda). Disattivandola il blocco viene rimosso.

Se l'apertura diretta non è attiva, al primo “Riprendi” l'app chiede di attivarla (“Attiva e apri”) oppure apre la scheda lasciando il comando negli appunti. Il vecchio metodo con ⌘V simulato è stato tolto: con la firma ad-hoc il permesso Accessibilità si perde a ogni build. Senza Warp usa Terminale.

## Build

```bash
./Scripts/build_app.sh --install
swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

Richiede macOS 14+ e Xcode.
