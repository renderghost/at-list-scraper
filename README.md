# at-list-scraper

Exports every member of a set of Bluesky lists to `accounts.csv`.

Plain Ruby (2.6+, standard library only): no gems, no Bundler, no login.

## Use

1. Put your list URLs in `lists.md`, one per line.
2. Check `hosts.txt` (see below). It ships ready to use.
3. Run:

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
| `verified`    | `TRUE`                                                |
| `verifiedBy`  | `bsky.app` (several joined with ` \| `)               |
| `customDomain`| `TRUE`                                                |
| `profileUrl`  | `https://mu.social/profile/did:plc:5u54z2qgkq43dh2nzwzdbbhb` |

The three trust columns, for picking out real organisations:

- **`verified`** is `TRUE` only if the account has a valid Bluesky verification
  right now. A verification lapses when the account changes its handle or display
  name; a lapsed one counts as `FALSE`.
- **`verifiedBy`** says who verified it. Most say `bsky.app`. A newsroom can
  also be a verifier, so the FT verifying `@data.ft.com` shows as
  `financialtimes.com`. It is empty when `verified` is `FALSE`.
- **`customDomain`** is `TRUE` when the handle is not under a domain listed in
  `hosts.txt`. So `@financialtimes.com` and `@alphaville.ft.com` are `TRUE`, and
  `@someone.bsky.social`, `@afp.wsocial.eu` and Mastodon bridges are `FALSE`.

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

## `hosts.txt`

These are the domains that give handles to unrelated people: Bluesky's own
`bsky.social`, bridges (`brid.gy`), independent hosts (`eurosky.social`,
`blacksky.app`, …), fan and interest handle services, and free website
platforms (`substack.com`, `github.io`, …). Edit it freely: one domain per line,
with `#` for comments. A bad line stops the run before anything is written, so a
typo can't quietly fill `accounts.csv` with wrong values.

The first version was built from a sample of 18,825 accounts. The count next to
each entry is how many sampled accounts used it. There's no official
directory, so add hosts as you spot them. Changes only affect accounts added
after the change, because existing rows are never rewritten.

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
| `2`   | stopped early: missing or broken `lists.md`/`hosts.txt`, unreadable `accounts.csv`, offline, rate-limited |
| `130` | interrupted (finished lists are kept)                                       |

## Settings

- `BSKY_APPVIEW`: the API host (default `https://public.api.bsky.app`).
- `NO_COLOR`: set it to turn off coloured output.
- `HTTPS_PROXY` and `NO_PROXY` are respected.
