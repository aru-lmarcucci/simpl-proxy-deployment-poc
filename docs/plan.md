# Piano della PoC: root CA del proxy da OpenBao, con import della CA legacy

## 1. Contesto

Il proxy genera certificati foglia firmati da una root CA. Oggi:

- gira come **StatefulSet**;
- legge e scrive tutto (root CA e certificati foglia) sotto `/app/certs`, su un **PVC condiviso**
  tra le repliche;
- se la root CA non esiste in `/app/certs/_ca`, la **genera** all'avvio.

Problemi: scritture concorrenti sul volume condiviso e, di conseguenza, obbligo di usare uno
StatefulSet.

### Soluzione scelta (dal task di refactoring)

> **Aggiornata il 2026-11-16 (Fase 7).** Il design iniziale prevedeva, in brownfield, un secret
> placeholder con valori vuoti e il fallback del proxy sul volume legacy montato in sola lettura.
> Poiché il job legge già il volume per decidere, ora **importa** la CA legacy in OpenBao: il
> proxy legge la CA sempre e solo dalle env var e non monta più il PVC. Di conseguenza la cartella
> di lavoro resta `/app/certs` (ora un `emptyDir`): non serve più un path distinto
> `/app-data/certs`. Il task di refactoring (`TASK.md`) viene aggiornato di conseguenza. Il
> design iniziale non è mai andato in produzione, quindi non esistono secret placeholder da
> convertire.

**Applicazione**
1. All'avvio legge `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE` (PEM **codificate in base64**).
   Se entrambe sono presenti e non vuote, le decodifica e le scrive in
   `/app/certs/_ca/private-key.pem` e `/app/certs/_ca/certificate.pem`, gli stessi path di oggi.
2. Altrimenti **esce con errore**. Non genera più la CA da sola.
3. Logga da quale fonte ha inizializzato la root CA.
4. La base dir dei certificati resta `/app/certs`: il resto del codice non cambia.

**Deploy**
- Deployment al posto di StatefulSet.
- `emptyDir` su `/app/certs`, uno per istanza. Il Deployment **non monta** il PVC legacy.
- Env var iniettate da OpenBao con riferimenti `vault:...`.
- Il PVC legacy resta nel chart (mai eliminato) e lo monta, in sola lettura, solo il job.
- Un job eseguito da Argo CD prima del proxy provvede i secret su OpenBao:
  - file CA presenti sul PVC e secret assente → **importa** i file nel secret, così come sono;
  - file CA assenti e secret assente → genera una CA e crea il secret con i dati.

**Risultati attesi**
- Greenfield: la CA generata dal job arriva da OpenBao tramite env var.
- Brownfield: al primo sync del nuovo chart il job importa la CA del volume; il proxy la riceve
  da env var, con lo stesso fingerprint. Da lì in poi la CA sul volume non serve più.
- Senza env var il proxy fallisce.
- Il prune di Argo CD non elimina il PVC esistente.
- I certificati foglia diventano effimeri: non sopravvivono a scale-to-0 o redeploy.

## 2. Obiettivi della PoC

Dimostrare, **esclusivamente su un cluster kind locale** (`proxy-poc`), che:

1. la logica di bootstrap dello stub rispetta la matrice della §4.1;
2. il job rispetta la matrice della §4.2, è idempotente e **non può** sovrascrivere un secret;
3. l'ordine imposto da Argo CD (sync wave e hook) funziona anche al primo deploy greenfield e con
   una StorageClass `WaitForFirstConsumer`;
4. la migrazione brownfield (StatefulSet legacy → Deployment) mantiene **lo stesso PVC** (stesso
   UID) e **la stessa CA** (stesso fingerprint), importata dal job in OpenBao;
5. dopo la migrazione il proxy non dipende più dal volume: non lo monta e funziona anche se la CA
   sul PVC sparisce;
6. tutte le repliche usano la stessa CA e i certificati foglia sono locali a ogni istanza.

### Fuori scope
- Modifiche al proxy reale: la logica dello stub sarà portata lì in seguito.
- Rotazione e rinnovo della root CA.
- OpenBao in HA, TLS verso OpenBao, storage di produzione.
- Qualsiasi cluster diverso dal kind locale `proxy-poc` (remoto, condiviso, cloud o altra
  distribuzione locale), così come istanze esterne di OpenBao, Argo CD o registry.

## 3. Architettura della PoC

```
kind cluster "proxy-poc" (1 nodo)
├── ns openbao        OpenBao in dev mode (KV v2 su "secret/", auth kubernetes)
├── ns vault-webhook  Bank-Vaults vault-secrets-webhook (sintassi vault:)
├── ns argocd         Argo CD
├── ns chartmuseum    ChartMuseum: repository Helm da cui Argo CD scarica i chart
├── ns proxy-green    installazione greenfield
└── ns proxy-brown    installazione brownfield (prima legacy, poi migrata)
```

**Perché ChartMuseum.** Argo CD non legge cartelle locali. Con un repository Helm in-cluster
basta un `curl --data-binary` per pubblicare un chart. Inoltre il passaggio brownfield si fa come
in produzione: si cambia `targetRevision` dell'Application da `1.x` (legacy) a `2.x` (nuovo),
**con lo stesso nome di chart** (`proxy`).

**Immagini.** Lo stub e il job vengono costruiti in locale e caricati con `kind load docker-image`,
con `imagePullPolicy: IfNotPresent`.

### Struttura del repository

```
README.md                     # per gli umani: cosa fa la PoC e come testarla (minimale)
AGENTS.md
CLAUDE.md                     # importa AGENTS.md
.gitattributes                # eol=lf, precauzione per chi clona su Windows
docs/
  plan.md                     # questo file
  results.md                  # esiti degli scenari (da produrre)
app/                          # stub del proxy (Python, minimale)
  Dockerfile
  requirements.txt            # solo cryptography, versione fissata
  requirements-dev.txt        # + pytest, solo per i test locali
  proxy/
    __main__.py               # entrypoint: modalità legacy, server HTTP, emissione foglie
    bootstrap.py              # logica §4.1 e validazione (pura, testabile)
  tests/
    test_bootstrap.py
job/
  Dockerfile
  provision-root-ca.sh        # logica §4.2
charts/
  proxy-legacy/               # Chart name "proxy", version 1.0.0
  proxy/                      # Chart name "proxy", version 2.0.0
poc/
  versions.env
  lib.sh                      # funzioni comuni: guard del context, assert, port-forward
  check-charts.sh             # verifiche offline dei chart: lint, template, diff spec PVC
  kind-config.yaml
  setup.sh
  openbao-config.sh           # auth kubernetes, policy e ruoli per namespace
  build.sh
  teardown.sh
  argocd/
    app-green.yaml
    app-brown.yaml
  scenarios/
    run-all.sh                # reset, tutti gli scenari in ordine, riepilogo
    reset.sh                  # stato pulito per gli scenari, senza ricreare il cluster
    common.sh                 # helper degli scenari (Argo CD, OpenBao, pod)
    g1-*.sh … e7-*.sh
```

