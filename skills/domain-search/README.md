# Domain Search

**Find available domain names with real RDAP/WHOIS verification and intelligent name generation.**

---

## Why Domain Search?

Searching for domains manually is tedious — check one name, it's taken, try another, repeat. Domain Search automates the entire workflow:

- **Bulk checking** — Check dozens of candidates across multiple TLDs in seconds
- **Pattern generation** — Prefix/suffix combinations, letter patterns, and variations
- **AI-generated alternatives** — When your first choice is taken, get creative suggestions
- **Authoritative results** — Uses RDAP/WHOIS (not DNS guessing) for accurate availability data
- **Registration links** — Direct links to register available domains

---

## Installation

### Agent Skills (any agent)

```bash
npx skills add mattheworiordan/powerups --skill domain-search
```

### Claude Code Plugin

Included with the powerups plugin:

```bash
/plugin marketplace add mattheworiordan/powerups
```

### Prerequisites

- **`domain-check` CLI** — Rust-based RDAP/WHOIS checker. Install via Homebrew: `brew install domain-check`
- **Instant Domain Search API** — Free, no API key needed (used for AI-generated variations)

---

## Usage

```bash
/domain-search              # Start a domain search session
```

The skill guides you through:

1. **Understanding your project** — What's the domain for? Preferred TLDs?
2. **Generating candidates** — Brainstorms 15-20 names using compound words, prefixes, suffixes, portmanteaus
3. **Checking availability** — Bulk RDAP/WHOIS verification across your chosen TLDs
4. **Getting variations** — AI-generated alternatives for taken names
5. **Presenting results** — Ranked table with availability, recommendations, and registration links

### Common Patterns

**"I need a domain for my new project"** — Describe the project, get brainstormed candidates checked across startup TLDs.

**"Is example.com available?"** — Quick check with alternatives if taken.

**"Find me a short .com domain"** — Pattern generation with letter wildcards.

**"Bulk check a list"** — Provide a list, get structured results.

---

## Tools Used

| Tool | Purpose |
|------|---------|
| `domain-check` CLI | Authoritative RDAP/WHOIS availability verification |
| Instant Domain Search API | AI-generated name variations and registration links |

See the [full SKILL.md](./SKILL.md) for detailed command reference, API usage, and rate limiting notes.
