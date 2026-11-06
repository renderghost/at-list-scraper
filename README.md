# at-list-scraper

Exports every member of a set of Bluesky lists to `accounts.csv`.

Plain Ruby (2.6+, standard library only): no gems, no Bundler, no login.

## Use

1. Put your list URLs in `lists.md`, one per line.
2. Run:

   ```bash
   ruby scrape.rb
   ```

`ruby scrape.rb --help` prints the file format and exit codes.

## `lists.md`

One list per line. Any Bluesky-compatible client works (mu.social, bsky.app, …);
only the owner and list ID in the URL are used.

```markdown
# Headings and blank lines are ignored
https://mu.social/profile/aendra.com/lists/3kmsxmhakdw27
- https://bsky.app/profile/did:plc:kkf4naxqmweop7dv4l2iqqf5/lists/3kmsxmhakdw27
at://aendra.com/app.bsky.graph.list/3kmsxmhakdw27
```

The parser is strict. A leading bullet, `` `backticks` ``, `<angle brackets>` or
`[text](url)` are fine. Any other line is reported with its line number and the
reason (for example: feed URL, profile URL, bad handle, missing list ID). The
valid lists still run.

The same list given twice (even once by handle and once by DID) is scraped once.

## `accounts.csv`

| column        | example                                               |
| ------------- | ----------------------------------------------------- |
| `did`         | `did:plc:5u54z2qgkq43dh2nzwzdbbhb`                    |
| `alias`       | `at://financialtimes.com`                             |
| `handle`      | `@financialtimes.com`                                 |
| `displayName` | `Financial Times`                                     |
| `description` | `The best of FT journalism, …`                        |
| `profileUrl`  | `https://mu.social/profile/did:plc:5u54z2qgkq43dh2nzwzdbbhb` |

How rows are written:

- **Append-only, deduplicated by DID.** Each run adds only accounts whose DID is
  not already in the file. Existing rows are never changed. An account on
  several lists is saved once. To refresh everything, delete the file and re-run.
- **One account per line.** Line breaks and control characters in names and
  bios become a single space.
- **Accounts with a broken handle.** Bluesky reports these as `handle.invalid`.
  They keep `@handle.invalid` in `handle`, and `alias` falls back to `at://<did>`
  so it still resolves.
- **`profileUrl` uses the DID,** so the link survives handle changes.
- **Safe to interrupt.** Each list is saved as soon as it has been fully
  fetched, so Ctrl-C or a failure loses at most the list in progress. Re-running
  skips what's already saved.

**Excel warning:** cells starting with `@` (the `handle` column) can be read as
formulas when you double-click to open the file. Import it via *Data → From
Text/CSV* and set the columns to Text. Numbers and Google Sheets are fine.

## Errors and exit codes

Problems with a single list are reported and skipped: list not found, owner
handle doesn't resolve, the API keeps failing. Network errors, timeouts, `429`
and `5xx` responses are retried with backoff (4 attempts) before giving up. The
summary at the end lists every problem by its `lists.md` line.

| code  | meaning                                                                     |
| ----- | --------------------------------------------------------------------------- |
| `0`   | every list scraped                                                          |
| `1`   | finished, but some lines or lists failed                                    |
| `2`   | stopped early: missing `lists.md`, unreadable `accounts.csv`, offline, rate-limited |
| `130` | interrupted (finished lists are kept)                                       |

## Settings

- `BSKY_APPVIEW`: the API host (default `https://public.api.bsky.app`).
- `NO_COLOR`: set it to turn off coloured output.
- `HTTPS_PROXY` and `NO_PROXY` are respected.