## 4. Specifiche dettagliate

### 4.1 Stub del proxy (`app/`)

**Linguaggio:** Python 3.12 con la sola libreria `cryptography` (più `pytest` per i test), scelto
per comodità. Il proxy reale potrebbe essere scritto in un altro linguaggio: lo stub serve a
validare la logica, non il codice.

**Minimalità.** Lo stub implementa solo ciò che serve agli scenari della §5 e ai test della
matrice: niente framework, configurazione, retry o astrazioni. Due moduli: `bootstrap.py`
(logica della matrice e validazione, testabile senza I/O di rete) e `__main__.py` (tutto il resto).

**Modalità** (env `PROXY_MODE`):
- `legacy`: replica il comportamento attuale. La base dir è `/app/certs`. Se `/app/certs/_ca`
  non contiene la CA, la genera (RSA 4096, 10 anni, `CN=Proxy Root CA (legacy)`). Serve a creare
  lo stato brownfield.
- `new` (default): comportamento del refactoring, descritto sotto.

**Bootstrap in modalità `new`.** Le costanti dei path sono configurabili via env solo per i test.

| `ROOT_CA_PRIVATE_KEY` | `ROOT_CA_CERTIFICATE`       | Esito                                                      | Fonte nel log |
| --------------------- | --------------------------- | ---------------------------------------------------------- | ------------- |
| non vuota             | non vuota                   | decodifica base64, valida, scrive in `/app/certs/_ca`      | `env`         |
| non vuota             | vuota/assente (o viceversa) | **errore**: configurazione parziale                        | –             |
| vuote/assenti         | vuote/assenti               | **errore**: nessuna root CA disponibile                    | –             |

Fino alla Fase 6 la matrice aveva anche il fallback sul volume legacy (`source=legacy-volume`),
rimosso in Fase 7.

Dettagli:
- "Vuota" significa stringa vuota o fatta solo di spazi bianchi.
- Prima della decodifica base64 lo stub rimuove spazi e a-capo dal valore. Un base64 non valido o
  un PEM non valido produce errore, con un messaggio che nomina la variabile ma **non** il valore.
- **Validazione**:
  - la chiave privata corrisponde alla chiave pubblica del certificato;
  - il certificato ha `basicConstraints CA:TRUE`;
  - il certificato è nel suo periodo di validità → altrimenti errore.
- La chiave privata è scritta con permessi `0600`, il certificato con `0644`. La directory `_ca`
  viene creata con `0700`.
- Log di avvio, una riga strutturata (JSON) di questo tipo:
  `{"event":"root_ca_loaded","source":"env","fingerprint_sha256":"…","subject":"…","not_after":"…"}`.
- In caso di errore: messaggio chiaro su stderr ed **exit code 1**, prima di aprire la porta HTTP.
  Il pod finisce in `CrashLoopBackOff`, ed è il comportamento voluto.
- In modalità `new` lo stub non legge né scrive `/app/certs`, che non è montato.

**Server HTTP** (porta 8080, stdlib `http.server`):
- `GET /healthz` → `200 ok`.
- `GET /ca` → JSON `{source, fingerprint_sha256, not_after, pod}`. `pod` viene da `HOSTNAME`.
- `GET /issue?host=<fqdn>` → emette un certificato foglia per `host`, firmato dalla root CA, e lo
  salva in `<basedir>/<host>/cert.pem` e `key.pem`. Se esiste già, lo riusa. Risponde con JSON
  `{host, serial, path, reused}`.
- `GET /certs` → elenco dei certificati foglia presenti nella base dir, esclusa `_ca`.

**Immagine:** `python:3.12-slim` con versione fissata, utente non root `10001:10001`, `WORKDIR
/app`, `CMD ["python", "-m", "proxy"]`. In modalità `new` il container deve funzionare con
`readOnlyRootFilesystem: true`.

**Test** (`app/tests/test_bootstrap.py`, pytest con `tmp_path`): coprono tutte le righe della
matrice, più:
- base64 non valido;
- chiave che non corrisponde al certificato;
- certificato non CA;
- certificato scaduto;
- valori con a-capo e spazi;
- permessi dei file scritti.

Le CA di test si generano nei test e non si committano.

### 4.2 Job di provisioning (`job/`)

**Immagine:** `alpine` con versione fissata, più `openssl`, `curl` e `jq`. Usa la **HTTP API** di
OpenBao invece della CLI `bao`: i codici di stato HTTP permettono di distinguere "assente" (404)
da "accesso negato" (403) senza interpretare messaggi di errore.

**Input** (env):
- `BAO_ADDR`, ad esempio `http://openbao.openbao.svc:8200`;
- `BAO_AUTH_PATH`, default `kubernetes`;
- `BAO_ROLE`, ad esempio `proxy-ca-init`;
- `SECRET_PATH`, ad esempio `secret/data/proxy/<namespace>/root-ca` (path API KV v2, con `data/`);
- `LEGACY_CA_DIR`, default `/legacy-certs/_ca`;
- `CA_SUBJECT`, default `/CN=Proxy Root CA`;
- `CA_DAYS`, default `3650`;
- `CA_KEY_ALG`, default `rsa:4096`.

**Formato del secret** (KV v2): un solo path con due chiavi, `private_key` e `certificate`.
Ciascuna contiene la PEM codificata in base64 standard su una sola riga. In brownfield sono i file
del volume, codificati così come sono.

**Logica:**

```
1. login: POST /v1/auth/$BAO_AUTH_PATH/login {role, jwt=<token del service account>}
2. stato del volume:
     entrambi i file presenti e non vuoti → VOLUME=present
     nessuno dei due                       → VOLUME=absent
     uno solo / file vuoti                 → exit 1 "CA incompleta sul volume legacy"
3. stato del secret: GET /v1/$SECRET_PATH
     200 → SECRET=present  (anche se i valori sono vuoti)
     404 → SECRET=absent
     altro → exit 1 con il codice HTTP
4. decisione:
```

