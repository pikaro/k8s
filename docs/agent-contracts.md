# Agent Contract Notes

`.codex/contracts/main.md` contains durable repo-specific behavior and
governance rules for agents. It is appended to `AGENTS.md`-style instruction
context by the local tooling.

Only change this file after the user has expressly clarified that a general
rule should be added or updated. Do not add task-specific implementation notes,
current-work decisions, temporary plans, or one-off troubleshooting details.

Good contract entries describe patterns that should apply across many future
tasks, such as where derived configuration belongs or which layer owns a class
of resources.
