# Watchlist n8n workflows

Four separate n8n workflows backing the "things to watch/read" feature: a public add-form, a themed view page, a status-change action, and a delete action — the latter two are only ever hit via links on the view page, not visited directly. Backed by the `watchlist` Postgres database and `to_watch` table set up in `configuration.nix`.

Note: each file embeds a `credentials` block referencing a Postgres credential ID that only exists inside this specific n8n instance — re-export from n8n (or hand-edit these files) if you want a fresh backup; importing an old one still requires re-pointing that credential.

## Files
| File | n8n workflow name | Trigger |
|---|---|---|
| `add-to-watchlist.json` | Add to Watchlist | Form Trigger |
| `view-watchlist.json` | View Watchlist | Webhook (GET) |
| `update-status.json` | Update Watchlist Status | Webhook (GET) |
| `delete-row.json` | Delete Watchlist Row | Webhook (GET) |

## Production URLs
n8n itself is reachable at `http://athena:5678` over the tailnet — **not** `localhost` (that only resolves correctly if you're running curl directly on the VPS itself; from a laptop browser it resolves to the laptop, not the VPS).

| Purpose | URL |
|---|---|
| Add something | `http://athena:5678/form/watchlist-add` |
| View the list | `http://athena:5678/webhook/watchlist` |
| Change a status (used by the pills on the view page) | `http://athena:5678/webhook/update-status?id=<id>&status=<status>` |
| Delete a row (used by the 🗑 link on the view page, browser-confirmed via `confirm()` before navigating) | `http://athena:5678/webhook/delete?id=<id>` |

## Importing into n8n
For each file: n8n menu → **Import from File** → select it.

After importing, on **every** Postgres node that uses raw `$1`/`$2`-style placeholders (all of them except **Get Rows**, which has none, and **Insert Row**, which also needs one):
1. Open it and pick your real `Postgres - watchlist` credential from the dropdown (the JSON ships with a placeholder `"id": "REPLACE_ME"` that doesn't resolve to anything real).
2. **Confirmed field location on this instance (n8n 2.38.1, Postgres node v2.5):** the parameter field is not shown by default. Click **Add Option** below the Query box → select **Query Parameters** (internal name `queryReplacement`) → the field appears. Paste in the comma-separated `{{ }}` expressions (see each node below) — without doing this, every `$1`/`$2` reference fails with `there is no parameter $1` (or `$2`, etc.), since zero values are actually bound.

| Node | Query | Query Parameters |
|---|---|---|
| Insert Row | `INSERT INTO to_watch (title, kind, notes) VALUES ($1, $2, $3);` | `{{ $json.Title }},{{ $json.Type.toLowerCase() }},{{ $json.Notes }}` |
| Update Row | `UPDATE to_watch SET status = $1 WHERE id = $2;` | `{{ $json.query.status }},{{ $json.query.id }}` |
| Delete Row | `DELETE FROM to_watch WHERE id = $1;` | `{{ $json.query.id }}` |

This is genuine parameter binding (confirmed via the Postgres node's own source — values are sent to Postgres separately from the query text), so **do not** wrap placeholders in quotes in the query text (`status = '$1'` is wrong and would literally set the column to the four-character string `$1`) — Postgres handles quoting/escaping automatically once a value is actually bound.

Then **Activate** all four workflows (each toggles independently, unlike the merged single-workflow version).

## Schema reference
```sql
CREATE TABLE to_watch (
  id serial PRIMARY KEY,
  title text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('book','movie','tv show')),
  status text NOT NULL DEFAULT 'to watch' CHECK (status IN ('to watch','watching','done')),
  notes text,
  added_at timestamptz NOT NULL DEFAULT now()
);
```
