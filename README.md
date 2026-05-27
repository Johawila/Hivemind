# Hivemind

A macOS menu bar app that manages a structured [Notion](https://notion.so) workspace — daily pages, task tracking, calendar, AI-powered weekly reviews, and a knowledge graph. Built for someone working across engineering management and an ongoing path to CTO.

No dock icon. Runs quietly in the background, ticking every 15 minutes.

---

## What it does

**Daily pages** — Creates a fresh Notion page each morning with a consistent structure: active projects, the day's focus (MIT), your calendar schedule, rolled-over tasks from yesterday, a notes section, a curated quote, and a rotating reflection question. Yesterday's page is archived automatically.

**Calendar** — Reads any ICS feed (Outlook `webcal://` works) and renders today's events in the daily page. Past events appear strikethrough. Refreshes every 15 minutes.

**Task & note capture** — Works in tandem with [Noted](#integration-with-noted): quick-capture from any app lands in today's page and the Notion databases.

**Weekly AI review** — Every Monday, Hivemind pulls the previous week's pages, extracts your MIT completions, meetings, tasks, and reflection answers, then sends them to Claude Sonnet for analysis. The review surfaces wins, blockers, and a suggested focus for the coming week. Previous focus is fed back in to maintain continuity.

**AI note linking (Zettelkasten)** — When Noted saves a note, Hivemind scans all existing notes with Claude Haiku and suggests connections. High-confidence links (≥ 0.8) are applied automatically in Notion. Lower-confidence ones surface in a pending links UI for manual review.

**Knowledge graph** — A standalone canvas window showing your notes, tasks, projects, people, and teams as a force-directed graph. Pending AI links appear as dashed orange edges. Clicking any node opens it in Notion.

**Notifications** — Configurable morning nudge ("What's your MIT?") and evening nudge ("Time to reflect"), both linking to today's page.

---

## Notion workspace structure

Hivemind sets up and manages the following, all under one parent page:

| Database / Page | Purpose |
|---|---|
| Projects | Active / On Hold / Completed projects |
| People | Colleagues with team and color assignment |
| Teams | Team groupings |
| Tasks | Daily tasks linked to projects and people |
| Notes | Knowledge base with tags, links, and relations |
| Schedule | ICS-driven calendar entries |
| Weekly Summaries | AI-generated weekly review pages |
| Archive | Completed daily pages |

---

## Setup

1. Build and run in Xcode (macOS 14+, no App Store — sandbox off).
2. On first launch, open Settings from the menu bar icon.
3. Provide a Notion integration token and a parent page ID. Hivemind creates the full workspace structure automatically.
4. Optionally add a calendar ICS URL and configure notification times.

---

## Integration with Noted

Hivemind shares an App Group (`group.johanwilander.hivemind`) with [Noted](../Noted/). Noted reads the Notion API key and database IDs from shared UserDefaults, and fires a `DistributedNotification` after each note save — Hivemind's linking engine picks this up automatically.

---

## Tech

- Swift / SwiftUI + AppKit
- Notion API (REST)
- Anthropic API — Claude Sonnet 4.6 (weekly review), Claude Haiku 4.5 (note linking)
- ICS parsing (no external libraries)
- Canvas-rendered knowledge graph with force-directed physics
