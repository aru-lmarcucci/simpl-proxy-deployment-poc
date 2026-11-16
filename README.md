# PoC: root CA del proxy da OpenBao

Dimostra che il nuovo chart del proxy (Deployment, root CA iniettata da OpenBao con fallback sul
volume legacy) funziona in automatico sia in installazioni nuove sia in quelle esistenti, su un
cluster kind locale. Il proxy è sostituito da uno stub.

Dettagli in [docs/plan.md](docs/plan.md), esiti in [docs/results.md](docs/results.md).

## Prerequisiti

`docker`, `kind`, `kubectl`, `helm`, `argocd`, `curl`, `jq`, `python` ≥ 3.12.
`kind` e `argocd` devono avere esattamente le versioni di [poc/versions.env](poc/versions.env).

## Esecuzione

```bash
poc/setup.sh               # cluster kind "proxy-poc" con OpenBao, webhook, Argo CD, ChartMuseum
poc/build.sh               # immagini e chart
poc/scenarios/run-all.sh   # scenari e riepilogo (log in .tmp/scenario-logs/)
poc/teardown.sh            # elimina il cluster
```

Da cluster pulito servono circa 20 minuti: 5 per setup e build, 15 per gli scenari. `run-all.sh`
si può rieseguire sullo stesso cluster. Un singolo scenario si lancia con
`poc/scenarios/<id>-*.sh`, rispettando l'ordine (B1 dipende da B0, ecc.).

Verifiche senza cluster:

```bash
cd app && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest      # stub
cd .. && poc/check-charts.sh     # chart: lint, template, spec del PVC
```
