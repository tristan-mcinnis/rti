# RTI RAG Benchmark Questions

These questions represent the daily-driver vault interface RTI should support.
They are intentionally phrased like a user would ask during work, not like a
database query.

## Core Daily-Driver Questions

1. **Acme project map**
   - Query: "Tell me about the Acme projects I have done this year."
   - Expected retrieval: project status files, project summaries, recent RTI/vault chat logs.
   - Must not require a project to be pre-selected.

2. **AcmeWear city comparison**
   - Query: "What is the difference between mass consumers in Northport and Southvale for the AcmeWear project?"
   - Expected retrieval: AcmeWear transcripts, evidence deck, language bank, city-difference notes.
   - Expected answer: comparison by awareness, localisation, retail expectations, Acme visibility, product norms.

3. **Latest project point**
   - Query: "Answer the latest client question using the current project."
   - Expected retrieval: recent transcript window first, then project-scoped vault search if needed.

4. **Discussion guide lookup**
   - Query: "@wear dg"
   - Expected retrieval: an AcmeWear discussion-guide style file, not generic RTI session discussion guides.

5. **Evidence/source audit**
   - Query: "What sources did you use for that?"
   - Expected retrieval/display: source popover shows typed source rows and timing, not a large inline debug block.

6. **Recent work**
   - Query: "What did we discuss most recently on this project?"
   - Expected retrieval: recent project meetings/sessions before semantic search.

## Automated Coverage

Current automated checks cover:

- multi-token `@` matching, including abbreviation (`wear dg`);
- scoped `@` search before global fallback;
- large `@` candidate set responsiveness;
- vault search tokenisation and ranking;
- workstream matching from meeting names.

Manual/live-call checks still required:

- real Zoom/Teams/Meet audio/transcript latency;
- provider first-token latency;
- answer quality against real vault documents.
