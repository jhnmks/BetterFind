# Corresponding Source

The installable `BetterFind.alfredworkflow` embeds complete corresponding source under `Source/BetterFind/`. It includes:

- Better Find’s adapter, backend, IPC, workflow files, assets, and build script
- The modified Cling search engine and its pinned provenance records
- All project and third-party license notices
- The complete Yams 6.2.2 source under `Vendor/Yams/`
- A source-package `Package.swift` that resolves Yams through `.package(path: "Vendor/Yams")`

The source revision and integrity details for the Cling-derived file are recorded in `Vendor/ClingCore/UPSTREAM.md`.

To rebuild from either this repository or an extracted `Source/BetterFind/` directory on an Apple Silicon Mac running macOS 13 or newer:

```zsh
chmod +x build-workflow.sh
./build-workflow.sh
```

Xcode Command Line Tools are required. The release script builds ARM64-only binaries and does not sign or notarize them.
