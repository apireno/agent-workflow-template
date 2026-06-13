# DBA — Project-Specific Database Context

<!-- CUSTOMIZE per project. This stub is the template default. -->

**Storage engine(s):** {e.g. SurrealDB 2.3.10 embedded / LanceDB file-based / Postgres}
**Client/driver version(s):** {e.g. surrealdb-py X.Y.Z — note the client↔server version mapping}

## Hot query mix
- {vector ANN search — index type, dim}
- {full-text / BM25 — analyzer, inverted index}
- {graph traversal — edge types, max depth/cardinality bounds}
- {point lookups / scans — supporting indexes}

## Data model
- {tables / graph tables, edges}
- **Multi-tenancy keys:** {e.g. `{repo, project}` on every record}
- **Provenance / version stamps:** {e.g. source uri + char offsets; embedding-model canary}

## Index inventory
| Index | Serves query | Type |
|---|---|---|
| {…} | {…} | {…} |

## Re-index / migration triggers
- {file edit → offset drift → re-chunk}
- {embedding-model change → re-embed (a migration; needs a canary)}

## Concurrency / ops
- {single-writer? embedded? networked? backup/restore — coordinate with VP DevOps}
