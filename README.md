# DevWorkspace Auto Validation

Automated validation tool for testing DevWorkspace instances on OpenShift clusters. Tests container image compatibility with devfiles across three editor scenarios: SSHD, JetBrains IDEA, and VSCode.

## Commands

### Running Tests

```bash
# Basic validation (uses small numbers of entries - 3 images, 5 devfiles)
./dw-auto-validate.sh

# Verbose mode - shows detailed output
./dw-auto-validate.sh -v

# Full test matrix (uses all entries from -full.txt files - all images, all devfiles. Takes significant time to complete!)
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
6. **Summary Report**: Shows test counts, success/failure, elapsed time, and lists failed tests

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
- `validate_devworkspace()`: Function that validates the running DevWorkspace

#### Scenario Validation Methods

**sshd** (settings-sshd.env):
- Timeout: 60s
- Checks `/tmp/sshd.log` for "Server listening on"
- Verifies SSHD server started successfully

**jetbrains** (settings-jetbrains.env):
- Timeout: 120s
- Port-forwards to 3400, curls `127.0.0.1:3400`
- Validates HTTP 200 response from JetBrains landing page
- On failure, outputs `/idea-server/std.out` for debugging

**vscode** (settings-vscode.env):
- Timeout: 60s
- Checks `/checode/entrypoint-logs.txt` for "Extension host agent listening on 3100"
- Verifies VSCode extension host is listening

### DevWorkspace Generation

Uses `devworkspace-template.yaml` as base, performs sed substitutions in two stages:

**Stage 1** - Metadata and devfile injection:
```bash
cat devworkspace-template.yaml | sed \
  -e "/DEVFILE/r ${TMP_DEVFILE}" \    # Inject devfile content
  -e '/DEVFILE/ d' \                  # Remove DEVFILE placeholder
  -e "s|DEVWORKSPACE_NAME|...|" \
  -e "s|DEVWORKSPACE_NS|...|" \
  -e "s|EDITOR_DEFINITION|...|" \
  -e "s|PROJECT_URL|...|"
```

**Stage 2** - Image override:
```bash
eval "sed \"s|image: .*|image: ${image}|\" > ${TMP_DEVWORKSPACE}"
```

The two-stage approach ensures devfile content is injected before image replacement.

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
  settings-sshd.env       # SSHD scenario: timeout=60s, validates /tmp/sshd.log
  settings-jetbrains.env  # JetBrains scenario: timeout=120s, validates port 3400
  settings-vscode.env     # VSCode scenario: timeout=60s, validates /checode/entrypoint-logs.txt

images/
  images.txt              # Quick test list (3 UDI images: ubi8, ubi9, ubi10)
  images-full.txt         # Complete test matrix (UDI + base-developer-image variants)

devfiles/
  devfiles.txt            # Quick test list (nodejs, go, python, php-laravel and java-quarkus devfile)
  devfiles-full.txt       # Complete devfile list (32 devfiles from devfile registry)

samples/
  samples.txt             # Sample project URLs (currently unused)
  samples-full.txt        # Extended sample project list (currently unused)

devworkspace-template.yaml  # Base template with placeholders
dw-auto-validate.sh        # Main validation orchestrator
verify_images.sh           # Skopeo-based image accessibility checker
```

## Implementation Details

### Validation Function Pattern

All `validate_devworkspace()` functions follow this pattern:

```bash
validate_devworkspace() {
  devfile_url=$1  # Receives devfile URL as first argument

  # Resolve pod and container via shared helper
  resolve_devworkspace_pod || return 1

  # Scenario-specific validation logic here
  # Return 0 for pass, 1 for fail
}
```

The shared `resolve_devworkspace_pod()` function sets `podName` and `mainContainerName` globals.

**Critical details**:
- Has access to `${DEVWORKSPACE_NS}`, `${DEVWORKSPACE_NAME}`, `log()`
- Must return 0 for success, 1 for failure
- Should use `&>/dev/null` on oc exec commands meant only for exit code checking

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
while [ "${state}" != "Running" ] && [ ${count} -lt ${TIMEOUT} ]; do
  state=$(oc get dw ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}')
  sleep 1s
  count=$((count+1))
done
```

**Finding pod by DevWorkspace label**:
```bash
podNameAndDWName=$(oc get pods -o 'jsonpath={range .items[*]}{.metadata.name}{","}{.metadata.labels.controller\.devfile\.io/devworkspace_name}{end}')
podName=$(echo ${podNameAndDWName} | grep ${DEVWORKSPACE_NAME} | cut -d, -f1)
```

**Getting main container name**:
```bash
mainContainerName=$(oc get devworkspace ${DEVWORKSPACE_NAME} -o json | jq -r '[.spec.template.components[] | select(.container) | .name] | first')
```

### Adding a New Scenario

1. Create `settings/settings-<name>.env`
2. Export required variables: `TIMEOUT`, `DEVWORKSPACE_NAME`, `PROJECT_URL`, `EDITOR_DEFINITION`
3. Implement `validate_devworkspace()` function that returns 0/1
4. Update scenario selection in dw-auto-validate.sh (add option, update prompts)
