# Risultati della PoC

Esecuzione di riferimento del 2026-11-16, dopo la Fase 7 del piano (import della CA legacy in
OpenBao, proxy senza volume, cartella di lavoro su `/app/certs`): `poc/teardown.sh` →
`poc/setup.sh` → `poc/build.sh` → `poc/scenarios/run-all.sh`. Durata totale 14 min 35 s (scenari
10 min 9 s), exit code 0. Versioni in [poc/versions.env](../poc/versions.env) (kind node v1.36.4,
OpenBao 2.7.2, vault-secrets-webhook 1.23.1, Argo CD v3.6.1).

**Esito: 16 scenari su 16 superati, 117 asserzioni, 0 fallite.**

L'esecuzione precedente (design iniziale con placeholder vuoto e fallback sul volume, 17 scenari,
125 asserzioni, tutte verdi) è descritta nella cronologia git di questo file.

I log completi di ogni esecuzione sono in `.tmp/scenario-logs/` (ignorata da git). I fingerprint
sono SHA-256 del certificato della root CA, in hex minuscolo; i log non contengono chiavi, PEM o
token.

## Riepilogo

| ID  | Scenario                                     | Esito | Asserzioni | Durata |
| --- | -------------------------------------------- | ----- | ---------- | ------ |
| G1  | primo sync greenfield                        | PASS  | 13         | 36 s   |
| G2  | nuovo sync greenfield                        | PASS  | 8          | 16 s   |
| G3  | certificati foglia locali al pod             | PASS  | 5          | 4 s    |
| G4  | scale 0 → 2                                  | PASS  | 7          | 20 s   |
| G5  | rollout restart                              | PASS  | 7          | 20 s   |
| B0  | stato brownfield con il chart legacy 1.0.0   | PASS  | 7          | 33 s   |
| B1  | migrazione a 2.0.0 con prune (import CA)     | PASS  | 17         | 33 s   |
| B2  | nuovo sync brownfield                        | PASS  | 9          | 17 s   |
| B3  | CA cancellata dal PVC dopo la migrazione     | PASS  | 10         | 25 s   |
| E1  | secret vuoto creato a mano, PVC senza CA     | PASS  | 5          | 50 s   |
| E2  | CA incompleta sul PVC                        | PASS  | 7          | 77 s   |
| E3  | secret parziale                              | PASS  | 4          | 51 s   |
| E4  | secret non valido (base64, chiave sbagliata) | PASS  | 5          | 62 s   |
| E5  | il job non può sovrascrivere il secret       | PASS  | 4          | 21 s   |
| E6  | PVC tolto dal chart, sync con prune          | PASS  | 3          | 65 s   |
| E7  | `accessModes` diverso dal legacy             | PASS  | 6          | 64 s   |

## Greenfield (`proxy-green`)

**G1: primo sync (chart 2.0.0).** PASS.
- Job: `legacy volume: absent, secret …: absent` → `RESULT: ca-generated`,
  `FINGERPRINT_SHA256: 3692b8c774c88d33d5613abfa12f775dcb3e88b245c69fc45248a0e57eb62231`.
- Secret in OpenBao: versione 1, `private_key` 4364 caratteri, `certificate` 2452.
- Deployment con 2 repliche pronte. Su entrambi i pod:
  `{"event": "root_ca_loaded", "source": "env", "fingerprint_sha256": "3692b8c7…62231", "subject": "CN=Proxy Root CA", …, "mode": "new"}`,
  uguale al fingerprint del job.
- Variabili iniettate da `vault-env` nel processo (solo lunghezze): `ROOT_CA_PRIVATE_KEY` 4364,
  `ROOT_CA_CERTIFICATE` 2452.
- PVC `proxy-certs` `Bound`, senza CA (`legacy volume: absent` nel log del job), montato solo dal
  job: il Deployment non ha volumi PVC. L'ordine wave 0 (PVC + job) → wave 1 (Deployment) funziona
  con la StorageClass `WaitForFirstConsumer`.

**G2: nuovo sync.** PASS. Job `RESULT: noop`, versione del secret invariata (1), stesso
fingerprint su tutti i pod.

