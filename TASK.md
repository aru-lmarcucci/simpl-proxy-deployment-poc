**Soluzione scelta**

<ins>Modifiche applicative</ins>

Modifichiamo il proxy affinché legga private key e certificato da env var all'avvio
(iniettate come negli altri pod, nomi delle env var: `ROOT_CA_PRIVATE_KEY`, `ROOT_CA_CERTIFICATE` ,
codificate in base64 per evitare problemi con il multilinea); se entrambe sono presenti
e non vuote, vengono validate (la chiave corrisponde al certificato, il certificato è una CA ed è
nel periodo di validità) e scritte su file (`/app/certs/_ca/private-key.pem` e
`/app/certs/_ca/certificate.pem` , gli stessi path usati oggi).

Se queste variabili NON sono presenti O sono vuote (anche una sola delle due), il proxy esce con un
errore prima di avviarsi (a differenza di quanto accade attualmente, non genera più la CA da solo).
In brownfield la CA presente sul volume persistente viene importata su OpenBao dal job di
provisioning (vedi sotto) e arriva al proxy tramite le stesse env var: il proxy non ha più bisogno
del volume persistente.

Loggare esplicitamente la fonte e il fingerprint della root CA caricata (mai il contenuto della
chiave); i messaggi di errore nominano la variabile, mai il valore.

La cartella base dei certificati resta `/app/certs`: il resto del codice del proxy rimane
invariato. Cambia solo cosa c'è dietro quel path (un volume locale per istanza invece del volume
persistente condiviso, vedi sotto).


<ins>Modifiche al deploy</ins>

Bisogna adattare i chart Helm del proxy:

- ogni istanza del proxy monta un volume `emptyDir` su `/app/certs` (uno per ogni istanza, sullo
  stesso path usato oggi dal PVC); il proxy **non** monta più il PVC legacy.
- le variabili d'ambiente `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE` devono essere
  iniettate da OpenBao tramite riferimento `vault:...` .
- il proxy diventa un Deployment invece di uno StatefulSet.
- il PVC legacy resta nel chart, con lo stesso nome e lo stesso spec di quello attuale (i campi
  `accessModes`, `storageClassName`, `volumeName` e `selector` sono immutabili), protetto da
  prune e delete di ArgoCD; lo monta solo il job di provisioning.
- le Application ArgoCD usano `PruneLast=true`, così lo StatefulSet legacy viene eliminato solo
  dopo che il nuovo Deployment è pronto (nessun disservizio durante la migrazione, e se il job
  fallisce lo StatefulSet resta attivo).


Inoltre bisogna fare in modo che i secret relativi a `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE`
vengano generati su OpenBao prima dell'avvio del proxy, tramite job via ArgoCD. In particolare,
il job monta in sola lettura il PVC legacy (con lo stesso UID del proxy attuale, per poter leggere
la chiave privata) e:

- se i file della CA esistono sul volume e non esistono i secret su OpenBao, importa su OpenBao
  il contenuto dei file così come sono, codificati in base64.
- se i file non esistono su PVC e i secret non esistono su OpenBao, crea i secret con una nuova
  CA, codificati in base64.
- se i secret esistono già su OpenBao, non fa nulla: il job non sovrascrive mai un secret e non rigenera mai una CA.
- se sul volume c'è uno solo dei due file, esce con errore (e il sync di ArgoCD fallisce).


<ins>Risultati attesi</ins>

- Per installazioni greenfield, il job genera la CA su OpenBao e il proxy la riceve tramite le env
  var `ROOT_CA_PRIVATE_KEY` e `ROOT_CA_CERTIFICATE`, ricreando i file della CA ad ogni avvio. Senza
  env var valorizzate, il proxy va in errore.
- Per installazioni brownfield, al primo sync del nuovo chart il job importa su OpenBao la CA
  presente sul volume; il proxy la riceve tramite env var, con lo stesso fingerprint di prima.
  Da quel momento la CA sul volume non serve più.
- Per installazioni brownfield, è importante che il prune di ArgoCD non elimini i PVC già esistenti.
- Usando un volume `emptyDir` locale per ogni istanza del proxy per la scrittura/lettura dei
  certificati a runtime, i certificati diventano di fatto effimeri (ovvero, non sopravvivano a 
  scale-to-0 o redeploy del proxy) e non dobbiamo più preoccuparci di scritture simultanee.
- Date le premesse dei punti precedenti, possiamo tornare ad usare un Deployment per il proxy:
  il proxy è stateless e non monta volumi condivisi, quindi le repliche possono girare anche su
  nodi diversi.


In questo repo: [GitHub aru-lmarcucci/simpl-proxy-deployment-poc](https://github.com/aru-lmarcucci/simpl-proxy-deployment-poc)
trovate una POC fatta con Claude, da usare come punto di partenza se volete (specialmente per
la modifica dei chart e del processo di deploy).
