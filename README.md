# Code Mycelial Network (CMN)

A sovereign-first protocol for code distribution and evolution tracking. Domains publish signed, hash-verified packages — no central registry.

Homepage: https://cmn.dev

## Install

```powershell
scoop bucket add cmnspore https://github.com/cmnspore/scoop-bucket
```

Then run one complete 64-bit Windows install command from the table.

## Manifests

| Manifest | Version | Install command | Description |
|---|---|---|---|
| [hypha](bucket/hypha.json) | 0.5.1 | `scoop install cmnspore/hypha` | The reference CMN client CLI — release spores, query synapses, resolve bonds, and manage your local mycelium. |
| [synapse](bucket/synapse.json) | 0.3.0 | `scoop install cmnspore/synapse` | The reference CMN indexer — ingests signed manifests, indexes spores and myceliums, serves discovery queries, and syncs across instances via Nostr. |
