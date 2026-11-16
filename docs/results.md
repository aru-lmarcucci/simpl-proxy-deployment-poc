# Risultati della PoC

Esecuzione di riferimento del 2026-11-16 su cluster pulito:
`poc/teardown.sh` → `poc/setup.sh` → `poc/build.sh` → `poc/scenarios/run-all.sh`.
Durata totale 19 min 16 s, exit code 0. Versioni in [poc/versions.env](../poc/versions.env)
(kind node v1.36.4, OpenBao 2.7.2, vault-secrets-webhook 1.23.1, Argo CD v3.6.1).

**Esito: 17 scenari su 17 superati, 125 asserzioni, 0 fallite.**

I log completi di ogni esecuzione sono in `.tmp/scenario-logs/` (ignorata da git). I fingerprint
sono SHA-256 del certificato della root CA, in hex minuscolo; i log non contengono chiavi, PEM o
token.

## Riepilogo

| ID  | Scenario                                     | Esito | Asserzioni | Durata |
| --- | -------------------------------------------- | ----- | ---------- | ------ |
| G1  | primo sync greenfield                        | PASS  | 12         | 42 s   |
| G2  | nuovo sync greenfield                        | PASS  | 8          | 19 s   |
| G3  | certificati foglia locali al pod             | PASS  | 4          | 4 s    |
| G4  | scale 0 → 2                                  | PASS  | 7          | 21 s   |
| G5  | rollout restart                              | PASS  | 7          | 21 s   |
| B0  | stato brownfield con il chart legacy 1.0.0   | PASS  | 7          | 31 s   |
| B1  | migrazione a 2.0.0 con prune                 | PASS  | 16         | 32 s   |
| B2  | nuovo sync brownfield                        | PASS  | 10         | 20 s   |
| B3  | copia della CA del volume in OpenBao         | PASS  | 6          | 19 s   |
| B4  | nuovo sync dopo la migrazione                | PASS  | 10         | 150 s  |
| E1  | placeholder vuoto e CA persa dal PVC         | PASS  | 8          | 108 s  |
| E2  | CA incompleta sul PVC                        | PASS  | 7          | 81 s   |
| E3  | secret parziale                              | PASS  | 4          | 56 s   |
| E4  | secret non valido (base64, chiave sbagliata) | PASS  | 5          | 70 s   |
| E5  | il job non può sovrascrivere il secret       | PASS  | 4          | 28 s   |
| E6  | PVC tolto dal chart, sync con prune          | PASS  | 3          | 80 s   |
| E7  | `accessModes` diverso dal legacy             | PASS  | 6          | 69 s   |

## Greenfield (`proxy-green`)

**G1: primo sync (chart 2.0.0).** PASS.
- Job: `legacy volume: absent, secret …: absent` → `RESULT: ca-generated`,
  `FINGERPRINT_SHA256: bf2f8ffd80a9716aef9c6caf5f106d9308ee8d1fc7e3d5943ddec8f3d0e78db6`.
- Secret in OpenBao: versione 1, `private_key` 4364 caratteri, `certificate` 2452.
- Deployment con 2 repliche pronte. Su entrambi i pod:
  `{"event": "root_ca_loaded", "source": "env", "fingerprint_sha256": "bf2f8ffd…78db6", "subject": "CN=Proxy Root CA", …, "mode": "new"}`,
  uguale al fingerprint del job.
- Variabili iniettate da `vault-env` nel processo (solo lunghezze): `ROOT_CA_PRIVATE_KEY` 4364,
  `ROOT_CA_CERTIFICATE` 2452.
- PVC `proxy-certs` `Bound` e vuoto: l'ordine wave 0 (PVC + job) → wave 1 (Deployment) funziona
  con la StorageClass `WaitForFirstConsumer`.

**G2: nuovo sync.** PASS. Job `RESULT: noop`, versione del secret invariata (1), stesso
fingerprint su tutti i pod.

**G3: certificati foglia locali.** PASS. `/issue?host=a.example` sul pod 1 →
`{"path": "/app-data/certs/a.example/cert.pem", "reused": false}`. `/certs`: `["a.example"]` sul
pod 1, `[]` sul pod 2.

