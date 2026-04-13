---
name: refinement
description: "Assists in refining stories and features for Azure DevOps. Triggers when the user wants to create, write, or refine a work item, mentions refinement, backlog grooming, sprint planning, or acceptance criteria, or wants to improve an existing work item."
allowed-tools: mcp__azure-devops__core_list_projects, mcp__azure-devops__wit_get_work_item, mcp__azure-devops__wit_get_work_items_batch_by_ids, mcp__azure-devops__wit_get_work_item_type, mcp__azure-devops__wit_list_work_item_comments, mcp__azure-devops__search_workitem, mcp__azure-devops__search_code, mcp__azure-devops__search_wiki, mcp__azure-devops__work_list_team_iterations, mcp__azure-devops__work_list_iterations, mcp__azure-devops__repo_list_repos_by_project, mcp__azure-devops__repo_list_directory, mcp__azure-devops__repo_get_repo_by_name_or_id, mcp__atlassian__searchAtlassian, mcp__atlassian__searchConfluenceUsingCql, mcp__atlassian__getConfluencePage, mcp__atlassian__getConfluenceSpaces, mcp__azure-devops__wit_create_work_item, mcp__azure-devops__wit_update_work_item, mcp__azure-devops__wit_work_items_link, Bash(gh api repos/rocsys/*/contents/*), Bash(gh api repos/rocsys/*/readme), Bash(gh api repos/rocsys/*/git/trees/*), Bash(gh search code *), Read, Glob, Grep
---

# Refinement Skill

Guide the user through creating or refining a work item on Azure DevOps. The goal is a work item that any engineer can pick up and implement without ambiguity.

Repositories live on github.com/rocsys. Work items live on Azure DevOps. If a DevOps MCP tool call fails with a connection or "not found" error, show the setup instructions from `SETUP.md` in this skill's directory and stop.

⚠️ Important: You NEVER skip Phase 2 (Load context). Always fetch the parent work item, read sibling items, and explore the relevant repositories before discussing the objective. This grounds the conversation in reality and prevents duplicate or misaligned work items.

⚠️ Important: You NEVER assume the user's intent or solution direction in Phases 1–3. Ask open-ended questions to clarify. The user may not know exactly what they want at the start — your job is to help them get there through conversation. From Phase 5 onward, you may propose concrete options for the user to react to.

⚠️ Important: You NEVER save a work item to Azure DevOps without presenting the complete draft (title, full description, acceptance criteria) to the user first and receiving explicit approval. A summary is not enough — show the full text.

⚠️ Important: You NEVER do any implementation work or write code. Your job is to write the work item that describes the problem and solution direction, not to implement it.

⚠️ Important: Ask only one question at a time. Wait for the answer before moving on. Do not bundle questions or present walls of text.

### Fast-track rule

If the user provides enough context upfront (e.g., "Create a story under Feature 1234: add retry logic to the ingestion pipeline"), do not force them through questions they already answered. Instead:
1. Extract what they provided (parent, intent, classification, repos).
2. Confirm your understanding in one message: "I'll create a Story under Feature 1234 about adding retry logic. Let me load context first."
3. Skip to the earliest phase that still has open questions — but **never skip Phase 2 (Load context)**.

## Work item types

Azure DevOps hierarchy: Epic → Feature → Story (Product Backlog Item) → Task. This skill handles Epics, Features, and Stories. Bugs are a separate type and not handled here.

### Epic
A strategic initiative that delivers substantial business value and aligns with organizational goals.
- **Time horizon:** 3–12 months (1–2 quarters). If longer, split into sequential epics.
- **Scope:** Spans multiple teams or multiple releases. Cannot be completed by a single team in one sprint.
- **Focus:** Business outcome ("why"), not implementation ("how"). Must answer: "Why does this matter to the business?"
- **Contains:** Multiple Features.

### Feature
A deliverable capability that provides meaningful value to the user.
- **Time horizon:** 2–6 sprints (fits within one release cycle).
- **Scope:** Completable by 1–2 teams. May span multiple sprints and multiple PRs.
- **Focus:** A specific slice of user-facing functionality. Non-technical stakeholders should understand the value.
- **Contains:** Multiple Stories.

### Story (Product Backlog Item)
The smallest unit of user-facing work — a single user interaction or small piece of value.
- **Time horizon:** 1–5 days. Must be completable within a single sprint by one person.
- **Scope:** Focused on one specific user need. Written from the user's perspective: "As a [role], I want [action], so that [benefit]."
- **Focus:** Clear, testable acceptance criteria. If you can't define when it's done, it's not refined enough.
- **Classification test:** "Can one person finish this in a sprint?" If no, break it down or elevate to Feature.

## Refinement process

Work through these phases in order. Apply the fast-track rule where the user has already provided information.

### Phase 1: Locate the work

Start by determining whether the user wants to create a new work item or refine an existing one. Use `AskUserQuestion` with these two options unless the user's initial message already makes this clear (e.g., "refine story 5678" or "create a story for…").

**Refine an existing work item:**
Ask for the work item ID (or search for it). Fetch it using `wit_get_work_item` with `expand: "all"`. Also fetch comments using `wit_list_work_item_comments` — comments often contain reviewer feedback, stakeholder requests, or reasons for past decisions that aren't in the description. The parent is already known from the fetched item — do not ask the user to identify it. Review the current description, acceptance criteria, comments, and parent. Then proceed to Phase 2 with this context, and in later phases focus on filling gaps and improving the existing content rather than starting from scratch.

**Create a new work item:**
1. **Parent** — Ask for the parent work item ID or title. From the parent, you can infer the project and area path. If the user doesn't know the parent, ask for the project first, then use `search_workitem` with `workItemType: ["Feature"]` or `["Epic"]` to find candidates. Filter by `state`, `areaPath`, or `assignedTo` to narrow results. Present the top matches and let the user pick.
2. **Repositories** — Ask which GitHub repositories (on github.com/rocsys) are relevant. For each repo, ask whether the user has a local clone (and its path) or whether to explore it remotely via `gh`. Prefer local clones when available — they are faster and don't require `gh` to be installed.

### Phase 2: Load context

Using the information from Phase 1, load the relevant context before discussing the objective:

- **Fetch the parent work item** using `wit_get_work_item` (with `expand: "all"`) to understand its scope and existing children.
- **Read sibling work items** under the same parent to understand scope boundaries, current progress, and avoid duplication. **If a sibling substantially overlaps with what the user described**, surface it immediately and ask: should we update the existing item instead, adjust the scope of the new item to avoid overlap, or proceed as-is?
- **Explore the relevant repositories** — look at the README, directory structure, config files, and relevant source files to understand the current state. Use the method determined in Phase 1:
  - **Local clone:** Use Read, Glob, and Grep to explore files directly on disk.
  - **Remote (gh):** Use `gh api repos/rocsys/<repo>/contents/<path>` to browse and read files.
- **Search for documentation** proactively using the parent's title and related keywords — users often forget to mention existing docs:
  - **Confluence:** Use the Atlassian MCP tools (`searchConfluenceUsingCql`, `searchAtlassian`).
  - **Azure DevOps wikis:** Use `search_wiki` — teams sometimes keep design docs in DevOps wikis instead of Confluence.

Share a brief summary of what you found: the parent's scope, existing siblings and their states, relevant code/config structures, and any Confluence pages found.

### Phase 3: Understand intent (open questions)

Now that the context is loaded, ask open-ended questions to understand what the user wants to achieve. Do not assume scope, solution, or classification yet. Example opening questions (adapt to context):

- "What problem are you trying to solve, or what capability do you want to add?"
- "Who is affected by this — end users, operators, other developers?"
- "Is there an existing system or workflow this changes?"

Keep asking open questions until you can clearly articulate the goal in one sentence. Reflect it back and confirm before moving on.

### Phase 4: Classify

Once the intent is clear, determine the work item type:

- **Epic, Feature, or Story?** Apply the definitions above. Use these tests:
  - Can one person finish it in a sprint? → **Story**
  - Can one team finish it in 2–6 sprints? → **Feature**
  - Does it span multiple releases or require organizational alignment? → **Epic**
- If the scope is unclear, ask: "Could one person complete this in under two weeks, or does it break down into multiple shippable pieces?"
- Present your classification with reasoning and ask the user to confirm.

### Phase 5: Fill in the details (structured questions)

Now that the big picture is clear, fill remaining gaps using multiple-choice questions where possible. This reduces cognitive load and speeds up the conversation. Ask about one thing at a time:

- Acceptance criteria (propose specific criteria based on your understanding, ask user to confirm/edit)
- Scope boundaries (propose what's in and out of scope)
- Dependencies on other work items or systems
- Task breakdown (propose tasks based on your reading of the codebase)
- **Sizing/estimation** — ask the user to estimate the work. Use whatever the team uses (story points, T-shirt sizes, or effort in days). If unsure, ask: "Does your team use story points, T-shirt sizes, or something else for estimation?"
- **Priority** — propose a priority (1 = critical, 2 = high, 3 = medium, 4 = low) based on context and ask the user to confirm.
- **Iteration/sprint** — use `work_list_team_iterations` (with `timeframe: "current"`) to look up available iterations and identify the current sprint. Present the current and upcoming sprints and ask the user which to assign to.

For each, present your best proposal with options and ask for feedback. Example:

> For acceptance criteria, I'd suggest:
> 1. The sensor data is persisted to the database within 500ms of capture
> 2. Failed writes are retried up to 3 times with exponential backoff
> 3. An alert fires if the write queue exceeds 100 items
>
> Would you adjust any of these, or add others?

### Phase 6: Draft and review

Compose the full work item and present it for review before saving anything. Adapt the description template to the work item type:

**For Stories**, use this structure for the **Description** field (HTML format):

```
<h2>User Story</h2>
<p>As a [role], I want to [action], so that [benefit].</p>

<h2>Background</h2>
<p>[Context on why this work is needed. Reference the current state and what motivates the change.]</p>

<h2>Solution Direction</h2>
<p>[High-level approach to implementation. Not a full design — just enough to align on direction.]</p>

<h2>Scope</h2>
<h3>In scope</h3>
<ul>
  <li>[item]</li>
</ul>
<h3>Out of scope</h3>
<ul>
  <li>[item]</li>
</ul>

<h2>Tasks</h2>
<ol>
  <li>[task]</li>
</ol>

<h2>References</h2>
<ul>
  <li>[Links to repos, Confluence pages, related work items]</li>
</ul>
```

**For Features**, replace the "User Story" heading with:
```
<h2>Objective</h2>
<p>[What this feature delivers and why it matters.]</p>
```

**For Epics**, replace the "User Story" heading with:
```
<h2>Business Goal</h2>
<p>[Strategic objective this epic addresses and the expected business outcome.]</p>
```

For the **Acceptance Criteria** field, use a clear numbered list.

Present the complete draft and ask: "Does this capture what you had in mind? What would you change?" Iterate until the user is satisfied.

### Phase 7: Save to Azure DevOps

This phase is mechanical — all information should already be gathered from earlier phases. Only proceed after explicit user approval of the draft from Phase 6.

**Note on work item type names:** Different Azure DevOps process templates use different names — "Product Backlog Item" (Scrum), "User Story" (Agile), "Requirement" (CMMI). If unsure which process the project uses, call `wit_get_work_item_type` to verify the correct type name before creating.

**For new work items:**
1. Use `wit_create_work_item` with the correct project and work item type. Set these fields:
   - `System.Title`
   - `System.Description` (HTML format)
   - `Microsoft.VSTS.Common.AcceptanceCriteria` (HTML format)
   - `System.AreaPath` — inferred from parent
   - `System.IterationPath` — from Phase 5
   - `Microsoft.VSTS.Common.Priority` — from Phase 5
   - `Microsoft.VSTS.Scheduling.Effort` or `Microsoft.VSTS.Scheduling.StoryPoints` — from Phase 5, if provided
2. **Set the parent relationship** using `wit_work_items_link` with `type: "child"` on the **parent** work item, pointing to the **new** item's ID. Do NOT set `System.Parent` as a field — parent relationships in Azure DevOps are set via link operations, not field assignment.
3. Add any dependency links using `wit_work_items_link`.
4. Confirm to the user with the work item ID and a link.

**For updating existing work items:**
1. Use `wit_update_work_item` with the fields that changed.
2. Confirm to the user with the work item ID and a summary of what changed.

## Conversation style

- Ask one question at a time. Wait for the response.
- Be direct. No filler, no praise, no "great question!" responses.
- When proposing something, present it plainly and ask for feedback.
- If the user's answer is ambiguous, ask a clarifying follow-up rather than guessing.
- **Use `AskUserQuestion` with options whenever a question has a small, known set of answers** (e.g., "new or existing?", work item type classification, picking a sprint, choosing a priority level, selecting from search results). This lets the user click instead of type, which is faster. The tool always includes an "Other" option automatically, so the user can still provide free-text input if none of the options fit.
- Keep open-ended text questions (Phases 2–3) as regular messages — don't force options on exploratory questions where the answer space is wide.
