# AGENTS.md

Istruzioni per gli agenti (Claude Code e simili) che lavorano in questo repository.

## Cos'è questo repository

È una **PoC** del refactoring del deploy del *proxy*, un'app Kubernetes che fa da CA:
genera certificati foglia firmati da una root CA.

Il proxy reale **non è in questo repository**. Qui c'è:

- uno **stub** del proxy (`app/`), scritto in **Python** per comodità, che replica solo la logica
  toccata dal refactoring: bootstrap della root CA, emissione di certificati foglia, cartelle di
  lavoro. Va implementato il minimo indispensabile;
- il **job di provisioning** della root CA su OpenBao (`job/`);
- due **chart Helm** (`charts/`): quello attuale ("legacy", StatefulSet) e quello nuovo (Deployment);
- l'**infrastruttura locale** e gli **scenari di test** (`poc/`): kind, OpenBao, webhook di
  iniezione `vault:`, Argo CD, ChartMuseum.

L'obiettivo è dimostrare che lo stesso chart funziona **in automatico** sia nelle installazioni
greenfield sia in quelle brownfield, senza passi manuali su OpenBao.

## Documento di riferimento

**[docs/plan.md](docs/plan.md) è la specifica.** Contiene requisiti, decisioni, dettagli
implementativi, fasi di lavoro e scenari di test. Leggilo per intero prima di iniziare.

- Segui le fasi nell'ordine. Spunta le checklist in `docs/plan.md` man mano che le completi.
- Se una decisione del piano si rivela impraticabile (es. un tool non si comporta come previsto),
  **fermati e chiedi**. Non inventare un'alternativa in silenzio. Annota il problema nella
  sezione "Punti aperti" del piano.
- I risultati degli scenari vanno in `docs/results.md` (vedi il piano per il formato).
- Tieni aggiornato, man mano che l'implementazione avanza, un `README.md` **minimale** per gli
  umani: poche righe su cosa fa la PoC, prerequisiti e comandi per eseguirla e testarla. Niente
  dettagli implementativi: per quelli rimanda a `docs/plan.md` e `docs/results.md`.

## Regole

### Sicurezza del cluster
- La PoC usa **esclusivamente un cluster kind locale** (`proxy-poc`). Niente cluster remoti,
  condivisi o cloud, nemmeno in sola lettura, e niente altre distribuzioni locali (minikube, k3d,
  Docker Desktop Kubernetes…). Anche OpenBao, Argo CD e ChartMuseum girano solo dentro questo kind.
- Ogni comando `kubectl`, `helm` o `argocd` negli script usa `--context kind-proxy-poc` in modo
  esplicito.
- Ogni script in `poc/` che usa il cluster verifica all'inizio che il context esista e fallisce
  altrimenti. Non usare mai il current-context implicito: sulla macchina possono esserci context
  di cluster reali. Gli script offline (es. `poc/check-charts.sh`) non hanno bisogno del guard.
- Non installare nulla fuori da kind, a parte i tool CLI dei prerequisiti.

### Segreti
- Nessuna chiave privata, certificato o token nel repository, nei log o nell'output dei comandi.
  Lo stub e il job non loggano mai il contenuto della chiave: solo fingerprint e metadati.
- Il root token di OpenBao in dev mode (`root`) va bene solo per la PoC e solo negli script di
  setup. Il job e lo stub si autenticano con l'auth Kubernetes, mai con il root token.

### Ambiente
- Tutto gira dentro kind, quindi il sistema operativo dell'host conta poco. Gli script in `poc/`
  sono **bash** e devono girare su Linux (anche WSL2) e macOS.
- I file di testo usano terminatori **LF**. Il `.gitattributes` (`* text=auto eol=lf`, creato in
  Fase 0) serve solo a evitare sorprese se il repo viene clonato su Windows: uno script con CRLF
  copiato in un'immagine Linux non parte.
- Le versioni di tool, immagini e chart sono fissate in `poc/versions.env`. Usa l'ultima release
  stabile disponibile al momento dell'implementazione e non usare mai `latest`.

### Stile
- Documentazione e messaggi rivolti all'utente in **italiano**. Codice, identificatori, log e
  commenti nel codice in **inglese**.
- Mantieni lo stub minimale: deve dimostrare il comportamento, non essere un proxy vero. Niente
  framework, astrazioni o funzionalità che gli scenari non verificano.
- Script bash con `set -euo pipefail`, idempotenti dove ha senso, con output leggibile
  (`==>` per i passi, `OK`/`FAIL` per le verifiche).

## Comandi principali

```bash
poc/setup.sh                # crea il cluster e installa OpenBao, webhook, Argo CD e ChartMuseum
poc/build.sh                # build delle immagini, load in kind, push dei chart su ChartMuseum
poc/scenarios/run-all.sh    # esegue tutti gli scenari e stampa il riepilogo
poc/teardown.sh             # elimina il cluster
```

Test locali senza cluster:

```bash
cd app && python -m pytest       # matrice di bootstrap dello stub
helm lint charts/proxy charts/proxy-legacy
```

## Definition of done

1. Tutte le fasi in `docs/plan.md` hanno la checklist completa.
2. `poc/scenarios/run-all.sh` passa da cluster pulito (`teardown` → `setup` → `build` → `run-all`).
3. `docs/results.md` riporta, per ogni scenario, l'esito e le evidenze (fingerprint, log
   rilevanti, stato delle risorse).
4. I punti aperti e le differenze rispetto al piano sono annotati in `docs/plan.md`.
