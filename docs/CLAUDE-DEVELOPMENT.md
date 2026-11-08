# Development Guide

This document provides detailed development guidance for student-repo-management.

## Architecture

### Docker-Based Repository Creation
The system uses containerized scripts to eliminate local dependencies:

**Prerequisites for students:**
- WSL + Docker Desktop (Windows) or Docker Desktop (macOS)
- GitHub CLI (recommended for improved experience)
- GitHub account with appropriate organization access

**Creation Process:**
1. **Host Authentication**: GitHub CLI authentication check and token retrieval on host
2. **Secure Token Transfer**: Authentication tokens passed to container via environment variables
3. **Repository creation**: From appropriate template (sotsuron-template or wr-template)
4. **File cleanup**: Automatic removal of unused files based on student ID pattern
5. **Environment setup**: LaTeX devcontainer integration via aldc script
6. **Workflow initialization**: Review system setup with initial branches

### Enhanced Authentication System
The authentication system provides a secure and user-friendly experience:

**Authentication Flow:**
1. **Host-side Validation**: Check GitHub CLI installation and authentication status
2. **Multiple Account Detection**: Automatically detect and validate multiple GitHub accounts
3. **Token Extraction**: Securely retrieve authentication tokens using `gh auth token`
4. **Container Security**: Pass tokens via environment variables, no persistent storage
5. **Fallback Support**: Maintain browser authentication for environments without GitHub CLI

**Multiple Account Support:**
```bash
# Validate that the current account can create in TARGET_ORG:
# either it is the user's own account, or the user is a member of that org.
CURRENT_USER=$(gh api user --jq .login)
if [ "$TARGET_ORG" != "$CURRENT_USER" ] \
   && ! gh api "orgs/$TARGET_ORG/members/$CURRENT_USER" >/dev/null 2>&1; then
    # Not a member (or org does not exist): guide account switching
    echo "gh auth switch --user <member>"
fi
```

### Organization Configuration (multi-org deployment)

`setup.sh` resolves the target organization without hardcoding `smkwlab`, so
the tool can be forked and deployed to another org. Override via environment
variables (defaults preserve smkwlab behavior):

| Variable | Default | Purpose |
|----------|---------|---------|
| `DEFAULT_ORG` | `smkwlab` | Org checked for membership and used as the default creation target for organization members. Forks set this (via env or by editing the embedded default). |
| `TARGET_ORG` | derived | Explicit creation target. If it is not the user's own account, membership in it is verified. Individual users default to their own account. |
| `TOOLS_REPO_OWNER` | `$DEFAULT_ORG` | Owner of the `student-repo-management` repo cloned internally. Distinct from `TARGET_ORG` (which may be a personal account). |
| `TOOLS_REPO_NAME` | `student-repo-management` | Repo name cloned internally and forwarded to the container for registry integration. |
| `TOOLS_CLONE_URL` | `https://github.com/<owner>/<repo>.git` | Full override of the clone URL (e.g. GitHub Enterprise / mirror). Must start with `https://` or `git@`. When set alone, also set `TOOLS_REPO_OWNER`/`TOOLS_REPO_NAME` so the usage/releases URLs in help text match the actual clone source. |
| `TEMPLATE_REPO` | per doc type | Source template repo. `thesis`/`ise`/`wr`/`sotsuron-report` default to `<org>/…`; `latex`/`poster` default to `smkwlab/…` (shared templates used by individual accounts too). Set to `<org>/<template>` to use your own. |
| `AUTO_ASSIGN_REVIEWER` | `toshi0806` | GitHub login inserted as the reviewer/assignee in the auto-assign config injected into organization-member repos. Set to a member of your org, or auto-assign will not work. |
| `RULE_REVIEW_ACTION` | `smkwlab/rule-review` in smkwlab, empty elsewhere | `owner/repo` of the private rule-review action whose caller is added to thesis repos of organization members. The caller (`@v2`) reads the org variable `RULE_REVIEW_APP_CLIENT_ID` and the org secret `RULE_REVIEW_APP_KEY` of the dispatch app that starts the private review runner. Empty or `off` adds nothing. Set it only if your org has its own rule-review action. |
| `ALDC_URL` | `https://raw.githubusercontent.com/smkwlab/aldc/main/aldc` | Source of the aldc LaTeX-devcontainer installer fetched during setup. Must start with `https://`. |
| `SETUP_GIT_EMAIL_DOMAIN` | `smkwlab.github.io` | Domain for the `setup-*@…` commit-author email used by the container. |

These container-side overrides (`TEMPLATE_REPO`, `AUTO_ASSIGN_REVIEWER`,
`RULE_REVIEW_ACTION`, `ALDC_URL`, `SETUP_GIT_EMAIL_DOMAIN`) are forwarded from `setup.sh` into the
Docker container only when set, each validated against a safe character set.

`TOOLS_REPO_OWNER` / `TOOLS_REPO_NAME` are validated against a safe character
set (character class only) before being embedded in the clone URL; GitHub's
finer naming rules are left to the clone-time error. See the ecosystem-wide
[Multi-Org Deployment Guide](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/MULTI-ORG-DEPLOYMENT.md)
(canonical upstream reference; the URL stays on the smkwlab origin repo
regardless of deployment org).

**Security Features:**
- No persistent authentication storage in containers
- Automatic token validation before use
- Clear permission error handling for student accounts
- Secure token passing via environment variables

