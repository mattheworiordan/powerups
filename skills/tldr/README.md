# TL;DR — Document Condenser

Condense long AI-generated documents into a concise, reader-first summary. Acts as a critical first reader: surfaces issues, asks only what's genuinely unclear, then produces a focused TL;DR using the Pyramid Principle (bottom line first).

## The Problem This Solves

AI generates thorough documents at near-zero cost. Reading them costs enormous attention. The asymmetry creates a burden on every person you share your work with.

This skill flips the structure: conclusion first, key points second, full document available for those who want the reasoning. The reader gets what they need in 30 seconds; the depth is there if they want it.

## When to Use It

At the point of sharing — when you've done the research or planning work and you're about to send a document to someone. Not during generation; after.

Good candidates:
- Strategy docs, vision docs, RFCs, proposals
- Research reports, competitive analyses
- PRDs, specs, go-to-market plans
- Any AI-generated document that's longer than one page

## Usage

```
/tldr path/to/document.md
```

Or just run `/tldr` and paste the content when asked.

## What Happens

1. **Reads the document** and identifies the type (RFC, vision, strategy, product, research, GTM)
2. **Surfaces observations** — flags things that may make the document harder to land (no clear ask, unresolved questions, audience mismatch, AI padding, etc.)
3. **Asks only genuine gaps** — if the document is clear, it proceeds without questions; if something important is missing or ambiguous, it asks the minimum needed
4. **Asks your format preference** — header section or companion one-pager
5. **Generates the summary** using the Pyramid Principle

## Output Formats

**Format A — Header section**
Prepends a TL;DR block to the top of your existing document. Includes: what/for/ask metadata, bottom line (2–3 sentences, conclusion first), key points (max 5 complete insights), and a section map.

**Format B — Companion one-pager**
Creates a separate `{filename}-BRIEF.md` file (~300–400 words) using the Pyramid Principle structure. Standalone — can be shared without the original document.

## What Makes a Good Key Point

The skill is explicit about this: a key point is an insight, not a topic.

- ❌ "Pricing concerns"
- ✅ "Our pricing is 40% above competitors without a clear differentiation story, which is slowing enterprise deals"

If the reader can't act on or react to the bullet, it's a topic. Make it an insight.

## Installation

```bash
# Via Agent Skills (Claude Code, Codex, Gemini CLI, Cursor, and more)
npx skills add mattheworiordan/powerups --skill tldr

# Or install all powerups skills at once
npx skills add mattheworiordan/powerups
```