| VOLUME      | SECRET                   | Azione                                                         | Exit |
| ----------- | ------------------------ | -------------------------------------------------------------- | ---- |
| present     | absent                   | importa i file del volume nel secret, senza validarli          | 0    |
| absent      | absent                   | genera la CA con openssl e scrive il secret                    | 0    |
| qualsiasi   | present con dati         | nessuna (es. sync dopo la migrazione, anche con PVC svuotato)  | 0    |
| qualsiasi   | present vuoto o parziale | nessuna. Warning: "il proxy fallirà" (es. secret creato a mano) | 0    |

Fino alla Fase 6, con `present / absent` il job scriveva un placeholder vuoto.

Dettagli:
- Ogni scrittura usa `{"options":{"cas":0},"data":{…}}`, cioè crea il secret solo se non esiste.
  Se la scrittura fallisce per CAS (secret creato nel frattempo, o versioni cancellate ma
  metadati ancora presenti), il job rilegge il secret: se esiste, esce con 0 (no-op); altrimenti
  esce con 1.
- Nessuna rigenerazione automatica. Con un secret vuoto o parziale il job **non** genera una
  nuova CA: rigenerare in silenzio invaliderebbe la fiducia dei client, e comunque la policy non
  permette di sovrascrivere. Meglio che il proxy fallisca.
