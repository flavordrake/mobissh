import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
    environment: 'node',
    // Coverage is an assessment tool, not a gate (#1152): only `vitest run
    // --coverage` (scripts/ts-coverage.sh) enables it. `include` lists every
    // source file so files no test imports still show up at 0% (the default
    // only reports files that were loaded); the lcov feeds lcov-summary.sh.
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/__tests__/**', 'src/**/*.test.ts'],
      reporter: ['text', 'lcov'],
      reportsDirectory: 'coverage',
    },
  },
});
