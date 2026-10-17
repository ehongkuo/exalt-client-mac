# Build compatibility

The current integration uses a reviewed profile. Its addresses, method identities, hook bytes and caller
sites live in one JSON file. The build checks generated files against that profile before compiling.
An analysis report cannot approve a new build or change the installed app.
The commands below validate the selected profile and produce comparison reports when needed.

## Files

| File | Purpose |
|---|---|
| `active-profile.txt` | Selects the profile used for builds. |
| `profiles/2026-10-15.json` | Current native-audited build: 13 methods, 27 referenced fields and three caller sites. |
| `profiles/2026-10-12.json` | Historical comparison reference, assembled from the earlier audited source and metadata. Runtime generation is disabled for it. |
| `manage.py` | Profile validation, native header generation, binary verification and comparison reports. |
| `../guard/build_profile.h` | Generated C constants, method names/owners and audited hook bytes. Checked in for ordinary native compilation. |
| `../guard/game-build.sha256` | Generated fingerprint used by the launch gate. |

The signed app bundles `compatibility-profile.json` with its guard library and fingerprint. The app does
not load arbitrary profiles at runtime. The existing exact-build launch check, signature checks, typed
field reads and native entry-byte checks remain active. Gameplay behavior is unchanged.

## Check the current build

From the repository root:

```sh
python3 compatibility/manage.py generate --check
python3 compatibility/manage.py verify \
  --binary "$HOME/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib"
python3 tests/compatibility/test_profiles.py
```

The first command checks that the header and fingerprint match the reviewed source profile. The second
also checks the game fingerprint, every recorded entry prefix and all audited caller sites. It does not
launch the game. Normal app and probe builds check the generated files too.

After a reviewed profile edit, regenerate the checked-in outputs with:

```sh
python3 compatibility/manage.py generate
```

Candidate and historical-reference profiles cannot generate runtime outputs. A native-audited label is
an explicit developer review decision, not something the analysis command sets. It records a native
inspection; live readiness and damage-source coverage remain separate questions.

## Analyze a new game build

If the existing patched dumper is installed locally, this command runs it and creates both reports:

```sh
python3 compatibility/manage.py analyze \
  --binary "$HOME/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib" \
  --metadata "$HOME/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat" \
  --dumper "$HOME/Development/ExaltDumper-mac-v31/run-mac.sh" \
  --output build/compatibility/new-build
```

Choose a new output folder for each run. The command refuses an existing folder. It reads installed game
files, invokes the supplied trusted local dumper wrapper, and writes generated artifacts under the chosen
folder. No account credentials, settings, game preferences or network traffic are read. It never starts
the game or edits balances, requests, profiles, generated runtime constants or the installed app.

The dumper is a development dependency, not a runtime app dependency. This command uses its existing
`run-mac.sh <binary> <metadata> <new-output-directory>` interface. A dumper failure stops analysis; partial
generated artifacts may remain for diagnosis. Metadata version changes may require a dumper update.
The report records binary, metadata, dump and wrapper fingerprints. The wrapper fingerprint does not
identify every file in the external toolchain. Game/metadata changes during the analysis abort the run.

If a dump already exists, skip the dumper:

```sh
python3 compatibility/manage.py compare \
  --binary /absolute/path/to/GameAssembly.dylib \
  --dump /absolute/path/to/dump.cs \
  --output build/compatibility/comparison
```

A separately supplied dump is not proven to belong to the binary. Its fingerprint is retained, and all
findings still require review. Successful command exit means a report was produced, not compatibility
approval. Reports are Markdown (`report.md`) and JSON (`report.json`).

## Read the report

| Finding | Meaning |
|---|---|
| `unchanged` | The checked method identity and entry bytes/address, field type/storage/offset, or caller address matched. |
| `moved` | A unique matching identity and entry prefix moved, or a matching field/call moved. |
| `changed` | The entry bytes, signature, field type or static/instance storage differs. |
| `missing` | The lookup could not establish a matching item or caller. |
| `ambiguous` | Multiple matching methods, fields or calls remain. No candidate is selected. |

Methods match namespace, owning type, name, parameter types and return type. Obfuscated-name changes
produce missing/changed findings and need manual identification. Call analysis uses local
`xcrun llvm-objdump`, then checks decoded direct calls or the expected virtual slot inside the matched
containing method. Virtual-slot candidates assume the recorded vtable layout; a runtime/ABI change must
be reviewed. Address movement alone does not establish equivalent behavior.

An unchanged entry prefix does not prove the rest of a method is unchanged. A single matching call does
not prove it is the controlled-player path. Inspect damage/report ordering, object identity, HP updates,
virtual dispatch and escape behavior before accepting any new addresses. Ambiguous, shared or missing
metadata can prevent automatic matching. Decoder errors stop analysis.

Every report contains `approved_for_runtime: false` and `manual_review_required: true`, including reports
for a known build. The tool never turns its candidates into an approved runtime profile.

## After review

Create a new profile with the audited identities, offsets, complete relocatable hook prefixes, field
facts and caller sites. Update `active-profile.txt`, regenerate the outputs, and run the compatibility,
native and app tests. If method ABI or behavior changed, update the integration code as well. A profile
cannot adapt compiled C function prototypes or make an unsafe instruction prefix relocatable.

The build continues to reject unknown games. Dynamic relocation handling, per-feature availability,
unrestricted game-launch fallback and remote profile delivery are not part of this first stage.

🤖 Generated with Codex
