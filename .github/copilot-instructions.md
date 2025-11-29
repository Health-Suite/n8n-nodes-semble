# n8n Semble Integration - Copilot Instructions

**📋 See [workspace-overview.md](../../workspace-overview.md) for how this project relates to others**

## Critical Project-Specific Information

### Semble API Authentication - CRITICAL
**The Semble API uses `x-token` header, NOT `Authorization: Bearer`**

```typescript
// CORRECT
headers: { 'x-token': credentials.apiToken }

// WRONG - will fail with 401
headers: { 'Authorization': `Bearer ${credentials.apiToken}` }
```

This is implemented in `credentials/SembleApi.credentials.ts` - always use the `sembleApiRequest` helper which handles this correctly.

### API Documentation
- Official docs: https://docs.semble.io/
- GraphQL endpoint: https://open.semble.io/graphql
- **Always verify field names in docs** - validation errors usually mean incorrect field names, not permissions

### Rate Limiting
- Max 120 requests/minute
- Polling triggers: minimum 30 second intervals
- Use `sembleApiRequest` helper - it handles rate limiting automatically

### Testing Workflow
- **Never create new test workflows** - always use existing "Automated test - Don't delete" workflow
- Enable debug mode in node settings for detailed logging
- Test GraphQL queries independently before implementing

### Technology Stack
- TypeScript (strict mode)
- n8n-workflow framework
- GraphQL for Semble API
- PNPM for package management
- Docker for local n8n instance

### Project Structure
- `/credentials/` - Semble API authentication
- `/nodes/` - Action nodes (CRUD operations)
- `/triggers/` - Event monitoring nodes
- `/core/` - Shared utilities and helpers
- `/docs/` - Project documentation

### Excluded Fields Pattern
Complex fields (Letters, Labs, Prescriptions, etc.) are intentionally excluded from triggers for performance. They appear in output with explanatory messages directing users to dedicated nodes. Configuration in `BaseTrigger.ts` via `EXCLUDED_FIELDS_CONFIG`.

### Common Pitfalls
1. Using `Authorization: Bearer` instead of `x-token` header
2. Assuming field names without checking API docs
3. Creating new test workflows instead of using existing one
4. Not respecting rate limits in polling triggers
5. Missing GraphQL field validation against official schema

### British English - CRITICAL
**All code, comments, and documentation MUST use British English:**
- optimise (not optimize)
- colour (not color)
- customise (not customize)
- organisation (not organization)
- **Use -ise suffix, not -ize**

### File Management
- Always check if files exist before creating
- Use explicit full paths when creating files
- Update all references when moving files
- Project root is `n8n-nodes-semble` directory

## Essential Commands
```bash
pnpm install          # Install dependencies
pnpm run build        # Build the project
pnpm run lint         # Run linting
pnpm run dev          # Development mode with Docker
```