**G3: certificati foglia locali.** PASS. `/issue?host=a.example` sul pod 1 →
`{"path": "/app/certs/a.example/cert.pem", "reused": false}` (l'`emptyDir` del pod). `/certs`: `["a.example"]` sul
pod 1, `[]` sul pod 2.

**G4: scale 0 → 2.** PASS. Nuovi pod con `source=env` e fingerprint `3692b8c7…62231`; `/certs`
vuoto su entrambi (il certificato `g4.example` emesso prima dello scale è sparito).

**G5: rollout restart.** PASS. Come G4, con certificati `g5.example` emessi su tutti i pod prima
del restart e assenti dopo.

## Brownfield (`proxy-brown`)

**B0: chart legacy 1.0.0.** PASS.
- StatefulSet con 2 repliche pronte. `proxy-0` genera la CA (`source=generated`), `proxy-1` la
  legge dal volume (`source=legacy-volume`), stesso fingerprint.
- `FP_LEGACY = 14733771e475f24f116901868ad898281ced96bdf47169105cd029ccc5943df2`
  (`CN=Proxy Root CA (legacy)`), `PVC_UID = e0843358-fe16-4c0f-bd2f-83f9ddeb6fe6`.
- Sul PVC: `_ca/certificate.pem`, `_ca/private-key.pem` e il certificato foglia `b.example`.
- Nessun secret in OpenBao.

**B1: migrazione a 2.0.0, sync con prune.** PASS.
- Job: `legacy volume: present, secret …: absent`, `importing the root CA from the legacy volume`,
  `FINGERPRINT_SHA256: 14733771…943df2` (= `FP_LEGACY`), `RESULT: ca-imported`. Secret versione 1,
  `private_key` 4364 caratteri, `certificate` 2424.
- StatefulSet e Service `proxy-headless` eliminati dal prune; Service `proxy` presente; PVC con
  lo stesso UID `e0843358-…-83f9ddeb6fe6`. Il Deployment non monta il PVC.
- Variabili iniettate: `{"ROOT_CA_CERTIFICATE": 2424, "ROOT_CA_PRIVATE_KEY": 4364}` su entrambi i
  pod.
- Entrambi i pod: `source=env`, fingerprint `FP_LEGACY`, `subject` `CN=Proxy Root CA (legacy)`.
- Disponibilità durante il sync (`PruneLast=true`): minimo 2 pod pronti, 0 campioni su 22 con 0
  pod pronti.

**B2: nuovo sync.** PASS. Job `legacy volume: present, secret …: data` → `RESULT: noop` senza
warning; versione del secret invariata (1); `source=env`, fingerprint `FP_LEGACY`.

**B3: CA cancellata dal PVC dopo la migrazione.** PASS. Un pod di servizio RW cancella `_ca`: sul
PVC resta solo `b.example`. Il sync successivo: job `legacy volume: absent, secret …: data` →
`RESULT: noop` senza warning, versione del secret invariata. Dopo il `rollout restart` entrambi i
nuovi pod hanno `source=env` e fingerprint `FP_LEGACY`: il volume non serve più.

## Casi di errore

Ogni scenario usa un namespace temporaneo `proxy-err-*` e lo elimina alla fine, insieme ad
Application, ruoli, policy e secret su OpenBao.

**E1: secret vuoto creato a mano, PVC senza CA.** PASS. Secret versione 1 con valori vuoti,
scritto con il root token prima del primo sync:
- job `legacy volume: absent, secret …: empty` →
  `WARN: secret has empty values: the proxy will fail (no root CA available)`, `RESULT: noop`;
  secret ancora vuoto alla versione 1 (nessuna CA rigenerata);
- pod in `CrashLoopBackOff` con
  `ERROR: no root CA available: ROOT_CA_PRIVATE_KEY/ROOT_CA_CERTIFICATE are empty`.

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
2. **`vault-env` con valori vuoti** (design iniziale). Le variabili arrivavano al processo
   presenti e vuote. Dalla Fase 7 il job non scrive più valori vuoti. Resta valido il metodo di
   verifica: `kubectl exec -- env` mostra i valori dello spec (`vault:…`), quindi gli scenari
   leggono `/proc/1/environ`.
3. **`rollout restart` e sync successivo.** Il restart aggiunge l'annotazione
   `kubectl.kubernetes.io/restartedAt` al template del pod. Il sync successivo di Argo CD la
   rimuove e provoca un secondo rollout (osservato nel design iniziale: 150 s in B4). Non ha
   effetti sulla CA, ma per i redeploy in produzione è meglio un sync (§8 del piano).
4. **Webhook con `podsFailurePolicy=Fail`.** Con il default del chart (`Ignore`), se il webhook
   non risponde il proxy parte con il valore letterale `vault:…` e fallisce con
   `is not valid base64`, un messaggio fuorviante. Nella PoC si usa `Fail`, limitato ai namespace
   applicativi.
5. **Messaggi in inglese.** Le stringhe della §5 del piano ("il proxy fallirà", "nessuna root CA
   disponibile"…) corrispondono ai messaggi in inglese di stub e job (`the proxy will fail`,
   `no root CA available`…), come chiede `AGENTS.md`.
6. **Import della CA legacy (Fase 7, decisione dell'utente).** Il job importa in OpenBao i file
   del volume così come sono, senza validarli: se sono sbagliati lo erano già per il proxy legacy,
   e il proxy lo segnala all'avvio. Effetti misurati: B1 ha la stessa CA (`FP_LEGACY`) con
   `source=env`; il Deployment non monta il PVC; B3 mostra che dopo la migrazione la perdita della
   CA sul PVC non ha conseguenze. Il caso "secret vuoto" non nasce più dal job (E1 lo crea a mano).

## Da portare nel proxy reale

Modifiche applicative, con le differenze rispetto allo stub:

1. All'avvio leggere `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE`. Un valore vuoto o fatto solo
   di spazi equivale a "assente". Prima della decodifica base64 togliere spazi e a-capo.
2. Applicare la matrice della §4.1:
   - entrambe valorizzate → CA da env;
   - una sola valorizzata → errore `partial configuration`;
   - nessuna → errore `no root CA available`.
   Il proxy non legge più `/app/certs`.
3. Validare la CA: la chiave corrisponde al certificato, il certificato ha `basicConstraints
   CA:TRUE` ed è nel periodo di validità. È l'unico controllo sulla CA importata dal volume.
4. Scrivere la CA in `/app/certs/_ca` (gli stessi path di oggi): directory `0700`, chiave
   `0600`, certificato `0644`.
5. In caso di errore uscire con codice diverso da 0 **prima** di aprire la porta, con un
   messaggio che nomina la variabile e mai il valore. Il proxy non deve più generare la CA da solo.
6. Loggare una riga strutturata `root_ca_loaded` con `source` (`env`), fingerprint SHA-256,
   subject e scadenza. È l'evidenza da usare nella migrazione.
7. Base dir dei certificati: resta `/app/certs`, che nel nuovo chart è un `emptyDir` per istanza.
   Il resto del codice non cambia.
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
  in greenfield, e lo monta solo il job. Un controllo come `poc/check-charts.sh` in CI evita il
  drift (E7).
- **Job di provisioning:** hook `Sync` (non `PreSync`), `hook-delete-policy: BeforeHookCreation`,
  `sync-wave: "0"`, nella **stessa wave del PVC**. Importa la CA legacy o ne genera una.
  ServiceAccount dedicato, PVC montato in sola lettura, `/tmp` in memoria, **stesso UID del
  proxy legacy** (la chiave legacy è `0600`),
  `backoffLimit: 1`, `activeDeadlineSeconds: 300`. Label diverse da quelle del proxy, così il
  Service non seleziona i pod del job.
- **Deployment:** `sync-wave: "1"`, `command` esplicito (necessario al webhook se l'immagine non
  è leggibile dal registry), `emptyDir` su `/app/certs` (stesso path del PVC di oggi), **nessun
  PVC**, stesso UID e
  `fsGroup` del chart attuale, env
  `vault:<path>#private_key` e `vault:<path>#certificate`, annotazioni del webhook.
- **OpenBao:** per namespace, una policy del job con `["create", "read"]` **senza `update`** (il
  job non può sovrascrivere, E5) e una policy del proxy con `["read"]`; ruoli Kubernetes legati
  ai rispettivi ServiceAccount.
- **Application Argo CD:** `syncOptions` con **`PruneLast=true`** (B1, E2, E7). Valori specifici
  dell'ambiente (StorageClass, access mode, path del secret) nell'Application, non nel chart.
- **Webhook:** valutare `podsFailurePolicy=Fail` per i namespace del proxy (scoperta 4).
