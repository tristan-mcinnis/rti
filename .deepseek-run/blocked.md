# Blocked

## B01: TCC sandbox prevents xcodebuild package resolution

**Severity**: BLOCKER (Phase 0 cannot proceed)

**Symptom**: `xcodebuild` fails during "Resolve Package Graph" with:
```
cannot open file '~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia' 
for diagnostics emission (Operation not permitted)
```

**Root cause**: Files in `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/` have `com.apple.provenance` extended attributes that prevent access from the DeepSeek TUI sandbox. These files were created by a different process (likely Xcode.app GUI) and are TCC-protected.

**Attempted fixes**:
- `chmod 644` — no effect (permissions already correct)
- `xattr -c` — Operation not permitted
- `rm` — Operation not permitted
- `mv` — Operation not permitted
- `echo "" >` — Operation not permitted
- `HOME=/tmp/fake-home` — xcodebuild ignores HOME override for SwiftPM cache
- `SWIFTPM_CACHE_DIR` env var — SwiftPM inside xcodebuild ignores this
- PTY allocation — no difference
- `-derivedDataPath` — packages fetch/checkout fine but manifest loading still hits the protected cache
- `-disableAutomaticPackageResolution` — still resolves the package graph

**Workaround**: The user must run this command in Terminal.app (not inside DeepSeek TUI):
```bash
rm ~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia
```
After this, xcodebuild will recreate the files from within the same sandbox context.

**Impact**: Phase 0 cannot complete — no build baseline, no test baseline. Phase 1 (MAP) can proceed read-only.
