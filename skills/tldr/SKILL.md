---
name: tldr
description: Condense long documents into a concise TL;DR for sharing. Acts as a critical first reader — surfaces observations, asks only what's genuinely unclear, then creates a focused summary using the Pyramid Principle (bottom line first).
version: 1.0.0
allowed-tools: Read, Write, Bash
argument-hint: "[file path or paste content]"
---

# TL;DR — Document Condenser

**Purpose**: Transform a lengthy document into a concise, reader-first summary. The reader gets the bottom line immediately; the full document is there only for those who want the reasoning, evidence, and detail.

**Core principle**: You are a critical first reader — not a summariser. Read the document cold, surface honest observations, ask only what you genuinely cannot determine from the content, then produce a structured summary using the Pyramid Principle (bottom line first, then key points, then document map).

---

## Execution Flow

### 1. Get the Document

If the user ran `/tldr [file path]`, read the file. If they pasted content, use it directly. If neither, ask: "Please share the document — paste the content or provide a file path."

### 2. Read and Identify Doc Type

Read the full document. Identify the type from the content:

| Type | Signals |
|------|---------|
| RFC / Architecture Decision | Technical proposal, alternatives considered, author/reviewer/approver fields, tradeoffs |
| Vision | Aspirational language, long time horizons, "north star", "where we're headed" |
| Strategy | Priorities, bets, trade-offs, objectives, timeframes, what we will/won't do |
| Product doc (PRD/spec) | User stories, requirements, acceptance criteria, scope, non-goals |
| Market research | Competitive analysis, data, findings, methodology, customer insight |
| Go-to-market | Launch date, positioning, channels, pricing, messaging, segments |

If the type is genuinely ambiguous between two candidates, ask one question with two options. If it's reasonably clear from the content, proceed without asking.

### 3. Surface Observations (Critical Read)

Read as a first-time recipient who's just been handed this document cold. Look for:

- **No clear ask**: Is it obvious what you're asking the reader to do or decide?
- **Competing asks**: Does the document pull in multiple directions, leaving the reader unsure what matters most?
- **Audience mismatch**: Is the depth and language appropriate for who will actually read this?
- **Unresolved questions**: Are there open issues, TBDs, or "we need to decide" statements buried in the content?
- **Assumptions as facts**: Are conclusions presented without supporting evidence?
- **Disproportionate length**: Does the length feel proportionate to what's being communicated, or is there significant AI-generated padding?
- **Completeness sections**: Are there sections that appear to exist because they were expected, not because they add reader value?

Be specific — cite the actual issue, not a generic concern.

If you found observations worth surfacing, present them like this:

```
Before I create the summary, here's what I noticed as a first-time reader:

**[Issue]**: [What the problem is and why it matters to the reader]
**[Issue]**: [...]

These may make the document harder to land. I can help address any of them before creating the summary, or I can proceed as-is — just let me know.
```

If you found nothing significant, skip this step and move straight to step 4.

### 4. Ask Only What You Genuinely Cannot Determine

Consider whether there are things that would make the summary sharper but that the document doesn't clearly answer. Only ask about genuine gaps — never ask something the document already answers.

Questions to consider by doc type (raise only if unclear):

**RFC / Architecture Decision**
- What decision needs to be made? (if not explicitly stated)
- Who has authority to approve or reject? (if not stated)
- Is there a decision deadline? (if time-sensitive but unstated)

**Vision**
- What does success look like concretely? (if the doc is aspirational without tangible outcomes)
- What's the time horizon? (if unstated)

**Strategy**
- What should people prioritise differently or stop doing? (if trade-offs aren't explicit)
- What's the single biggest risk to this working? (if not addressed)

**Product doc (PRD/spec)**
- What's explicitly out of scope? (if not stated — often the most important clarifier)
- What does the reader need to decide or approve? (if the doc is passive/informational)

**Market research**
- What should change in how we operate based on this? (if findings are presented without implications)
- Are there conclusions you're less confident in? (if all findings are presented with equal certainty)

**Go-to-market**
- Who needs to act differently as a result of reading this? (if not clear)
- What's the key launch date or milestone? (if not stated)

Ask the minimum. If you can write a sharp summary without asking anything, do so.

### 5. Ask Format Preference

Ask: "Would you like me to (1) add a TL;DR section to the top of your document, or (2) create a separate one-pager companion file?"

This is the one question always worth asking — it's a preference that can't be inferred from the document.

### 6. Generate the Output

Use the user's answers together with your own reading to generate the output. Follow the Pyramid Principle: bottom line first, key points second, document map third.

---

**Format A — Header section (prepend to existing document)**

Add this at the very top of the document, above the existing title:

```markdown
---

## TL;DR

> **What**: [1-sentence description of what this document is] | **For**: [intended audience] | **Ask**: [what you need from the reader — or "For awareness" if no action required]

**Bottom line**: [2–3 sentences. Lead with the conclusion or recommendation. Not "this document covers..." — the actual point, stated plainly.]

**Key points**
- [A complete insight with its implication — not a topic. E.g. "Our current architecture adds 3 weeks to every release, which means we'll miss the Q3 window unless we act now." Not: "Architecture concerns."]
- [...]
- [Maximum 5 bullets. If you can't fit it in 5, the document has too many main points.]

**What's in this document**
- [Section name] — [1-sentence description of what it covers and why it's there]
- [...]

---
```

The original document follows, unchanged.

---

**Format B — Companion one-pager (separate file)**

Create a file named `{original-filename}-BRIEF.md` in the same directory (or `BRIEF.md` if no filename is available). Write to it:

```markdown
# [Document Title] — Brief

> [1-sentence: what this is, for whom, and what it asks of the reader]

## Bottom Line

[2–3 sentences. Recommendation or conclusion first. Why it matters. What happens if we don't act or decide.]

## Key Points

[4–6 bullets. Each is a complete insight — the point AND its implication. Mutually exclusive, no overlap, no gaps.]

- [...]
- [...]

## Supporting Context

[2–3 bullets of secondary evidence or context. Not required reading — here for those who want more before diving in.]

## What's in the Full Document

- [Section] — [what it covers]
- [...]

→ Full document: [filename or link if known]
```

Target: 300–400 words. If you're over, you're not compressing enough.

---

## Critical Rules

- **Lead with the conclusion, not the journey.** The reader doesn't care how you got there — they care what it means for them.
- **Each key point must be an insight, not a topic.** "Pricing" is a topic. "Our pricing is 40% above competitors without a clear differentiation story, which is slowing enterprise deals" is an insight.
- **Only ask what you genuinely cannot determine from the document.** If the document is clear, produce the summary without interrupting.
- **Surface observations honestly.** If the document has a problem, name it specifically. Softening it to the point of vagueness helps no one.
- **Never pad the TL;DR.** If there are 3 key points, list 3. Don't invent more to fill space.
- **The summary is baked from intent, not just content.** What the author is trying to achieve matters more than what they wrote. If you asked questions in step 4, use those answers — they reveal intent that the document itself may have buried.
