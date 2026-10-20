# Troubleshooting Guide

This document provides troubleshooting information for common issues in student-repo-management.

## Common Issues

### GitHub CLI Authentication Problems
- Verify GitHub CLI is installed: `command -v gh`
- Check authentication status: `gh auth status`
- Re-authenticate if needed: `gh auth login`
- Refresh expired tokens: `gh auth refresh`

### Missing `workflow` Scope

Symptom — the push at the end of setup is rejected and only an empty repository
is left behind:

```
 ! [remote rejected] main -> main (refusing to allow an OAuth App to create or
   update workflow .github/workflows/autoassignees.yml without workflow scope)
```

`setup.sh` adds `.github/workflows/autoassignees.yml` for organization members
(it is deliberately absent from the templates), and GitHub refuses any push that
creates or updates a file under `.github/workflows/` with a token that lacks the
`workflow` scope. A push is atomic, so the whole of `main` is rejected along with
it: the repository keeps only the template's `Initial commit`, and `0th-draft`,
branch protection and registry registration never happen.

The default scopes of `gh auth login` are `repo`, `read:org` and `gist` — not
`workflow`. The container's own device-flow login does request `workflow`, so
whether a given person hits this depends on which of the two paths produced the
token `setup.sh` forwards.

- Inspect the scopes: `gh auth status` (or the `X-OAuth-Scopes` response header)
- Add the scope: `gh auth refresh -h github.com -s workflow`
- Delete the half-created repository before retrying; `setup.sh` has no resume
  mode, so re-running it against an existing repository does not fill in the
  missing pieces

`setup.sh` checks this before launching the container, so the failure above
should no longer be reachable; it is kept here because existing repositories
left in that state still need the recovery steps.

### Multiple Account Issues
- Check active account: `gh api user --jq .login`
- Switch accounts: `gh auth switch --user target-username`
- Verify organization access: `gh org list`
- Check TARGET_ORG environment variable

### Docker Authentication Problems
- Verify Docker Desktop is running
- Ensure host GitHub CLI authentication is complete
- Test with `DEBUG=1` for detailed output
- Check token passing: `echo $GH_TOKEN` (in container)

### Repository Creation Failures
- Verify student ID format matches patterns
- Check GitHub API rate limits
- Validate template repository access
- Confirm organization membership and permissions

### File Cleanup Issues
- Test student ID pattern matching
- Verify template file structure
- Check file permissions and Git operations

## Debug Commands

### Authentication Debugging
```bash
# Check host authentication status
gh auth status
gh api user --jq .login

# Test multiple account scenarios
gh auth list
gh auth switch --user target-username

# Test token validity manually
gh auth token | gh auth login --with-token
```

### Docker Debugging
```bash
# Test Docker container with token (image built from create-repo/Dockerfile;
# override the main.sh entrypoint to get a shell)
docker run -it --rm --entrypoint bash -e GH_TOKEN="$(gh auth token)" thesis-creator

# Check GitHub CLI in container (with token)
docker run --rm --entrypoint gh -e GH_TOKEN="$(gh auth token)" thesis-creator auth status
```

### Repository Creation Debugging
```bash
# Enable debug mode for detailed output
DEBUG=1 STUDENT_ID=k21rs001 bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis

# Verify student ID patterns
echo "k21rs001" | grep -E "k[0-9]{2}rs[0-9]{3}" && echo "undergraduate" || echo "graduate"

# Test TARGET_ORG scenarios
TARGET_ORG=your-username STUDENT_ID=k21rs001 ./setup.sh
```

## Emergency Procedures

### Repository Creation Failures
1. **Check system status** (GitHub, Docker Hub)
2. **Verify template availability**
3. **Test with debug mode** for detailed error information
4. **Manual repository creation** as fallback
5. **Document issues** for future prevention

### Review System Problems
1. **Use manual review branch update script**
2. **Verify GitHub Actions functionality**
3. **Check repository permissions and settings**
4. **Communicate with affected faculty and students**
5. **Document resolution steps**

## Shell Command Gotchas

### Backticks in gh pr create/edit
When using `gh pr create` or `gh pr edit` with `--body`, backticks (`) in the body text are interpreted as command substitution by the shell. This causes errors like:
```
permission denied: .devcontainer/devcontainer.json
command not found: 2025c-test
```

**Solution**: Always escape backticks with backslashes when using them in PR bodies:
```bash
# Wrong - will cause errors
gh pr create --body "Updated `file.txt` to version `1.2.3`"

# Correct - escaped backticks
gh pr create --body "Updated \`file.txt\` to version \`1.2.3\`"
```