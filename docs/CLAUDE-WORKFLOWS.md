# Workflows and Best Practices

This document covers user workflows and development best practices for student-repo-management.

## Student Workflow (Automated)

### Repository Creation Phase
1. **Run one-liner command** (Docker handles everything)
2. **Browser authentication** with GitHub (automatic)
3. **Repository creation** from appropriate template
4. **File cleanup** based on thesis type
5. **LaTeX environment setup** via aldc integration
6. **Initial branch setup** for review workflow

### Development Phase
```
Phase 1: Thesis Writing
0th-draft (outline) → 1st-draft → 2nd-draft → ... → submit tag

Phase 2: Abstract Writing  
abstract-1st → abstract-2nd → abstract completion

Phase 3: Final Submission
Further improvements → final-* tag → submission PR opened automatically → faculty merges
```

## Faculty Workflow

### Review Process
1. **Monitor draft PRs** for incremental changes
2. **Provide feedback** via GitHub comments and suggestions
3. **Track progress** through branch sequence
4. **Final approval** through GitHub workflow

### Management Tools
- **Progress tracking**: Via GitHub repository insights
- **Deadline management**: Through milestone and project features
- **Quality assurance**: Automated LaTeX compilation and textlint checks
- **Communication**: Integrated with GitHub notification system

## Ecosystem Integration

### Related Repositories
- **sotsuron-template**: Primary thesis template
- **wr-template**: Weekly report template  
- **latex-environment**: Development environment
- **aldc**: LaTeX environment deployment tool

### Coordination Points
- Template updates require coordination with creation scripts
- LaTeX environment changes may affect repository setup
- Faculty workflow changes require documentation updates
- Student onboarding process spans multiple repositories

## MCP Tools Usage

### GitHub Operations
Use MCP tools instead of `gh` command for GitHub operations:
- **Development**: Use `mcp__gh-toshi__*` tools for development work
- **Student testing**: Use `mcp__gh-k19__*` tools only when testing student workflows