**G4: scale 0 → 2.** PASS. Nuovi pod con `source=env` e fingerprint `bf2f8ffd…78db6`; `/certs`
vuoto su entrambi (il certificato `g4.example` emesso prima dello scale è sparito).

**G5: rollout restart.** PASS. Come G4, con certificati `g5.example` emessi su tutti i pod prima
del restart e assenti dopo.

## Brownfield (`proxy-brown`)

**B0: chart legacy 1.0.0.** PASS.
- StatefulSet con 2 repliche pronte. `proxy-0` genera la CA (`source=generated`), `proxy-1` la
  legge dal volume (`source=legacy-volume`), stesso fingerprint.
- `FP_LEGACY = 165bb1d2fbf7c708adb990b53114d8802daffda832a49b1d2a07388d6674cb28`
  (`CN=Proxy Root CA (legacy)`), `PVC_UID = d1a19486-5250-4794-9227-8ecdd0dbb06a`.
- Sul PVC: `_ca/certificate.pem`, `_ca/private-key.pem` e il certificato foglia `b.example`.
- Nessun secret in OpenBao.

**B1: migrazione a 2.0.0, sync con prune.** PASS.
- Job: `legacy volume: present, secret …: absent` → `RESULT: placeholder-created`. Secret
  versione 1 con valori vuoti.
- StatefulSet e Service `proxy-headless` eliminati dal prune; Service `proxy` presente; PVC con
  lo stesso UID `d1a19486-…-8ecdd0dbb06a`.
- Variabili iniettate con valori KV vuoti: `{"ROOT_CA_CERTIFICATE": 0, "ROOT_CA_PRIVATE_KEY": 0}`
  su entrambi i pod, cioè presenti e vuote. Il container parte (punto aperto 2 risolto).
- Entrambi i pod: `source=legacy-volume`, fingerprint `FP_LEGACY`.
- Scrittura su `/app/certs`: `touch: cannot touch '/app/certs/b1-write-test': Read-only file system`.
- Disponibilità durante il sync (`PruneLast=true`): minimo 2 pod pronti, 0 campioni su 21 con 0
  pod pronti. Senza `PruneLast` la stessa migrazione aveva 0 pod pronti per 17 campioni su 20 (vedi
  sotto, "Scoperte").

**B2: nuovo sync.** PASS. Job `RESULT: noop` senza warning, secret ancora vuoto alla versione 1,
fingerprint `FP_LEGACY` con `source=legacy-volume`.

**B3: migrazione della CA in OpenBao.** PASS. Lo script di supporto (root token) copia nel secret
la CA letta dal volume, con `cas=1`: secret versione 2, `private_key` 4364, `certificate` 2424.
Dopo il `rollout restart` entrambi i pod hanno `source=env` e fingerprint ancora `FP_LEGACY`.

**B4: nuovo sync dopo la migrazione.** PASS. Job: `legacy volume: present, secret …: data`,
`WARN: secret has data: the proxy will use the CA from OpenBao, not the one on the legacy volume`,
`RESULT: noop`. Secret ancora alla versione 2 e non svuotato; `source=env`, fingerprint `FP_LEGACY`.
La durata (150 s) dipende da un secondo rollout: vedi "Scoperte".

## Casi di errore

Ogni scenario usa un namespace temporaneo `proxy-err-*` e lo elimina alla fine, insieme ad
Application, ruoli, policy e secret su OpenBao.

**E1: placeholder vuoto e CA persa dal PVC.** PASS. Dopo la migrazione brownfield
(`placeholder-created`) e la cancellazione di `_ca` con un pod di servizio RW:
- job `legacy volume: absent, secret …: empty` →
  `WARN: secret is an empty placeholder and the legacy volume has no CA: the proxy will fail (no root CA available)`,
  `RESULT: noop`; secret ancora vuoto alla versione 1 (nessuna CA rigenerata);
- pod in `CrashLoopBackOff` con
  `ERROR: no root CA available: ROOT_CA_PRIVATE_KEY/ROOT_CA_CERTIFICATE are empty and /app/certs/_ca has no CA files`.

