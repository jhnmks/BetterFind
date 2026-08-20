# Cling Search Engine Attribution

Better Find derives `Sources/ClingSearchCore/SearchEngine.swift` from:

- Project: [Cling](https://github.com/FuzzyIdeas/Cling)
- Upstream commit: `e307f37a1b148ec6389999f6d260c1df777440b4`
- Upstream path: `Cling/SearchEngine.swift`
- Original upstream SHA-256: `7301d60fbe7df6472e771f34e67b6622944b068cd7296a7d990d779c0480c417`
- Better Find-modified SHA-256: `7b5bf77f20c26154c5972c2eefa9bab3d966c3a52f8bca7ddeb0b4c90540f3f8`
- Modification period: 2026-08-17 through 2026-08-18
- License: `GPL-3.0-only`

Better Find carries these focused changes in the derived engine file:

1. `search` accepts `parseOperators: false`, allowing Alfred text to use Cling’s fuzzy scorer without treating punctuation as Cling query operators.
2. `walkDirectory` accepts `skipGitDirectories`, allowing Better Find’s **Include hidden items** setting to control whether `.git` trees are indexed.
3. `removePathAndDescendants` removes directory subtrees under Cling’s internal lock so FSEvents reconciliation can run concurrently with searches.
4. `walkDirectory` accepts a file-inclusion predicate so Better Find rejects hidden and excluded files before adding them to the index.
5. Extension registries are isolated per search engine, preventing replacement builds from clearing or contending with the live engine’s extension state.
6. A prominent SPDX/provenance header records the upstream revision, modification dates, license, and location of these notices.

Better Find-specific lifecycle, IPC, matching, and public adapter code otherwise lives in separate files under `Sources/ClingSearchCore/`, `Sources/BetterFindBackend/`, and `Sources/BetterFindIPC/` so future upstream changes remain reviewable.

Better Find does not use Cling’s product branding, graphical application, commerce layer, or Pro-license implementation. It uses, modifies, and redistributes GPL-licensed search/index code in a separately branded GPL application.
