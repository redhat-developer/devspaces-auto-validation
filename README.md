# DevWorkspace Auto Validation

Automated validation tool for testing DevWorkspace instances on OpenShift clusters. Tests container image compatibility with devfiles across three editor scenarios: SSHD, JetBrains IDEA, and VSCode.

## Commands

### Running Tests

```bash
# Basic validation (uses small lists - images/images.txt and devfiles/devfiles.txt)
./dw-auto-validate.sh

# Verbose mode - shows detailed output
./dw-auto-validate.sh -v

# Full test matrix (uses *-full.txt files - all images, all devfiles. Takes significant time to complete!)
./dw-auto-validate.sh -f

# Debug mode - verbose + runs only first test + no cleanup
./dw-auto-validate.sh -d

# Skip interactive scenario choice (valid values: sshd, jetbrains, vscode)
./dw-auto-validate.sh -s vscode

# Test a che-code PR image (from che-incubator/che-code)
./dw-auto-validate.sh -p 1234

# Test a custom editor image
./dw-auto-validate.sh -i quay.io/redhat-user-workloads/devspaces-tenant/devspaces/code-rhel9:3.29

# Help
./dw-auto-validate.sh -h
```

### Verify Images

```bash
# Check all images in images-full.txt are accessible via skopeo
./verify_images.sh
```

## Dependencies

- `oc` - OpenShift CLI
- `jq` - JSON processor
- `curl` - HTTP client (for fetching devfiles)
- `skopeo` - Container image inspector (for verify_images.sh, `-p` PR image verification, and `-i` custom image verification)

## Architecture

### Main Script Flow (dw-auto-validate.sh)

1. **Prerequisites Check**: Validates `oc`, `jq` (and `skopeo` when using `-p` or `-i`) installation, checks cluster login (prompts for web login if needed)
2. **Scenario Selection**: Interactive prompt to choose scenario (1=sshd, 2=jetbrains, 3=vscode)
3. **Settings Loading**: Sources `settings/settings-<SCENARIO>.env` to load configuration and validation function
4. **Test Execution**:
   - Starts timer
   - Iterates through devfiles × images matrix
   - For each combination: creates DevWorkspace, waits for Running state, validates, records results
5. **Cleanup**: Deletes DevWorkspace and temporary files (skipped in debug mode)
6. **Summary Report**: Shows test counts, success/failure/excluded, elapsed time, and lists failed tests

### Command-Line Flags

- `-v`: Verbose mode - enables `log()` output, shows detailed progress
- `-f`: Full mode - uses `images/images-full.txt` and `devfiles/devfiles-full.txt` instead of their default counterparts
- `-d`: Debug mode - enables verbose output, runs only first test, skips cleanup (shows skipped resources)
- `-s <scenario>`: Skip interactive scenario prompt by specifying the scenario directly (`sshd`, `jetbrains`, or `vscode`)
- `-p <PR_NUMBER>`: Test a che-code PR image — downloads the editor definition, replaces the che-code image with `quay.io/che-incubator-pull-requests/che-code:pr-<PR_NUMBER>-amd64`, and creates a DevWorkspaceTemplate to use it
- `-i <IMAGE>`: Test a custom editor image — same mechanism as `-p` but with an arbitrary image reference (mutually exclusive with `-p`)
- `-h`: Help - displays usage information

**Debug mode specifics**: Sets `DEBUG=1`, `FULL=0`, `VERBOSE=1`, runs only the first test iteration (`[[ ${DEBUG} -eq 1 && ${total_count} == 1 ]] && continue`), skips cleanup to allow resource inspection.

### Scenarios

Each scenario in `settings/settings-<SCENARIO>.env` exports:

- `TIMEOUT`: Seconds to wait for DevWorkspace to reach 'Running' state
- `DEVWORKSPACE_NAME`: Name for the DevWorkspace instance (e.g., 'sshd-test', 'jetbrains-idea-test', 'vscode-test')
- `PROJECT_URL`: Git repository URL (must include surrounding double quotes)
- `EDITOR_DEFINITION`: URL to the editor definition YAML
- `EDITOR_COMPONENT_NAME`: Component name in the editor definition that contains the editor image (used by `-i`/`-p` to replace the correct image)
- `EXCLUDED_IMAGE_PATTERNS`: Array of Posix Extended Regular Expressions for images excluded from failure counts
- `validate_devworkspace()`: Function that evaluates whether the DevWorkspace is valid (scenario-specific checks)

#### Scenario Validation

Each scenario defines its own `validate_devworkspace()` function with checks tailored to its editor:

| Scenario | Timeout | Validation Checks | Editor Component |
|----------|---------|-------------------|------------------|
| sshd | 60s | HTTP check on port 3400 via `oc exec` curl (`-m 5`) + `/tmp/sshd.log` for `Server listening on` | che-code-sshd-page |
| jetbrains | 120s | HTTP check on port 3400 via `oc exec` curl (`-m 5`) | editor-injector |
| vscode | 120s | HTTP check on port 3100 via `oc exec` curl (`-m 5`), dumps `/checode/entrypoint-logs.txt` on failure | che-code-injector |

### DevWorkspace Generation

Uses `devworkspace-template.yaml` as base. The template uses ephemeral storage (`controller.devfile.io/storage-type: ephemeral`) to avoid PVC provisioning overhead during tests.

Substitutions are performed in two stages:

**Stage 1** - Metadata, devfile, and projects injection:
```bash
cat devworkspace-template.yaml | sed \
  -e "/DEVFILE/r ${TMP_DEVFILE}" \       # Inject devfile content
  -e '/DEVFILE/ d' \                     # Remove DEVFILE placeholder
  -e "/PROJECTS/r ${TMP_PROJECTS}" \     # Inject projects block
  -e '/PROJECTS/ d' \                   # Remove PROJECTS placeholder
  -e "s|DEVWORKSPACE_NAME|...|" \
  -e "s|DEVWORKSPACE_NS|...|" \
  -e "${EDITOR_SED_EXPR}" \             # Editor definition (uri or kubernetes ref)
  -e "s|PROJECT_URL|...|"
```

