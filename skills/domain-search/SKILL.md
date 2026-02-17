---
name: domain-search
description: Search for available domain names using RDAP/WHOIS checks and intelligent name generation. Use when someone needs to find or check domain availability, brainstorm domain names, or register domains.
version: 1.0.0
---

# Domain Search Skill

**Skill Name**: domain-search
**Auto-Trigger**: When agent detects domain name searching or availability checking tasks
**Purpose**: Find available domain names using real RDAP/WHOIS verification, pattern generation, and brainstorming

---

## Tools

This skill uses two complementary tools:

| Tool | Purpose | How |
|------|---------|-----|
| **domain-check CLI** | Availability verification via RDAP/WHOIS | Bash: `domain-check ... --json --yes` |
| **Instant Domain Search API** | Name variations and registration links | Bash: `curl` to MCP endpoint (see below) |

**`domain-check`** is the primary tool. It's a Rust CLI installed at `/opt/homebrew/bin/domain-check` that queries authoritative RDAP endpoints with WHOIS fallback. Fast, local, no API key needed.

**Instant Domain Search** is a free remote API (no auth required) that provides:
- `generate_domain_variations` - AI-generated name alternatives with prefixes/suffixes
- `search_domains` - fast availability check with registration links
- `check_domain_availability` - DNS-based availability verification

Access it via JSON-RPC over HTTP (MCP streamable HTTP protocol):
```bash
curl -s -X POST "https://instantdomainsearch.com/mcp/streamable-http" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"TOOL_NAME","arguments":{...}}}'
```

> **Note**: This API does NOT return pricing. It returns `buy_url` links to registration pages where prices are shown.

---

## Core Workflow

### Step 1: Understand the Requirements

Before searching, clarify:
- **Project/brand concept** - What is this domain for?
- **Preferred TLDs** - Default to `--preset startup` (com, org, io, ai, tech, app, dev, xyz)
- **Constraints** - Max length, must include specific word, avoid hyphens, etc.
- **Budget** - Standard registration vs premium/aftermarket domains

### Step 2: Generate Candidate Names

Use a combination of brainstorming and `domain-check` pattern generation.

**Brainstorming heuristics** (generate 10-20 candidates):
- Compound words (e.g., "mailchimp", "dropbox", "airbnb")
- Verb+noun (e.g., "sendgrid", "pushover", "gocraft")
- Prefix plays: get-, go-, try-, use-, my-, hey-, hi-
- Suffix plays: -ify, -ly, -io, -hub, -lab, -kit, -base, -flow, -nest
- Portmanteaus: blend two relevant words
- Metaphors: abstract concepts related to the domain's purpose
- Keep names **short** (<12 chars), **pronounceable**, **spellable**, and **memorable**

**Pattern generation** with `domain-check`:
```bash
# Prefix variations
domain-check myproject --prefix get,try,use,go --tld com,io,ai --json --yes

# Suffix variations
domain-check myproject --suffix hub,app,lab,kit,flow --tld com --json --yes

# Pattern matching (\w=letter, \d=digit, ?=either)
domain-check "code\w\w\w" --tld com --json --yes --dry-run  # Preview first
```

### Step 3: Check Availability

Run `domain-check` with JSON output for structured results:

```bash
# Single domain across startup TLDs
domain-check myproject --preset startup --json --yes -c 5

# Multiple specific domains
domain-check coolname brandname fastapp --tld com,io,ai --json --yes -c 5

# With detailed info (WHOIS/RDAP data for taken domains)
domain-check myproject --preset startup --json --yes -i -c 5

# Bulk from file (one domain per line)
domain-check --file candidates.txt --tld com --json --yes -c 5
```

**Output format** (JSON):
```json
[
  {
    "domain": "myproject.dev",
    "available": true,
    "check_duration": {"secs": 0, "nanos": 524499583},
    "method_used": "rdap"
  }
]
```

**Rate limiting warning**: Google registries (.app, .dev) rate-limit at default concurrency. For batches that include these TLDs, use **`-c 5`** to avoid null results:
```bash
# GOOD: lower concurrency for .app/.dev
domain-check name1 name2 name3 --tld com,io,app,dev --json --yes -c 5

# BAD: default concurrency (-c 20) causes rate limiting on .app/.dev
domain-check name1 name2 ... name20 --preset startup --json --yes
```

When rate-limited, results return `"available": null`. There is also a known bug where the `domain` field shows the first domain in the batch rather than the actual rate-limited domain. Lower concurrency eliminates both issues.

### Step 4: Get Variations and Registration Links

Use Instant Domain Search API for AI-generated name variations and direct registration links:

```bash
# Generate name variations (returns .com alternatives with buy_url links)
curl -s -X POST "https://instantdomainsearch.com/mcp/streamable-http" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"generate_domain_variations","arguments":{"name":"myproject","limit":10}}}'

# Search domains across TLDs (returns availability + buy_url links)
curl -s -X POST "https://instantdomainsearch.com/mcp/streamable-http" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_domains","arguments":{"name":"myproject","tlds":["com","io","ai"]}}}'
```

**Response fields** (inside `result.content[0].text`, JSON-encoded):
- `isRegistered`: true/false
- `label`: domain name without TLD
- `tld`: the TLD
- `words`: word decomposition (e.g., `["solar", "paws"]`)
- `buy_url`: direct registration link (e.g., `https://instantdomainsearch.com/get/domain.com?src=mcp`)
- `rank`: relevance score (1.0 = best)

