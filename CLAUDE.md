# CLAUDE.md

Administrative tools and workflows for thesis supervision at Kyushu Sangyo University. Provides Docker-based student repository creation and GitHub-based review systems.

## Quick Start

### Student Repository Creation
```bash
# Universal Setup Script - All document types supported (Recommended)
bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis

# With student ID specified (environment variable)
STUDENT_ID=k21rs001 bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis

# Document type specific usage
bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis   # Thesis repository
bash <(curl -fsSL https://repo-setup.smkwlab.net) wr       # Weekly reports
bash <(curl -fsSL https://repo-setup.smkwlab.net) latex    # General LaTeX
bash <(curl -fsSL https://repo-setup.smkwlab.net) ise      # ISE reports
bash <(curl -fsSL https://repo-setup.smkwlab.net) poster   # Conference posters
bash <(curl -fsSL https://repo-setup.smkwlab.net) sotsuron-report  # Thesis survey reports

# Environment variable style (Legacy, still supported)
DOC_TYPE=thesis bash <(curl -fsSL https://repo-setup.smkwlab.net)

# Advanced configuration with environment variables
DOCUMENT_NAME=research-note STUDENT_ID=k21rs001 bash <(curl -fsSL https://repo-setup.smkwlab.net) latex

# Individual mode for personal LaTeX documents (no student ID required)
INDIVIDUAL_MODE=true DOCUMENT_NAME=my-paper bash <(curl -fsSL https://repo-setup.smkwlab.net) latex
```

**Version pinning (reproducibility & safety)**: The short URL serves the latest stable
release (the `v1` moving tag), so the commands above never run unreleased changes. To
pin an exact version instead, fetch the raw URL with a release tag; the script body and
the content it clones internally are both pinned to that tag. The internal ref can also
be overridden via `UNIVERSAL_REF` (precedence: `UNIVERSAL_REF` > `UNIVERSAL_BRANCH` >
the ref embedded at release time). See [docs/RELEASE.md](docs/RELEASE.md) for the
release workflow.

```bash
# Pinned to an exact release
bash <(curl -fsSL https://raw.githubusercontent.com/smkwlab/student-repo-management/v1.3.0/create-repo/setup.sh) thesis
```

### Branch Protection Setup

**Automatic Setup (Thesis Repositories)**

Branch protection is automatically configured for thesis repositories through the following workflow:

1. Student creates repository using `setup.sh`
2. Issue is automatically created in `student-repo-management`
3. GitHub Actions (`student-repo-management.yml`) triggers automatically
4. `process-pending-issues.sh` executes `setup-branch-protection.sh`
5. Branch protection settings applied and recorded in `thesis-student-registry`

**Manual Setup (Faculty)**

For manual branch protection setup or troubleshooting:

```bash
# Individual student setup
./scripts/setup-branch-protection.sh k21rs001-sotsuron

# Check protection status
gh repo view smkwlab/k21rs001-sotsuron --json branchProtectionRules
```

**Note**: Weekly reports (wr-template) and thesis survey reports (sotsuron-report-template) do not use branch protection as they have simpler workflows. General LaTeX documents (latex-template) do not use it by default either, but opt in via `REVIEW_FLOW=true` at creation time. ISE reports (ise-report-template) and posters (poster-template) always use the same PR-based branch protection as thesis repositories.

## Key Files & Structure

```
create-repo/
├── setup.sh              # Universal Setup Script - All document types
├── main.sh               # Unified creation script (DOC_TYPE: thesis/wr/latex/ise/poster/sotsuron-report)
├── common-lib.sh         # Shared functions and utilities
├── types/                # Per-type definitions (static config + repo-name/commit/completion functions); see types/README.md
└── Dockerfile            # Docker image shared by all document types

scripts/
├── setup-branch-protection.sh    # Branch protection for individual student
├── process-pending-issues.sh     # Batch processing of pending repository requests
├── fill-author-readme.sh         # Author information into a new repository's README (run before branch protection)
├── sync-author-readme.sh         # Backfill the author README onto main for pre-existing repositories
├── lib/author-readme.sh          # Roster lookup, placeholder substitution and legacy-template migration
└── validate-yaml.sh              # YAML/GitHub Actions validation

## Data Management Integration

**IMPORTANT**: Student data management has been consolidated into `thesis-student-registry`:

- **Student registry (data)**: `thesis-student-registry/data/registry.json` (private repo)
- **Management tool**: [smkwlab/registry-manager](https://github.com/smkwlab/registry-manager) (Elixir escript, separate repo)
- **Monitoring tool**: [smkwlab/thesis-monitor](https://github.com/smkwlab/thesis-monitor) (Elixir escript, separate repo)

All operations now use GitHub API for safe, atomic data management instead of local files.
The tools read the registry location from `~/.config/registry-manager/config.json`
(`registry_repo`); thesis-monitor reads the registry via the GitHub contents
API using the same `registry_repo` key (or the `<org>/thesis-student-registry`
convention when unset, with `<org>` taken from the `github_org` config key,
default `smkwlab`).

## Document Type Configuration

Universal Setup Script uses `DOC_TYPE` environment variable to specify document type:

### Supported Document Types
- **thesis**: Undergraduate/Graduate thesis (sotsuron-template)
- **wr**: Weekly reports (wr-template)
- **latex**: General LaTeX documents (latex-template)
- **ise**: Information Science Exercise reports (ise-report-template)
- **poster**: Conference posters (poster-template)
- **sotsuron-report**: Thesis survey reports (sotsuron-report-template)

### Environment Variable Options
```bash
# LaTeX document configuration
DOCUMENT_NAME=research-note    # Custom document name

