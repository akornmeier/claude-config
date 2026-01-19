# Project Rename: Poche → Stache

**Domain:** stache.it.com

## Scope Summary

~66 files contain "Poche"/"poche" references across:
- 5 package.json files (npm scope `@poche/*`)
- UI components (navbar, sidebar, footer, about page)
- Documentation (README, CONTRIBUTING, GETTING_STARTED, etc.)
- Docker/Infrastructure configs
- Environment files
- CI/CD workflows
- Local storage keys
- CSS classes
- Test files

---

## Phase 1: Package Infrastructure

### 1.1 Package Names
| File | Change |
|------|--------|
| `package.json` | `"name": "poche"` → `"stache"`, update author |
| `apps/web/package.json` | `@poche/web` → `@stache/web` |
| `packages/convex/package.json` | `@poche/convex` → `@stache/convex` |
| `packages/types/package.json` | `@poche/types` → `@stache/types` |
| `packages/utils/package.json` | `@poche/utils` → `@stache/utils` |

### 1.2 Turbo Config
- `turbo.json`: Update task refs `@poche/convex#*` → `@stache/convex#*`

### 1.3 TypeScript Imports
Update all imports across codebase:
- `@poche/convex/api` → `@stache/convex/api`
- `@poche/types` → `@stache/types`
- `@poche/utils` → `@stache/utils`

---

## Phase 2: Infrastructure

### 2.1 Docker (`docker-compose.yml`)
- Container names: `poche-postgres` → `stache-postgres`, etc.
- DB user: `poche` → `stache`
- DB name: `poche_dev` → `stache_dev`
- DB password: `poche_dev_password` → `stache_dev_password`

### 2.2 Database Init (`infrastructure/database/init/01-init.sql`)
- Database name, user, privileges

### 2.3 Storage (`infrastructure/storage/create-buckets.sh`)
- Bucket names: `poche-dev` → `stache-dev`, etc.

### 2.4 Environment Files
- `.env.example`: DATABASE_URL, S3_BUCKET
- `.env.development`: S3_BUCKET
- `packages/convex/.env.local`: Comment about project name

---

## Phase 3: UI & Branding

### 3.1 Logo
- **Replace** `apps/web/public/images/poche-logo.png` with new `stache-logo.png`
- Update refs in: `PublicNavbar.tsx`, `AppSidebar.tsx`, `index.tsx`
- User will provide the new logo file

### 3.2 Text Content
| Component | Change |
|-----------|--------|
| `__root.tsx` | Page title "Poche" → "Stache" |
| `PublicNavbar.tsx` | Brand text |
| `AppSidebar.tsx` | Brand text |
| `PublicFooter.tsx` | Copyright text |
| `about.tsx` | About page: Update "Poche" → "Stache", blend pocket theme + mustache imagery |
| `index.tsx` (public) | Landing page text |

### 3.3 CSS
- `index.css`: `.poche-glowing-circle` → `.stache-glowing-circle`

### 3.4 Local Storage Keys
- `useSidebar.ts`: `poche-sidebar-collapsed` → `stache-sidebar-collapsed`
- `providers/index.tsx`: `poche-ui-theme` → `stache-ui-theme`

---

## Phase 4: Documentation

Update all markdown files:
- `README.md` - Title, description, logo ref, badges
- `CONTRIBUTING.md` - Project name refs
- `GETTING_STARTED.md` - Test user: `test@poche.dev` → `test@stache.it.com`, welcome messages
- `DEPLOYMENT.md` - URLs, team name
- `PROJECT_PLAN.md` - Project description
- `docs/design-system/*.md` - Brand refs
- `docs/architecture/*.md` - Package refs
- `docs/setup/github-actions-secrets.md` - Bucket names, client IDs
- `openspec/project.md` - Project description
- Package README files

---

## Phase 5: Configuration & CI

### 5.1 Config Files
- `.serena/project.yml`: `project_name`
- `.vscode/settings.json`: cSpell words
- `.github/dependabot.yml`: Reviewer team name

### 5.2 Storybook Files
- `PublicNavbar.stories.tsx`, `AppSidebar.stories.tsx`

---

## Phase 6: Tests

Update test files checking for "Poche" text:
- `useSidebar.test.ts` - Storage key
- `public-layout.test.tsx` - Logo checks
- `PublicNavbar.test.tsx` - Alt text
- `PublicFooter.test.tsx` - Footer text

---

## External Dependencies (Manual/Later)

These require external action:
1. **Convex Cloud**: Project `poche-a8627` may need rename or new deployment
2. **Vercel**: Project URLs (`poche-staging.vercel.app`, `poche.vercel.app`)
3. **GitHub**: Repository URL if repo itself is renamed
4. **Apple Client ID**: `com.poche.app` in secrets docs

---

## Execution Order

1. Package.json files + turbo.json
2. TypeScript imports (bulk find/replace)
3. Docker + infrastructure
4. Environment files
5. Logo rename + UI components
6. CSS
7. Local storage keys
8. Documentation
9. Tests
10. Config files
11. Run `pnpm install` to update lockfile
12. Run tests to verify

---

## Verification

- [ ] `pnpm install` succeeds
- [ ] `pnpm build` succeeds
- [ ] `pnpm test` passes
- [ ] `pnpm type-check` passes
- [ ] Docker containers start with new names
- [ ] UI shows "Stache" branding
- [ ] No remaining "poche" references (grep check)

---

## Decisions Made

- ✅ **Logo**: New stache-logo.png will be provided
- ✅ **Tagline**: Blend pocket theme + mustache imagery
- ✅ **Test email**: Update to `test@stache.it.com`

## Remaining External Actions (post-implementation)

These are outside scope of this code rename:
1. **Convex**: May need new project or contact support for rename
2. **Vercel**: Update project URLs when ready
3. **GitHub**: Repo rename if desired
4. **Apple Client ID**: `com.poche.app` → `com.stache.app` in Apple Developer