**E2: CA incompleta sul PVC.** PASS. Sul PVC resta solo `private-key.pem`.
- Job: `ERROR: incomplete CA on legacy volume /legacy-certs/_ca: expected both private-key.pem and certificate.pem, non-empty`.
- Sync `Failed` (`one or more synchronization tasks completed unsuccessfully`); Deployment non
  creato; nessun secret scritto.
- Con `PruneLast=true` lo StatefulSet legacy non viene eliminato e resta con 2 repliche pronte.

**E3: secret parziale.** PASS. Secret con `private_key` di 16 caratteri e `certificate` vuoto.
Job: `WARN: secret has only one of private_key/certificate: the proxy will fail (partial configuration)`,
`RESULT: noop`. Pod in `CrashLoopBackOff` con
`ERROR: partial configuration: ROOT_CA_PRIVATE_KEY is set but ROOT_CA_CERTIFICATE is empty`.

**E4: secret non valido.** PASS.
- Base64 non valido: `ERROR: ROOT_CA_PRIVATE_KEY is not valid base64`; il marcatore inserito nel
  valore non compare nei log.
- Chiave e certificato di due CA diverse: `ERROR: root CA private key does not match the certificate`;
  nei log non compaiono né un frammento della chiave né `PRIVATE KEY`.

**E5: nessuna sovrascrittura.** PASS. Da un pod con il service account `proxy-ca-init` e il suo
ruolo OpenBao: `read=200 write-cas=403 write-nocas=403`; versione del secret invariata.

**E6: PVC non eliminato dal prune.** PASS. Con `legacyCerts.renderPvc=false` il sync con prune
riesce, Argo CD segna il PVC `{"status":"OutOfSync","requiresPruning":true}` ma non lo elimina
(stesso UID).

**E7: `accessModes` diverso dal legacy.** PASS (fallimento atteso). Sync `Failed` con
`PersistentVolumeClaim "proxy-certs" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims`.
Il PVC resta `ReadWriteOnce` e, grazie a `PruneLast=true`, lo StatefulSet legacy resta attivo
con 2 repliche pronte. Il rischio è reale: un drift dello spec del PVC tra i due chart blocca la
migrazione. `poc/check-charts.sh` lo intercetta prima del deploy.

## Scoperte e differenze rispetto al piano

1. **Prune nella wave della risorsa (decisione: `PruneLast=true`).** Senza `PruneLast` Argo CD
   elimina lo StatefulSet legacy nella wave 0, in parallelo al job, e non alla fine del sync.
   Misurato: 0 pod pronti per circa 17 s durante la migrazione B1 e proxy senza pod in E2 (job
   fallito, StatefulSet già eliminato, Deployment mai creato). Con `PruneLast=true` nelle
   `syncOptions` dell'Application non ci sono momenti senza pod e lo StatefulSet resta se il sync
   fallisce. Decisione confermata dall'utente; §4.6 del piano aggiornata.
2. **`vault-env` con valori vuoti.** Le variabili arrivano al processo presenti e vuote: lo
   scenario brownfield funziona senza accorgimenti. `kubectl exec -- env` non è un buon modo per
   verificarlo, perché mostra i valori dello spec (`vault:…`). Gli scenari leggono
   `/proc/1/environ`.
3. **`rollout restart` e sync successivo.** Il restart aggiunge l'annotazione
   `kubectl.kubernetes.io/restartedAt` al template del pod. Il sync successivo di Argo CD la
   rimuove e provoca un secondo rollout (B4: `deployment.apps/proxy configured`, 150 s). Non ha
   effetti sulla CA, ma in produzione la procedura di migrazione (§8) deve usare un sync al posto
   del `rollout restart`, oppure prevedere il secondo rollout.
4. **Webhook con `podsFailurePolicy=Fail`.** Con il default del chart (`Ignore`), se il webhook
   non risponde il proxy parte con il valore letterale `vault:…` e fallisce con
   `is not valid base64`, un messaggio fuorviante. Nella PoC si usa `Fail`, limitato ai namespace
   applicativi.