**Available tools**:
| Tool | Parameters | Purpose |
|------|-----------|---------|
| `search_domains` | `name` (required), `tlds` (optional array), `limit` (optional, max 100) | Search availability across TLDs |
| `generate_domain_variations` | `name` (required), `limit` (optional, max 100), `sort` (optional: "rank" or "distance") | AI-generated prefix/suffix/compound variations |
| `check_domain_availability` | `domains` (required array of full domains like `["example.com"]`) | DNS-based availability check for specific domains |

> **Note**: The API does not return prices. Present `buy_url` links so the user can see pricing on the registration page.

### Step 5: Present Results

Organize results as a clear table:

```markdown
| Domain | Available | Register | Notes |
|--------|-----------|----------|-------|
| coolname.com | Yes | [Register](https://instantdomainsearch.com/get/coolname.com?src=mcp) | Short, memorable |
| coolname.io | Yes | [Register](https://instantdomainsearch.com/get/coolname.io?src=mcp) | Tech-friendly TLD |
| coolname.ai | No | - | Taken |
```

Include:
- Available domains sorted by recommendation strength
- Brief rationale for top picks (brandability, length, memorability)
- Registration links (use `https://instantdomainsearch.com/get/DOMAIN?src=mcp` format)
- Alternative suggestions if primary choices are taken

---

## Command Reference

### domain-check CLI

| Flag | Purpose | Example |
|------|---------|---------|
| `--tld` | Specific TLDs (comma-separated) | `--tld com,io,ai` |
| `--preset` | TLD presets | `--preset startup` (com,org,io,ai,tech,app,dev,xyz) |
| `--all` | Check all known TLDs | `--all` |
| `--prefix` | Prepend strings | `--prefix get,try,use` |
| `--suffix` | Append strings | `--suffix hub,app,lab` |
| `--pattern` | Generate names (\w=letter, \d=digit) | `--pattern "code\w\w\w"` |
| `--json` | JSON output | Always use for structured results |
| `--csv` | CSV output | For spreadsheet export |
| `-i` | Detailed RDAP/WHOIS info | Shows registrar, dates for taken domains |
| `-y` / `--yes` | Skip confirmation prompts | Always use in automation |
| `--dry-run` | Preview generated domains | Use before large pattern checks |
| `-c` | Concurrency (default 20, max 100) | `-c 5` recommended to avoid rate limiting |
| `-f` | Input file | `-f domains.txt` |
| `--force` | Override 500-domain limit | For very large bulk operations |

### Presets

| Preset | TLDs |
|--------|------|
| `startup` | com, org, io, ai, tech, app, dev, xyz |
| `enterprise` | com, org, net, info, biz, us |
| `country` | us, uk, de, fr, ca, au, br, in, nl |

---

## Common Patterns

### Pattern 1: "I need a domain for my new project"

```
1. Ask about the project (purpose, audience, vibe)
2. Brainstorm 15-20 candidate names
3. Check all candidates: domain-check name1 name2 ... --preset startup --json --yes -c 5
4. Get variations via Instant Domain Search API for top candidates
5. Present ranked recommendations with registration links
```

### Pattern 2: "Is example.com available?"

```
1. Quick check: domain-check example --tld com --json --yes
2. If taken, show alternatives: domain-check example --preset startup --json --yes
3. If all taken, generate variations: domain-check example --prefix get,try --suffix hub,app --tld com --json --yes
```

### Pattern 3: "Find me a short .com domain"

```
1. Pattern generation: domain-check --pattern "\w\w\w\w\w" --tld com --json --yes --dry-run
2. Review generated names, filter interesting ones
3. Check availability for filtered set
4. Present available options
```

### Pattern 4: "Bulk check a list of domains"

```
1. Write candidates to temp file (one per line)
2. domain-check --file /tmp/domains.txt --tld com,io --json --yes
3. Parse JSON results, separate available vs taken
4. Present summary table
```

---

## Tips

- **Always use `--json --yes`** for automation-friendly output
- **Always use `-c 5`** to avoid rate limiting from Google registries (.app, .dev)
- **Use `--dry-run`** before large pattern generations to preview what will be checked
- **Start with `--preset startup`** unless the user has specific TLD preferences
- **Check .com first** - it's still the most valuable TLD for most use cases
- **Combine prefix+suffix** with base names for maximum coverage
- **Use `generate_domain_variations`** from Instant Domain Search when the user's first choices are taken - it produces creative alternatives
- Domain names with hyphens are generally less desirable (harder to communicate verbally)
- Two-word compound domains (.com) under 10 characters are gold
- .io and .ai are premium-priced but signal tech/AI projects

---

## Limitations

- **No pricing data**: Neither tool returns registration prices. Provide `buy_url` links so users can see pricing on the registration page.
- **Rate limiting**: Google registries (.app, .dev) rate-limit concurrent RDAP requests. Use `-c 5` to avoid. When rate-limited, `domain-check` returns `"available": null` and incorrectly attributes the failure to the first domain in the batch (known upstream bug).
- Some TLDs may not have RDAP endpoints (WHOIS fallback used automatically)
- Results reflect real-time registry status - domains can be registered by others at any time
- Premium and aftermarket domains may show as "available" but have higher prices
- Instant Domain Search `generate_domain_variations` only returns `.com` variations