# Draft PR review flow opt-in (DOC_TYPE=latex only; thesis/ise/poster are always on, wr and sotsuron-report unsupported)
REVIEW_FLOW=true               # Initialize main + 0th-draft, enable auto-assign, apply branch protection

# Individual mode behavior (DOC_TYPE=latex only)
INDIVIDUAL_MODE=true           # Skip student ID input, create in personal account
# Note: When INDIVIDUAL_MODE=true, any STUDENT_ID argument is ignored
# Note: Individual mode automatically disables Registry Manager integration

# Non-interactive execution (auto-approve the confirmation prompt)
ASSUME_YES=1                   # Skip the "続行しますか?" confirmation; run without a TTY
# Accepted truthy values: 1 / true / TRUE / yes / YES (setup.sh normalizes to true internally)
# Works for all document types, independent of INDIVIDUAL_MODE (e.g. bulk creation, CI).
# setup.sh validates that the inputs needed to avoid any remaining prompt are present
# and fails fast before launching the container if any are missing:
#   - thesis/wr/ise : STUDENT_ID required (organization flow)
#   - latex         : STUDENT_ID (organization flow) + DOCUMENT_NAME
#   - poster        : STUDENT_ID (organization flow) + POSTER_NAME or DOCUMENT_NAME
# Under INDIVIDUAL_MODE=true, STUDENT_ID is not required (only the name inputs above).

# ISE report configuration
ISE_REPORT_NUM=1              # Report number (1 or 2)
```

```bash
# Non-interactive organization-flow example (no prompts, no TTY needed)
STUDENT_ID=k21rs001 ASSUME_YES=1 bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

## Student ID Patterns

`setup.sh` does not auto-detect the document type from the student ID. The mapping
below is the `DOC_TYPE` you should **specify** (positional `<type>` argument or the
`DOC_TYPE` env var) for each case.

```bash
# Undergraduate: k##rs### → DOC_TYPE=thesis
k21rs001, k22rs123, k23rs999

# Graduate: k##gjk## → DOC_TYPE=thesis
k21gjk01, k22gjk15, k23gjk99

# Weekly reports: any pattern → DOC_TYPE=wr
# General LaTeX: any pattern → DOC_TYPE=latex
# ISE reports: any pattern → DOC_TYPE=ise
```

## Common Tasks

### Test Repository Creation
```bash
# Local testing (DOC_TYPE selects the document type)
cd create-repo && DOC_TYPE=thesis ./main.sh k21rs999

# Docker testing
docker build -f create-repo/Dockerfile -t test-creator .
```

### Data Management (Registry Manager Integration)
```bash
# Build the tools (each in its own checkout)
(cd registry-manager && mix escript.build)
(cd thesis-monitor && mix escript.build)

# View repository status
./thesis-monitor/thesis-monitor status

# Add new repository to registry
./registry-manager/registry-manager add k21rs001-sotsuron

# Mark branch protection complete
./registry-manager/registry-manager protect k21rs001-sotsuron

# Update a repository field (e.g. GitHub username)
./registry-manager/registry-manager update k21rs001-sotsuron github_username student001
```

### Debug Authentication Issues
```bash
# Check GitHub CLI status
gh auth status && gh api user --jq .login

# Enable debug mode
DEBUG=1 STUDENT_ID=k21rs001 ./create-repo/setup.sh
```

### Emergency Manual Operations
```bash
# Validate repository structure
gh repo view smkwlab/repo-name --json defaultBranch,visibility
```

## Detailed Documentation

- **[Release Guide](docs/RELEASE.md)** - SemVer policy, manual release procedure, version pinning
- **[Development Guide](docs/CLAUDE-DEVELOPMENT.md)** - Architecture, security, testing
- **[Troubleshooting](docs/CLAUDE-TROUBLESHOOTING.md)** - Common issues, debug commands
- **[Workflows](docs/CLAUDE-WORKFLOWS.md)** - Student/faculty workflows, ecosystem integration
- **[Command Examples](docs/CLAUDE-EXAMPLES.md)** - Detailed usage examples, patterns