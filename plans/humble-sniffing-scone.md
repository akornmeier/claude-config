# Storybook 10 Setup for @oculis/browser

## Goal
Set up Storybook 10.1.x with `@storybook/vue3-vite` for Vue 3 component development and interaction testing in the browser extension package.

## Prerequisites
- Node.js 20+ (Storybook 10 is ESM-only)
- Vue 3.5.25, Vite 7.2.7, Tailwind CSS 4.1.18 (already installed)

---

## Implementation Steps

### Step 1: Install Dependencies

**File**: `packages/browser/package.json`

Add devDependencies:
```bash
pnpm --filter @oculis/browser add -D storybook@~10.1.0 @storybook/vue3-vite@~10.1.0 @storybook/addon-essentials@~10.1.0 @storybook/addon-interactions@~10.1.0 @storybook/test@~10.1.0
```

---

### Step 2: Create Storybook Configuration

**File**: `packages/browser/.storybook/main.ts` (NEW)

```typescript
import type { StorybookConfig } from '@storybook/vue3-vite';
import { resolve } from 'node:path';

const config: StorybookConfig = {
  stories: ['../src/**/*.stories.@(js|jsx|mjs|ts|tsx)'],
  addons: [
    '@storybook/addon-essentials',
    '@storybook/addon-interactions',
  ],
  framework: {
    name: '@storybook/vue3-vite',
    options: {
      docgen: 'vue-component-meta',
    },
  },
  async viteFinal(config) {
    const { mergeConfig } = await import('vite');
    return mergeConfig(config, {
      resolve: {
        alias: { '@': resolve(__dirname, '../src') },
      },
    });
  },
};

export default config;
```

---

### Step 3: Create Preview Configuration

**File**: `packages/browser/.storybook/preview.ts` (NEW)

- Import `main.css` for Tailwind CSS 4 + design tokens
- Setup Pinia globally for store-dependent components
- Add theme switcher toolbar (dark/light)
- Configure backgrounds matching Oculis design system
- Wrap stories with `data-theme` decorator

---

### Step 4: Create OculisPill Story

**File**: `packages/browser/src/components/OculisPill.stories.ts` (NEW)

Stories:
- `Default` - Standard state
- `Hovered` - With hover interaction test
- `Focused` - With focus interaction test
- `Clicked` - With click interaction test
- `LightTheme` - Light mode variant

---

### Step 5: Create OculisProvider Story

**File**: `packages/browser/src/components/OculisProvider.stories.ts` (NEW)

Stories:
- `Dark` - Default dark theme
- `Light` - Light theme variant
- `System` - System preference mode

Include sample content demonstrating severity badges and typography.

---

### Step 6: Add npm Scripts

**File**: `packages/browser/package.json`

```json
{
  "scripts": {
    "storybook": "storybook dev -p 6006",
    "storybook:build": "storybook build -o storybook-static"
  }
}
```

---

### Step 7: Configure Turborepo

**File**: `turbo.json`

Add tasks:
```json
{
  "storybook": { "cache": false, "persistent": true },
  "storybook:build": { "dependsOn": ["^build"], "outputs": ["storybook-static/**"] }
}
```

---

### Step 8: Update TypeScript Config

**File**: `packages/browser/tsconfig.json`

Add to `include`:
- `src/**/*.stories.ts`
- `.storybook/**/*.ts`

---

### Step 9: Add .gitignore Entry

**File**: `packages/browser/.gitignore` (create if needed)

```
storybook-static/
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `packages/browser/package.json` | Modify (add deps + scripts) |
| `packages/browser/.storybook/main.ts` | Create |
| `packages/browser/.storybook/preview.ts` | Create |
| `packages/browser/src/components/OculisPill.stories.ts` | Create |
| `packages/browser/src/components/OculisProvider.stories.ts` | Create |
| `packages/browser/tsconfig.json` | Modify (add includes) |
| `packages/browser/.gitignore` | Create/Modify |
| `turbo.json` | Modify (add tasks) |

---

## Verification

1. Run `pnpm --filter @oculis/browser storybook`
2. Verify Tailwind CSS 4 styles render correctly
3. Test theme switcher in toolbar
4. Check Interactions panel for each story
5. Run `pnpm --filter @oculis/browser storybook:build`
