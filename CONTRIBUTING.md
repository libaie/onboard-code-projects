# Contributing

Open an issue before changing the public workflow or state contract. Do not include secrets, repository contents, private paths, task messages, or unsanitized tool output.

Keep changes Windows PowerShell 5.1 compatible, dependency-free, fail-closed at identity and filesystem boundaries, and limited to the smallest runnable check. Run the complete suite in [README.md](./README.md#verification) before submitting a pull request; CI also runs package preflight and the clean-archive release gate.

Real Codex Desktop evidence must use disposable projects, fictional repository names, and sanitized identifiers. Design scratch files under `docs/superpowers/`, controller state, receipts, generated memory, and local codebase indexes are development artifacts and must not enter a public commit.

Report suspected vulnerabilities according to [SECURITY.md](./SECURITY.md). A pull request must not create tags, release artifacts, or external state.