**Stage 2** - Image override:
```bash
eval "sed \"s|image: .*|image: ${image}|\" > ${TMP_DEVWORKSPACE}"
```

The two-stage approach ensures devfile content is injected before image replacement.

**Projects handling**: If the devfile contains `starterProjects`, those are extracted and converted into a `projects:` block. Otherwise, the scenario's `PROJECT_URL` is used as a fallback sample project.

**Editor contribution**: When using `-p` or `-i` (override image), the editor contribution switches from `uri:` to `kubernetes: name:` referencing the applied DevWorkspaceTemplate.

### DevWorkspace Lifecycle Management

After each test, `cleanup_test()` handles the workspace depending on its current state:

- **Running / Starting**: Gracefully stops by patching `spec.started: false` and waiting up to `TIMEOUT/4` seconds for `Stopped` state.
- **Failed**: Force-deletes the workspace (`oc delete dw`) and waits for all associated pods to terminate before returning. This prevents stale pods from interfering with the next test's pod resolution.
- **Stopped / not found**: No action needed.
- **Debug mode**: `cleanup_test()` is skipped entirely to allow resource inspection.

At the end of the suite, `cleanup_suite()` deletes the DevWorkspace, any override DevWorkspaceTemplate, and temporary files (skipped in debug mode).

When a DevWorkspace fails to start, the script logs the failure reason from `.status.message`.

### Logging and Output Control

- `log()`: Outputs only when `VERBOSE=1` (set by `-v` or `-d` flags)
- `${QUIET}`: Set to `&>/dev/null` in non-verbose mode, empty string otherwise
  - Used with `eval` to conditionally suppress `oc` command output: `eval "oc apply -f ${TMP_DEVWORKSPACE} ${QUIET}"`

### Timing

Tracks test execution time using bash's `$SECONDS` variable:
- `START_TIME=$SECONDS` captured before test loop
- `ELAPSED_TIME=$((SECONDS - START_TIME))` calculated after cleanup
- Displayed in purple in summary as `Xm Ys` or `Xh Ym Zs` when duration exceeds 1 hour

## File Structure

```
settings/
  settings-sshd.env       # SSHD scenario: timeout=60s, port 3400
  settings-jetbrains.env  # JetBrains scenario: timeout=120s, port 3400
  settings-vscode.env     # VSCode scenario: timeout=90s, port 3100

images/
  images.txt              # Default test list (UDI images: ubi8, ubi9, ubi10)
  images-full.txt         # Complete test matrix (227 images including UDI, base-developer-image, and UBI variants)

devfiles/
  devfiles.txt            # Default test list (nodejs)
  devfiles-full.txt       # Complete devfile list (32 devfiles from devfile registry including java-quarkus, ollama, openclaw, picoclaw, zeroclaw)

samples/
  samples.txt             # Sample project URLs (currently unused)
  samples-full.txt        # Extended sample project list (currently unused)

devworkspace-template.yaml  # Base template with placeholders (ephemeral storage)
dw-auto-validate.sh        # Main validation orchestrator
verify_images.sh           # Skopeo-based image accessibility checker
```

## Implementation Details

### Validation Function

Each scenario defines its own `validate_devworkspace()` function in its settings file. All scenarios call `resolve_devworkspace_pod()` to set `podName` and `mainContainerName` globals, then perform scenario-specific checks (landing page HTTP check, log file scraping, or both).

`resolve_devworkspace_pod()` finds the pod by DevWorkspace label (filtering for `status.phase=Running` to exclude terminating pods) and selects the main container from pod status, filtering out containers whose name starts with `che-`.

### Variable Quoting Requirements

`PROJECT_URL` must include its own quotes: `export PROJECT_URL='"https://..."'`

This is because the sed substitution inserts the value directly into YAML:
```yaml
git:
  remotes:
    origin: PROJECT_URL  # becomes: origin: "https://..."
```

### Common DevWorkspace Patterns

**Waiting for Running state**:
```bash
state=""
count=0
while [ "${state}" != "Running" ] && [ "${state}" != "Failed" ] && [ ${count} -lt ${TIMEOUT} ]; do
  state=$(oc get dw ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}')
  sleep 1s
  count=$((count+1))
done
```

**Finding pod by DevWorkspace label** (filtered to Running pods only):
```bash
podNameAndDWName=$(oc get pods --field-selector=status.phase=Running -o 'jsonpath={range .items[*]}{.metadata.name}{","}{.metadata.labels.controller\.devfile\.io/devworkspace_name}{"\n"}{end}')
podName=$(echo "${podNameAndDWName}" | grep ${DEVWORKSPACE_NAME} | head -1 | cut -d, -f1)
```

**Getting main container name** (from pod status, excluding `che-*` containers):
```bash
mainContainerName=$(oc get pod "${podName}" -o json | jq -r '[.status.containerStatuses[] | select(.state.running and (.name | test("^che-") | not))] | first | .name // empty')
```

### Adding a New Scenario

1. Create `settings/settings-<name>.env`
2. Export required variables: `TIMEOUT`, `DEVWORKSPACE_NAME`, `PROJECT_URL`, `EDITOR_DEFINITION`, `EDITOR_COMPONENT_NAME`, `EXCLUDED_IMAGE_PATTERNS`
3. Define a `validate_devworkspace()` function with scenario-specific validation checks
3. Update scenario selection in dw-auto-validate.sh (add option, update prompts and `-s` validation)