- **Import senza validazione** (decisione dell'utente, Fase 7): se i file del volume sono
  sbagliati, lo erano già per il proxy legacy. L'errore emerge all'avvio del proxy, che valida la
  CA (§4.1). Il job controlla solo che entrambi i file esistano e non siano vuoti.
- File temporanei in `/tmp`, montato come `emptyDir` con `medium: Memory`. Nessun `set -x`, nessun
  `echo` di chiavi o token. Il token viene passato a curl via header letto da file o variabile,
  mai sulla riga di comando di un altro processo loggato.
- La CA generata ha le stesse estensioni attese dallo stub: `basicConstraints=critical,CA:TRUE` e
  `keyUsage=critical,keyCertSign,cRLSign`, più `subjectKeyIdentifier`. Il base64 si ottiene con
  `base64 | tr -d '\n'`, per compatibilità con busybox.
- Output finale: una riga `RESULT: <azione>` (`ca-imported`, `ca-generated`, `noop`), usata
  dagli scenari per le asserzioni. Se ha scritto una CA, stampa anche il fingerprint SHA-256
  nello stesso formato dello stub: hex minuscolo senza `:` (es. con
  `openssl x509 -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f`).

### 4.3 Policy e ruoli OpenBao (`poc/openbao-config.sh`)

Lo script gira con il root token della dev mode e configura:

- `auth/kubernetes` abilitato, con `kubernetes_host=https://kubernetes.default.svc`.
- Per ogni namespace di installazione (`proxy-green`, `proxy-brown`):
  - policy `proxy-ca-init-<ns>`:
    - `secret/data/proxy/<ns>/root-ca` con capability `["create", "read"]`.
      **Senza `update`**: in KV v2 la scrittura su un secret esistente richiede `update`, quindi
      il job non può sovrascrivere nemmeno per errore.
  - policy `proxy-read-<ns>`:
    - `secret/data/proxy/<ns>/root-ca` con capability `["read"]`.
  - ruolo `proxy-ca-init-<ns>`: SA `proxy-ca-init`, namespace `<ns>`, policy `proxy-ca-init-<ns>`.
  - ruolo `proxy-<ns>`: SA `proxy`, namespace `<ns>`, policy `proxy-read-<ns>`.

Il KV v2 su `secret/` è già montato dalla dev mode. Verificalo e, se manca, montalo.

### 4.4 Chart legacy (`charts/proxy-legacy`, `name: proxy`, `version: 1.0.0`)

Simula il chart attuale, quanto basta per creare lo stato brownfield:
- `StatefulSet` `proxy`, 2 repliche, `PROXY_MODE=legacy`, mount **RW** del PVC su `/app/certs`.
- Service headless `proxy-headless` e Service `proxy` (porta 80 → 8080).
- PVC `proxy-certs` come risorsa standalone del chart, condivisa da tutte le repliche (non
  `volumeClaimTemplates`).
- Label: `app.kubernetes.io/name: proxy`, `app.kubernetes.io/instance: {{ .Release.Name }}`.

### 4.5 Chart nuovo (`charts/proxy`, `name: proxy`, `version: 2.0.0`)

**PVC `proxy-certs`**
- Il nome è un valore (`legacyCerts.claimName`, default `proxy-certs`), **identico** al legacy.
- Lo spec deve essere identico a quello del chart legacy. `accessModes`, `storageClassName`,
  `volumeName` e `selector` sono **immutabili**: se cambiano, il sync fallisce. La dimensione può
  solo crescere.
- Valori di default allineati al legacy: `legacyCerts.accessModes`, `legacyCerts.storageClassName`,
  `legacyCerts.size`. Nella PoC: `ReadWriteOnce` con la StorageClass `standard` di kind
  (local-path, `WaitForFirstConsumer`), che con un solo nodo permette mount da più pod.
- Annotazioni:
  - `argocd.argoproj.io/sync-options: Delete=false,Prune=false`;
  - `helm.sh/resource-policy: keep`, per chi installa con la CLI di Helm;
  - `argocd.argoproj.io/sync-wave: "0"`.
- Il chart crea il PVC **sempre**, anche in greenfield, dove resta vuoto. Lo monta solo il job.

**Job `proxy-ca-init`**
- Annotazioni:
  - `argocd.argoproj.io/hook: Sync`;
  - `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`;
  - `argocd.argoproj.io/sync-wave: "0"`.
- **Non** usare `PreSync`: al primo deploy greenfield il PVC non esiste ancora.
- PVC e Job stanno nella **stessa wave 0**, non il PVC a -1. Con una StorageClass
  `WaitForFirstConsumer` il PVC resta `Pending` finché un pod non lo monta, e Argo CD considera
  un PVC `Pending` come `Progressing`. Con il PVC in una wave precedente il sync resterebbe
  bloccato. Nella stessa wave Argo applica prima il PVC (ordine per kind) e poi il Job, il cui pod
  fa da primo consumer.
- `ServiceAccount` `proxy-ca-init`, mount del PVC con `readOnly: true` su `/legacy-certs`,
  `/tmp` come `emptyDir` in memoria.
- Utente `10001`, lo stesso del proxy: la chiave privata legacy sul PVC ha permessi `0600` e
  `fsGroup` non basta a leggerla.
- `backoffLimit: 1`, `activeDeadlineSeconds: 300`, `restartPolicy: Never`.
- `securityContext`: non root, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`.
- Env come da §4.2. `SECRET_PATH` è derivato da `rootCa.secretPath`, con default
  `secret/data/proxy/{{ .Release.Namespace }}/root-ca`.

**Deployment `proxy`**
- `argocd.argoproj.io/sync-wave: "1"`, 2 repliche, strategia `RollingUpdate`.
- `ServiceAccount` `proxy`.
- Volumi:
  - `certs`: `emptyDir`, montato su `/app/certs`, lo stesso path del legacy. Valori
    `certsDir.medium` (default `""`, opzione `Memory`) e `certsDir.sizeLimit` (default `100Mi`).
    Con `Memory`, l'uso conta nel limite di memoria del container.
  - nessun mount del PVC legacy (Fase 7): il Deployment è stateless e, anche con un PVC
    `ReadWriteOnce`, le repliche possono stare su nodi diversi.
- Env:
  ```yaml
  - name: ROOT_CA_PRIVATE_KEY
    value: "vault:secret/data/proxy/<ns>/root-ca#private_key"
  - name: ROOT_CA_CERTIFICATE
    value: "vault:secret/data/proxy/<ns>/root-ca#certificate"
  ```
- Annotazioni del pod template per il webhook:
  - `vault.security.banzaicloud.io/vault-addr`;
  - `vault.security.banzaicloud.io/vault-role: proxy-<ns>`;
  - `vault.security.banzaicloud.io/vault-path: kubernetes`;
  - `vault.security.banzaicloud.io/vault-skip-verify: "true"`.
- **`command` esplicito** nel container (`["python", "-m", "proxy"]`). Senza `command` il webhook
  deve leggere l'entrypoint dal registry dell'immagine, ma le immagini caricate con `kind load`
  non sono in nessun registry e la mutazione fallisce.
- `securityContext`:
  - utente `10001`, lo stesso del legacy e del job;
  - `fsGroup: 10001`;
  - `readOnlyRootFilesystem: true`.
- Probe: `readinessProbe` e `livenessProbe` HTTP su `/healthz`.
- Service `proxy`, identico al legacy. Il Service headless **non** esiste più e deve essere
  eliminato dal prune.

**Label:** le stesse del legacy, così il Service `proxy` continua a selezionare i pod.

### 4.6 Argo CD

- Repository Helm registrato: `http://chartmuseum.chartmuseum.svc:8080`.
- `poc/argocd/app-green.yaml`: Application `proxy-green`, chart `proxy`, `targetRevision: 2.0.0`,
  namespace `proxy-green`.
- `poc/argocd/app-brown.yaml`: Application `proxy-brown`, chart `proxy`, all'inizio
  `targetRevision: 1.0.0`, namespace `proxy-brown`.
- `syncPolicy`: sync **manuale** (gli scenari chiamano `argocd app sync … --prune` e
  `argocd app wait … --health`), con `syncOptions: [CreateNamespace=true, PruneLast=true]`. Il
  prune va eseguito esplicitamente, per verificare la protezione del PVC.
- **`PruneLast=true`** (aggiunto in Fase 5, decisione confermata dall'utente). Senza questa opzione
  Argo CD elimina le risorse non più presenti nel chart **nella loro wave**, e le risorse del chart
  legacy, senza annotazioni, stanno nella wave 0. Lo StatefulSet viene quindi eliminato insieme al
  job, prima che il Deployment (wave 1) sia pronto. Misurato in B1: 0 pod pronti per circa 17 s.
  Se il job fallisce (E2) il proxy resta del tutto senza pod. Con `PruneLast=true` il prune avviene
  solo dopo che tutte le wave sono riuscite: durante la migrazione restano sempre 2 pod pronti e,
  se il job fallisce, lo StatefulSet legacy resta attivo.
- I valori specifici della PoC stanno in `helm.valuesObject` dell'Application, non nel chart:
  StorageClass e access mode di kind, path del secret.

### 4.7 Setup (`poc/setup.sh`)

1. Verifica i prerequisiti: `docker`, `kind`, `kubectl`, `helm`, `argocd`, `curl`, `jq`,
   `python` ≥ 3.12. Se manca qualcosa, stampa cosa manca e come installarlo, poi esce.
2. `kind create cluster --name proxy-poc --config poc/kind-config.yaml`. Se il cluster esiste già,
   lo riusa.
3. OpenBao: chart Helm `openbao/openbao` con `server.dev.enabled=true` e
   `server.dev.devRootToken=root`, namespace `openbao`. Poi esegue `poc/openbao-config.sh`.
4. Bank-Vaults `vault-secrets-webhook` (chart OCI `ghcr.io/bank-vaults/helm-charts`), namespace
   `vault-webhook`. Va verificato che il webhook escluda il proprio namespace e quelli di sistema.
5. Argo CD: manifest ufficiale `install.yaml` della versione fissata, namespace `argocd`. Login
   CLI tramite port-forward con la password admin iniziale.
6. ChartMuseum: chart `chartmuseum/chartmuseum` con `env.open.DISABLE_API=false` e storage
   locale, namespace `chartmuseum`. Poi registra il repo in Argo CD.

`poc/build.sh`:
- build di `proxy-stub:poc` e `proxy-ca-init:poc`;
- `kind load docker-image`;
- `helm package` dei due chart e upload su ChartMuseum (port-forward + `curl --data-binary`).
  Con versione già presente, cancella e ricarica: nella PoC si itera sullo stesso numero di versione.

Ogni port-forward viene avviato in background da `lib.sh` e chiuso con `trap`.

## 5. Scenari di test (`poc/scenarios/`)

Ogni scenario è uno script autonomo che usa le funzioni di `lib.sh` e stampa `OK`/`FAIL` per ogni
asserzione. `run-all.sh` li esegue nell'ordine indicato, perché alcuni dipendono dallo stato
lasciato dai precedenti, e stampa un riepilogo finale. Il fingerprint si legge con
`GET /ca` su **ogni** pod, tramite `kubectl exec` o port-forward per pod.

### Greenfield (`proxy-green`)

| ID  | Azioni                                                  | Asserzioni                                                                                                                                                                                |
| --- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | crea e sincronizza `proxy-green` (2.0.0)                | job `RESULT: ca-generated`; il secret in OpenBao ha dati; tutti i pod `Ready`; `source=env`; stesso fingerprint su tutti i pod, uguale a quello stampato dal job; PVC `proxy-certs` senza CA (log del job); il Deployment non monta PVC |
| G2  | nuovo sync                                              | job `RESULT: noop`; fingerprint invariato                                                                                                                                                 |
| G3  | `/issue?host=a.example` sul pod 1; `/certs` su entrambi | il certificato esiste solo sul pod 1 (`emptyDir` per istanza)                                                                                                                             |
| G4  | scale a 0, poi a 2                                      | fingerprint invariato; `/certs` vuoto su tutti i pod (certificati effimeri)                                                                                                               |
| G5  | `rollout restart`                                       | come G4                                                                                                                                                                                   |

### Brownfield (`proxy-brown`)

| ID  | Azioni                                                                                                                                         | Asserzioni                                                                                                                                                                                                                                                                                                                    |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B0  | sincronizza `proxy-brown` con 1.0.0 (legacy); `/issue?host=b.example`                                                                          | StatefulSet `Ready`; la CA esiste sul PVC; salva fingerprint (`FP_LEGACY`) e UID del PVC (`PVC_UID`); nessun secret in OpenBao                                                                                                                                                                                                |
| B1  | `targetRevision: 2.0.0`, sync con `--prune`                                                                                                    | job `RESULT: ca-imported` con fingerprint `FP_LEGACY`; secret con dati; StatefulSet e Service headless eliminati; PVC con **lo stesso UID** `PVC_UID`; il Deployment non monta PVC; env iniettate non vuote; pod `Ready` con `source=env` e fingerprint `FP_LEGACY` su tutti; sempre almeno un pod pronto durante il sync |
| B2  | nuovo sync                                                                                                                                     | job `RESULT: noop` senza warning; versione KV invariata; fingerprint invariato                                                                                                                                                                                                                                                |
| B3  | si cancella `_ca` dal PVC con un pod di servizio RW, poi sync e `rollout restart`                                                              | job `RESULT: noop` (volume `absent`, secret con dati) senza warning; versione KV invariata; pod `source=env` con `FP_LEGACY`                                                                                                                                                                                                  |

Fino alla Fase 6 B1 creava un placeholder vuoto (`source=legacy-volume`), B3 copiava a mano la CA
del volume nel secret e B4 verificava il sync successivo. Con l'import automatico B3 e B4 di allora
non servono più: il nuovo B3 verifica che, dopo la migrazione, il volume non serva più.

### Casi di errore

Questi scenari girano in namespace dedicati e temporanei (`proxy-err-*`), con Application create
al volo e ruoli OpenBao creati da `openbao-config.sh` con parametro namespace. Alla fine vengono
eliminati.

| ID  | Preparazione                                                                                                          | Asserzioni                                                                                                       |
| --- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| E1  | secret con valori vuoti creato a mano, PVC senza CA (Fase 7; prima: placeholder brownfield e CA persa dal PVC)        | job `RESULT: noop` + warning "il proxy fallirà", nessuna rigenerazione; pod in `CrashLoopBackOff` con log "nessuna root CA disponibile" |
| E2  | sul PVC resta solo `private-key.pem`                                                                                  | job in errore "CA incompleta"; sync dell'Application `Failed`; Deployment non aggiornato                         |
| E3  | secret con `private_key` valorizzata e `certificate` vuoto                                                            | pod in errore "configurazione parziale"                                                                          |
| E4  | secret con base64 non valido; poi con chiave e certificato non corrispondenti                                         | pod in errore con il messaggio specifico; il valore non compare nei log                                          |
| E5  | con il token del ruolo `proxy-ca-init-<ns>`, tentativo di sovrascrivere un secret esistente (con e senza `cas`)       | `403` (manca `update`)                                                                                           |
| E6  | il chart viene renderizzato senza la risorsa PVC (valore di test `legacyCerts.renderPvc=false`), sync con `--prune`   | il PVC **non** viene eliminato (protetto da `Prune=false`)                                                       |
| E7  | come B1, ma con `accessModes` diverso da quello del legacy                                                            | sync fallisce per campo immutabile. Lo scenario documenta il rischio e si aspetta il fallimento                  |

### Verifica dell'iniezione

`kubectl exec … -- env` mostra i valori dello spec del pod (`vault:…`), non quelli iniettati,
perché `vault-env` li passa solo al processo che avvia. Gli scenari leggono quindi
`/proc/1/environ` del container e stampano solo le lunghezze. In B1 le due variabili devono essere
presenti e non vuote. (Fino alla Fase 6 B1 verificava l'iniezione di valori **vuoti**: vedi §7,
punto 2.)

## 6. Fasi di lavoro

### Fase 0: scaffolding
- [x] `git init`, `.gitignore`, `.gitattributes` (`* text=auto eol=lf`, solo precauzione per i
      clone su Windows: su Linux/WSL2 i file sono già LF)
- [x] `CLAUDE.md` con `@AGENTS.md`
- [x] `README.md` minimale: scopo della PoC in 2-3 righe, prerequisiti, comandi. Va aggiornato
      alla fine di ogni fase se cambia qualcosa di rilevante per chi esegue la PoC
- [x] `poc/versions.env` con le versioni fissate: kind node image, OpenBao chart e immagine,
      vault-secrets-webhook, Argo CD, ChartMuseum, python, alpine
- [x] `poc/lib.sh` (guard del context, `assert_eq`, `assert_contains`, gestione port-forward)

Note di implementazione (Fase 0):
- `versions.env` fissa anche le versioni delle CLI `kind` (`v0.33.0`, richiesta dalla node image
  `v1.36.4`) e `argocd` (uguale al server). `setup.sh` dovrà verificarle. Sulla macchina di
  sviluppo, al 2026-11-16, `kind` è alla v0.31.0 e `argocd` non è installato.
- Python resta alla 3.12 come da §4.1 (`3.12.16-slim-trixie`), anche se esistono release più
  recenti.
- Il guard di `lib.sh` verifica che il context esista, che punti al cluster `kind-proxy-poc` con
  API server su localhost e che `kind get clusters` lo elenchi.
- `port_forward` è testato solo a livello di sintassi: la verifica reale arriva in Fase 4.

### Fase 1: stub
- [x] `app/proxy/bootstrap.py` secondo §4.1
- [x] `app/proxy/__main__.py`: modalità `legacy`, server HTTP, emissione dei certificati foglia
- [x] test pytest su tutta la matrice; `python -m pytest` verde
- [x] Dockerfile; l'immagine parte con `readOnlyRootFilesystem` in modalità `new`

Note di implementazione (Fase 1):
- Dipendenze: `cryptography==50.0.2` in `requirements.txt`; `pytest==9.2.0` in
  `requirements-dev.txt`, usato solo in locale (non va nell'immagine).
- I messaggi di errore sono in inglese (regola di `AGENTS.md`). Gli scenari della §5 devono cercare
  questi testi: `no root CA available`, `partial configuration`, `incomplete CA on legacy volume`,
  `is not valid base64`, `does not match the certificate`.
- Il fingerprint è hex minuscolo senza `:`. Il job (§4.2) usa lo stesso formato.
- In modalità `legacy` il log riporta `source=generated` quando la CA viene creata e
  `source=legacy-volume` quando esiste già. Ogni riga di log ha anche `mode`.
- I certificati foglia usano chiavi EC P-256 e durano 90 giorni. `/issue` accetta solo hostname
  validi (risponde 400 altrimenti), per evitare path traversal nella base dir.
- Lo stub gestisce `SIGTERM`: come PID 1 lo ignorerebbe, rallentando di 30 s scale e restart.
- `PYTHON_IMAGE` arriva come build-arg da `versions.env`. Il Dockerfile non ha default, per non
  duplicare la versione.
- Verifica dell'immagine fatta con `docker run --read-only` e tmpfs su `/app-data/certs`:
  CA da env; errore senza CA (exit 1); modalità legacy che genera la CA su un volume; modalità
  `new` che la legge dal volume montato `:ro` con lo stesso fingerprint; scrittura su
  `/app/certs` rifiutata; permessi 0700/0600/0644.

### Fase 2: job
- [x] `job/provision-root-ca.sh` secondo §4.2
- [x] Dockerfile
- [x] `shellcheck` pulito, se disponibile

Note di implementazione (Fase 2):
- Lo script è in bash (installato nell'immagine alpine insieme a `curl`, `jq` e `openssl`), per
  coerenza con le regole di `AGENTS.md`.
- L'immagine gira come utente `10001`. Il chart deve usare lo stesso UID (§4.5).
- Oltre alle variabili della §4.2 accetta `SA_TOKEN_FILE` (default: il token del service account),
  utile solo per i test.
- Caso non previsto dalla matrice: secret con una sola delle due chiavi valorizzata. Il job non fa
  nulla (`noop`) e stampa un warning, perché il proxy fallirà con `partial configuration`.
- Warning ed errori sono in inglese. Testi utili agli scenari: `the proxy will fail`,
  `the proxy will use the CA from OpenBao`, `incomplete CA on legacy volume`, `cannot create`.
- Con la policy senza `update`, una scrittura su un path che ha già metadati (anche se la versione
  corrente è cancellata) restituisce `403`, non l'errore CAS. Il job lo gestisce allo stesso modo:
  rilegge il secret ed esce con 0 se esiste, con 1 altrimenti (caso del secret soft-deleted).
- Il token di OpenBao passa a curl tramite `-H @file`, quindi non compare mai negli argomenti dei
  processi. Il JWT del service account viaggia nel body letto da file.
- shellcheck gira via Docker (`SHELLCHECK_IMAGE` in `versions.env`) ed è pulito su
  `job/provision-root-ca.sh` e `poc/lib.sh`.
- Verifica locale, senza cluster, contro OpenBao `2.7.2` in dev mode in Docker. Per il login si usa
  l'auth `jwt`, che accetta lo stesso body `{role, jwt}` dell'auth `kubernetes`; nessun root token
  nel job. Casi verificati (21 asserzioni):
  - tutte le righe della matrice, con le riesecuzioni idempotenti (versione KV invariata);
  - CA generata dal job accettata dallo stub (`source=env`, stesso fingerprint);
  - volume incompleto (exit 1, nessun secret scritto);
  - secret soft-deleted (exit 1);
  - anticipo di E5: con la policy del job la sovrascrittura dà `403`, con e senza `cas`;
  - nessuna PEM e nessun token nell'output.

  Lo script di test non è nel repository: gli stessi casi tornano negli scenari della Fase 5.
  Alla prima esecuzione un'asserzione (secret soft-deleted) è fallita una volta; nelle tre
  esecuzioni successive, complete, tutto è verde. Da tenere d'occhio in E-scenari.

### Fase 3: chart
- [x] `charts/proxy-legacy` (§4.4)
- [x] `charts/proxy` (§4.5)
- [x] `helm lint` e `helm template` puliti
- [x] diff dello spec PVC tra i due chart renderizzati: nessuna differenza nei campi immutabili

Note di implementazione (Fase 3):
- `poc/check-charts.sh` esegue `helm lint --strict`, `helm template` (anche con
  `legacyCerts.renderPvc=false`, per E6) e il diff dello spec PVC tra i due chart, con i default
  e con i valori di kind. Non tocca il cluster, quindi non chiama il guard del context (vedi
  `AGENTS.md`). Ho verificato anche il caso negativo: con `accessModes` diversi lo script fallisce
  e mostra il diff.
- Il chart legacy usa valori `persistence.*`, quello nuovo `legacyCerts.*`, come succederebbe con
  due chart reali diversi. L'Application brownfield (§4.6) deve quindi impostare entrambi in
  `valuesObject`: ciascun chart ignora i valori dell'altro.
- `storageClassName` vuoto viene omesso dallo spec, quindi si usa la StorageClass di default del
  cluster. Nella PoC le Application impostano `standard` in modo esplicito.
- Chart legacy: `podManagementPolicy: OrderedReady` e readiness probe. Il pod 1 parte solo dopo
  che il pod 0 è pronto, quindi solo il pod 0 genera la CA sul volume condiviso.
- I pod del job hanno label `app.kubernetes.io/name: proxy-ca-init`, così il Service `proxy` non
  li seleziona.
- Il PVC è montato in sola lettura sia sul mount (`readOnly: true`) sia sul volume
  (`persistentVolumeClaim.readOnly: true`), nel Deployment e nel job.
- `securityContext` di job e Deployment: in più rispetto al piano, `runAsNonRoot`,
  `capabilities.drop: [ALL]` e `seccompProfile: RuntimeDefault`. `/tmp` del job è un `emptyDir`
  in memoria da 16Mi.
- ~~Da osservare in B1: Argo esegue il prune alla fine del sync~~ (ipotesi sbagliata, smentita in
  Fase 5: senza `PruneLast` il prune avviene nella wave della risorsa, vedi §4.6). Con
  `PruneLast=true` per qualche istante convivono i pod dello StatefulSet (in scrittura sul volume)
  e quelli del Deployment (in lettura fino alla Fase 7, poi senza volume), e il Service seleziona
  entrambi.
- Corretto un bug di `lib.sh`: `tmp_dir` chiamato dentro `$(...)` creava la cartella in una
  subshell, che restava in `/tmp`. Ora la cartella si crea quando si carica la libreria.

### Fase 4: infrastruttura
- [x] `kind-config.yaml`, `setup.sh`, `openbao-config.sh`, `build.sh`, `teardown.sh`
- [x] Application Argo CD
- [x] setup completo da zero senza interventi manuali

Note di implementazione (Fase 4):
- Prerequisiti sulla macchina di sviluppo: `kind` v0.33.0 e `argocd` v3.6.1 installati in
  `~/.local/bin`, con checksum verificato. `/usr/local/bin/kind` (v0.31.0) resta, ma nel PATH
  viene dopo. `setup.sh` fallisce se le versioni di `kind` e `argocd` non coincidono con
  `versions.env`.
- `teardown.sh` → `setup.sh` → `build.sh` da zero: circa 5 minuti, nessun intervento manuale.
  `setup.sh` e `build.sh` sono idempotenti: rieseguiti, riusano ciò che esiste e ripubblicano i
  chart.
- `kind create cluster` cambia il current-context: `setup.sh` ripristina quello dell'utente.
  Nessuno script lo usa comunque.
- I chart esterni si installano con `helm --repo` (o OCI), senza `helm repo add`: la
  configurazione Helm dell'utente resta intatta.
- OpenBao: injector del chart disabilitato (`injector.enabled=false`), tag dell'immagine esplicito.
  `openbao-config.sh` usa la CLI `bao` dentro il pod via `kubectl exec`, con il root token solo
  lì. Accetta namespace come argomenti, e `--delete <ns>` per ripulire (servirà agli scenari E).
  I ruoli hanno `token_ttl=10m`.
- vault-secrets-webhook: `podsFailurePolicy=Fail` (il default del chart è `Ignore`, che farebbe
  partire il proxy con il valore letterale `vault:…` se il webhook non risponde). Esclusi i
  namespace di sistema e di infrastruttura (`openbao`, `vault-webhook`, `argocd`, `chartmuseum`,
  `local-path-storage`), così un guasto del webhook non li blocca. L'immagine `vault-env` è quella
  di default del chart (`v1.23.0`).
- Argo CD: CLI con config isolata (`--config` in una cartella temporanea) e context chiamato
  `kind-proxy-poc`, usato con `--argocd-context`. La `~/.config/argocd` dell'utente non viene
  toccata. Ogni script fa login via port-forward (`argocd_login` in `lib.sh`).
- Il repo Helm è registrato in modo dichiarativo, con un Secret
  `argocd.argoproj.io/secret-type: repository`.
- ChartMuseum usa storage locale senza persistenza: se il pod riparte, i chart vanno ripubblicati
  con `build.sh`.
- Argo CD tiene in cache i chart per versione. Dopo `build.sh` gli scenari devono fare
  `argocd app get --hard-refresh` prima del sync.
- Verifica con Argo CD, senza sync: le due Application leggono i chart da ChartMuseum (2.0.0 e
  1.0.0) e risultano `OutOfSync` senza condizioni di errore. `argocd app manifests` non elenca il
  Job, perché è un hook.
- Corretti due bug di `lib.sh`:
  - `port_forward` lanciava in background la funzione `k`: `$!` era il PID di una subshell e
    `kubectl` restava vivo dopo l'uscita dello script. Ora lancia `kubectl` direttamente.
  - il controllo del webhook in `setup.sh` cercava una label che il chart non mette; ora cerca la
    configurazione per nome.

### Fase 5: scenari
- [x] G1–G5
- [x] B0–B4
- [x] E1–E7
- [x] `run-all.sh` verde da cluster pulito

Note di implementazione (Fase 5):
- Esecuzione di riferimento il 2026-11-16: `teardown` → `setup` → `build` → `run-all` in 19 min,
  17 scenari su 17, 125 asserzioni, 0 fallite. Dettagli ed evidenze in `docs/results.md`.
- `run-all.sh` parte da `scenarios/reset.sh`, che elimina Application, namespace `proxy-*` e
  secret/ruoli OpenBao e ricrea i ruoli di `proxy-green` e `proxy-brown`: si può rieseguire sullo
  stesso cluster. I log di ogni scenario vanno in `.tmp/scenario-logs/`, lo stato condiviso
  (fingerprint, UID, versioni KV; nessun segreto) in `.tmp/scenarios/state.env`.
- **Decisione (confermata dall'utente): `PruneLast=true`** nelle `syncOptions` delle Application
  (§4.6). Senza, lo StatefulSet legacy veniva eliminato nella wave 0: disservizio in B1 e proxy
  senza pod in E2. In più rispetto al piano: B1 misura i pod pronti durante il sync (minimo 2), E2
  ed E7 verificano che lo StatefulSet legacy resti attivo.
- L'iniezione dei valori vuoti si verifica su `/proc/1/environ` e non con `kubectl exec -- env`
  (§5, "Verifica dell'iniezione").
- Gli scenari con pod che devono andare in crash (E1, E3, E4) lanciano il sync con `--async`:
  dopo l'ultima wave l'operazione non attende la salute dei pod, ma così lo scenario non dipende
  da questo dettaglio.
- E1 svuota il PVC con un pod di servizio RW (`kubectl run` con overrides). E2 rimuove
  `certificate.pem` direttamente dal pod legacy, che monta il volume in scrittura.
- E5 usa un pod con l'immagine del job e il service account `proxy-ca-init`: stampa solo i codici
  HTTP, il token resta nel pod.
- Il `rollout restart` di B3 (prima della Fase 7) veniva annullato dal sync di B4, che faceva un
  secondo rollout (vedi §8).

### Fase 6: risultati
- [x] `docs/results.md`: per ogni scenario esito, evidenze (righe `RESULT:`, log `root_ca_loaded`,
      fingerprint, UID del PVC) ed eventuali note
- [x] sezione "Da portare nel proxy reale": elenco puntuale delle modifiche applicative, con le
      differenze rispetto allo stub
- [x] sezione "Da portare nei chart reali": annotazioni, wave, valori
- [x] `README.md` riletto e allineato allo stato finale; resta minimale

### Fase 7: import della CA legacy in OpenBao
Decisione dell'utente del 2026-11-16, vedi §1. Le note delle fasi 1-6 descrivono il design
iniziale dove citano placeholder, fallback sul volume e `source=legacy-volume` in modalità `new`.

- [x] stub: modalità `new` solo da env, senza fallback sul volume (§4.1); test aggiornati
- [x] job: `ca-imported` al posto di `placeholder-created`, senza validazione dell'import (§4.2)
- [x] chart: il Deployment non monta più il PVC; `check-charts.sh` lo verifica (§4.5)
- [x] scenari: G1, B1, B2 e E1 aggiornati, nuovo B3, rimossi B3 e B4 di prima (§5)
- [x] `run-all.sh` verde da cluster pulito; `docs/results.md`, `README.md` aggiornati

Note di implementazione (Fase 7):
- Il job codifica i file del volume così come sono e stampa il fingerprint del certificato
  importato (`unavailable` se openssl non riesce a leggerlo). Con un secret già presente, con dati,
  non stampa più il warning "the proxy will use the CA from OpenBao": è lo stato normale dopo la
  migrazione.
- Testi del job utili agli scenari: `the proxy will fail`, `incomplete CA on legacy volume`,
  `cannot create`. Lo stub in modalità `new` non produce più `incomplete CA on legacy volume`
  (resta in modalità `legacy`).
- Il caso "secret vuoto" non nasce più dal job: E1 lo crea a mano, per verificare che il job non
  rigeneri la CA.
- Esecuzione di riferimento il 2026-11-16, con la cartella di lavoro su `/app/certs`: `teardown`
  → `setup` → `build` → `run-all` in 14 min 35 s, 16 scenari su 16, 117 asserzioni, 0 fallite.
  Un'esecuzione intermedia (prima dello spostamento su `/app/certs`) era fallita una volta in B0
  per `token is not valid yet` della CLI di Argo CD, subito dopo il login (salto transitorio
  dell'orologio di WSL2): se ricapita, basta rieseguire `run-all.sh`. Dettagli in
  `docs/results.md`.
- **Cartella di lavoro su `/app/certs`** (decisione dell'utente, dopo l'import): senza il PVC nel
  pod non servono due path, quindi l'`emptyDir` è montato su `/app/certs` e il proxy reale non
  deve cambiare base dir. Lo stub usa `/app/certs` in entrambe le modalità (`PROXY_BASE_DIR` solo
  per i test); il valore del chart `appData` diventa `certsDir`. `check-charts.sh` verifica il
  mount e G3 il path del certificato foglia. Rischio residuo: se il nuovo chart rimontasse per
  errore il PVC su `/app/certs`, il proxy scriverebbe sul volume condiviso; lo intercetta il
  controllo "Deployment mounts no PVC" di `check-charts.sh`.

## 7. Punti aperti

Assunzioni da confermare con l'utente. Se durante l'implementazione emergono contraddizioni,
fermarsi e chiedere.

1. **Injector:** si assume che la sintassi `vault:` sia quella del **Bank-Vaults
   vault-secrets-webhook**. Se il cluster reale usa un altro meccanismo, le §4.5 e §5 cambiano.
2. ~~**Comportamento di `vault-env` con valori vuoti:** da verificare in B1 (vedi §5).~~
   **Risolto in B1:** con valori KV vuoti `vault-env` (`v1.23.0`) passa al processo variabili
   presenti e vuote, e il container parte. Dalla Fase 7 non è più rilevante: il job non scrive
   più valori vuoti.
3. **Nomi dei file legacy:** si assume `/app/certs/_ca/private-key.pem` e
   `/app/certs/_ca/certificate.pem`. Da confermare sul proxy reale.
4. **Parametri della CA:** algoritmo, durata e subject devono ricalcare quelli che il proxy reale
   usa oggi. I default della §4.2 sono provvisori.
5. **PVC in produzione:** access mode e StorageClass reali. Il PVC legacy è una risorsa standalone
   del chart, non un `volumeClaimTemplates`? Dalla Fase 7 lo monta solo il job: con
   `ReadWriteOnce` il vincolo riguarda solo il pod del job, che durante la migrazione deve poter
   montare il volume insieme ai pod legacy ancora attivi (stesso nodo).
6. **Sync policy di Argo CD in produzione** (automatica? prune automatico?): influisce sugli
   scenari E6 ed E7.
7. **UID del job:** deve coincidere con quello che ha scritto i file brownfield, altrimenti
   l'import dal volume fallisce per permessi. Dalla Fase 7 il vincolo vale solo per il job.
8. **Path del secret su OpenBao in produzione:** convenzione di naming e mount KV in uso negli altri
   servizi.
9. **`PruneLast=true` sulle Application reali** (emerso in Fase 5, vedi §4.6): senza questa
   opzione la migrazione brownfield causa un disservizio, e un job fallito lascia il proxy senza
   pod. Da verificare che sia compatibile con la sync policy in uso in produzione (punto 6).
10. **`podsFailurePolicy` del webhook in produzione:** il default del chart è `Ignore`. Se il
    webhook non risponde, il proxy parte con il valore letterale `vault:…` e fallisce con
    `is not valid base64`: il messaggio è fuorviante. Nella PoC si usa `Fail` (vedi Fase 4).

## 8. Da documentare per il passaggio in produzione (fuori PoC)

- Migrazione di un'installazione brownfield: è automatica (scenario B1). Dopo il sync verificare
  che il job riporti `RESULT: ca-imported` con il fingerprint della CA legacy, e che il log
  `root_ca_loaded` dei pod abbia `source=env` e lo stesso fingerprint.
- Rimozione del PVC legacy: dopo che tutte le installazioni sono migrate, una versione successiva
  del chart può togliere il PVC e il mount del job. Il PVC non viene eliminato da Argo CD
  (`Prune=false`, `Delete=false`): va cancellato a mano quando non serve più.
- Redeploy: preferire un sync di Argo CD a un `rollout restart`, che il sync successivo annulla con
  un secondo rollout.
- Rotazione e scadenza della root CA: oggi non gestite.
- Monitoraggio: alert su `CrashLoopBackOff` del proxy e sul fallimento del job di provisioning.