5. **Messaggi in inglese.** Le stringhe della §5 del piano ("il proxy fallirà", "nessuna root CA
   disponibile"…) corrispondono ai messaggi in inglese di stub e job (`the proxy will fail`,
   `no root CA available`…), come chiede `AGENTS.md`.

## Da portare nel proxy reale

Modifiche applicative, con le differenze rispetto allo stub:

1. All'avvio leggere `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE`. Un valore vuoto o fatto solo
   di spazi equivale a "assente". Prima della decodifica base64 togliere spazi e a-capo.
2. Applicare la matrice della §4.1:
   - entrambe valorizzate → CA da env;
   - una sola valorizzata → errore `partial configuration`;
   - nessuna → file in `/app/certs/_ca`; uno solo presente → errore `incomplete CA`; nessuno →
     errore `no root CA available`.
3. Validare la CA con le stesse regole per le due fonti: la chiave corrisponde al certificato, il
   certificato ha `basicConstraints CA:TRUE` ed è nel periodo di validità.
4. Copiare la CA in `/app-data/certs/_ca`: directory `0700`, chiave `0600`, certificato `0644`.
   Non scrivere mai sotto `/app/certs`.
5. In caso di errore uscire con codice diverso da 0 **prima** di aprire la porta, con un
   messaggio che nomina la variabile o il file e mai il valore. Il proxy non deve più generare la
   CA da solo.
6. Loggare una riga strutturata `root_ca_loaded` con `source` (`env` | `legacy-volume`),
   fingerprint SHA-256, subject e scadenza. È l'evidenza da usare nella migrazione.
7. Base dir dei certificati foglia: `/app-data/certs`. Il resto del codice non cambia.
8. Gestire `SIGTERM` se il processo gira come PID 1 (lo stub lo fa, altrimenti ogni stop attende
   il grace period di 30 s).

Differenze rispetto allo stub: lo stub usa Python e `cryptography`, chiavi foglia EC P-256 e un
server HTTP minimale; nel proxy reale contano solo la matrice, la validazione, i path, i permessi,
il log e il comportamento in caso di errore. Restano da confermare i nomi dei file legacy (punto
aperto 3) e i parametri della CA (punto aperto 4).

## Da portare nei chart reali

- **PVC legacy:** stesso nome e **stesso spec** del chart attuale (`accessModes`,
  `storageClassName`, `volumeName`, `selector` immutabili; la dimensione può solo crescere).
  Annotazioni: `argocd.argoproj.io/sync-options: Delete=false,Prune=false`,
  `helm.sh/resource-policy: keep`, `argocd.argoproj.io/sync-wave: "0"`. Va creato sempre, anche
  in greenfield. Un controllo come `poc/check-charts.sh` in CI evita il drift (E7).
- **Job di provisioning:** hook `Sync` (non `PreSync`), `hook-delete-policy: BeforeHookCreation`,
  `sync-wave: "0"`, nella **stessa wave del PVC**. ServiceAccount dedicato, PVC montato in sola
  lettura, `/tmp` in memoria, **stesso UID del proxy** (la chiave legacy è `0600`),
  `backoffLimit: 1`, `activeDeadlineSeconds: 300`. Label diverse da quelle del proxy, così il
  Service non seleziona i pod del job.
- **Deployment:** `sync-wave: "1"`, `command` esplicito (necessario al webhook se l'immagine non
  è leggibile dal registry), `emptyDir` su `/app-data/certs`, PVC in sola lettura su `/app/certs`
  (sia `readOnly` sul mount sia sul volume), stesso UID e `fsGroup` del chart attuale, env
  `vault:<path>#private_key` e `vault:<path>#certificate`, annotazioni del webhook.
- **OpenBao:** per namespace, una policy del job con `["create", "read"]` **senza `update`** (il
  job non può sovrascrivere, E5) e una policy del proxy con `["read"]`; ruoli Kubernetes legati
  ai rispettivi ServiceAccount.
- **Application Argo CD:** `syncOptions` con **`PruneLast=true`** (B1, E2, E7). Valori specifici
  dell'ambiente (StorageClass, access mode, path del secret) nell'Application, non nel chart.
- **Webhook:** valutare `podsFailurePolicy=Fail` per i namespace del proxy (scoperta 4).