### Student ID Pattern Recognition
```bash
# Undergraduate thesis (卒業論文)
k??rs??? (e.g., k21rs001) → sotsuron-template → keeps sotsuron.tex, gaiyou.tex, examples

# Graduate thesis (修士論文)  
k??gjk?? (e.g., k21gjk01) → sotsuron-template → keeps thesis.tex, abstract.tex only

# Weekly reports
Any pattern → wr-template → weekly report structure
```

### Review Workflow System
Sophisticated GitHub Actions-based supervision:

**Branch Strategy:**
- `initial`: Base state for clean diff tracking
- `0th-draft`, `1st-draft`, `2nd-draft`, etc.: Sequential development

**Faculty Workflow:**
- **Differential review**: Each draft PR shows changes from previous version
- **GitHub suggestions**: Direct edit capabilities for faculty
- **Auto-management**: Students close PRs after addressing feedback

## File Structure Conventions

### Repository Structure
```
create-repo/
├── setup.sh                    # Universal entry point (all document types)
├── main.sh                     # Unified creation script (DOC_TYPE: thesis/wr/latex/ise/poster/sotsuron-report)
├── common-lib.sh               # Shared functions and utilities
├── types/                      # Per-type definitions (static config + repo-name/commit/completion functions); see types/README.md
├── Dockerfile                  # Docker image shared by all document types
└── README.md                   # Usage instructions

scripts/
└── (management scripts)

docs/
└── (developer documentation: CLAUDE-*.md, RELEASE.md, etc.)
```

Faculty-facing guides (TEACHER-ONBOARDING.md, PR-REVIEW-GUIDE.md, TEACHER-GUIDE.md)
are centralized in
[latex-ecosystem/docs/](https://github.com/smkwlab/latex-ecosystem/tree/main/docs).

### Template Integration
- **sotsuron-template**: Primary template for undergraduate/graduate theses
- **wr-template**: Weekly report template
- **latex-environment**: LaTeX development environment (via aldc)

## Development Workflow

### For Script Updates
1. **Test locally** with sample student IDs
2. **Verify Docker builds** work across platforms
3. **Test authentication flow** in containerized environment
4. **Validate file cleanup** for different student ID patterns
5. **Test integration** with GitHub repository creation

### For Workflow Enhancements
1. **Test review system** with sample repositories
2. **Verify branch management** automation
3. **Validate faculty workflow** documentation
4. **Test error handling** and edge cases

### For Documentation Updates
1. **Keep faculty guides current** with GitHub interface changes
2. **Update student instructions** for clarity
3. **Document troubleshooting** procedures
4. **Maintain screenshot accuracy** in guides

## Testing Guidelines

### Local Testing
```bash
# Test Docker builds (single image for all document types)
docker build -f create-repo/Dockerfile -t test-creator .

# Test scripts with sample IDs (DOC_TYPE selects the document type)
cd create-repo
DOC_TYPE=thesis ./main.sh k21rs999  # Test undergraduate
DOC_TYPE=thesis ./main.sh k21gjk99  # Test graduate
DOC_TYPE=wr ./main.sh k21rs999      # Test weekly report

# Test file cleanup logic
echo "k21rs001" | grep -E "k[0-9]{2}rs[0-9]{3}"  # Should match
echo "k21gjk01" | grep -E "k[0-9]{2}gjk[0-9]{2}"  # Should match
```

### Integration Testing
- Test complete student onboarding flow
- Verify repository creation with all template types
- Test review workflow with sample content
- Validate faculty tools and documentation accuracy

### Error Handling Testing
```bash
# Test with invalid student IDs
DEBUG=1 DOC_TYPE=thesis ./main.sh invalid

# Test without Docker
STUDENT_ID=k21rs001 ./setup.sh  # Should handle gracefully

# Test network issues
# (Simulate offline conditions and verify error messages)
```

## Security Considerations

### Enhanced Authentication Security
- **Host-side Authentication**: GitHub CLI authentication performed on user's machine
- **Secure Token Transfer**: Tokens passed via environment variables, not stored in containers
- **Token Lifecycle**: Tokens are temporary and automatically expire
- **No Persistent Storage**: Containers do not store authentication information
- **Fallback Security**: Browser-based authentication maintained as secure fallback

### Container Security
- Minimal container images with only required tools
- No persistent storage of credentials
- Temporary token-based authentication only
- Regular base image updates
- Process isolation prevents token leakage

### Access Control
- Repository creation limited to authenticated GitHub users
- Multiple account support with proper validation
- Template access controlled via GitHub permissions
- Faculty review permissions managed through GitHub teams
- Student permission limitations handled gracefully
- Audit trail through GitHub activity logs

### Token Security Considerations
- **Environment Variable Exposure**: Tokens visible in process lists (acceptable for personal PC use)
- **Scope Limitation**: Tokens use minimal required scopes
- **Automatic Validation**: Token validity checked before use
- **Future Enhancement**: Consider file-based token transfer for enhanced security

## Contributing Guidelines

### Script Development
- Test with multiple student ID patterns
- Ensure cross-platform Docker compatibility
- Maintain error handling and user feedback
- Document all environment variables and options

### Documentation
- Keep faculty guides synchronized with GitHub interface
- Update screenshots and examples regularly
- Maintain troubleshooting procedures
- Include step-by-step instructions

### Testing Requirements
- All scripts must pass integration tests
- Docker containers must build successfully
- Error handling must be comprehensive
- Documentation must be accurate and current

### Review Process
- Test changes with sample student repositories
- Verify faculty workflow compatibility
- Check ecosystem integration points
- Validate security and access control measures