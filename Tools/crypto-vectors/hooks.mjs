// Module hooks that let Node import Signal-Desktop's TypeScript sources unmodified:
//   * bare specifiers that Signal-Desktop cannot resolve (it has no node_modules here)
//     resolve from this directory's node_modules;
//   * .ts files are transpiled with esbuild (Desktop uses enums, which Node's type
//     stripping rejects).
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { transform } from 'esbuild';

const here = new URL('./index.mjs', import.meta.url).href;

const compiledProtos = new URL('./generated/compiled.std.js', import.meta.url).href;

export async function resolve(specifier, context, next) {
  // Desktop generates this file at build time (pnpm run build:protobuf); ours is built
  // from the same .proto files by generate.sh.
  if (specifier.endsWith('/compiled.std.js') && context.parentURL?.includes('/ts/protobuf/')) {
    return { url: compiledProtos, shortCircuit: true };
  }
  try {
    return await next(specifier, context);
  } catch (error) {
    if (/^[@a-zA-Z]/.test(specifier) && !specifier.startsWith('node:')) {
      try {
        return await next(specifier, { ...context, parentURL: here });
      } catch (inner) {
        // Desktop's bundler tolerates extensionless deep imports.
        if (inner.code === 'ERR_MODULE_NOT_FOUND' && specifier.includes('/dist/')) {
          return next(`${specifier}.js`, { ...context, parentURL: here });
        }
        throw inner;
      }
    }
    throw error;
  }
}

export async function load(url, context, next) {
  if (url.startsWith('file:') && /\.tsx?$/.test(url)) {
    const source = await readFile(fileURLToPath(url), 'utf8');
    const { code } = await transform(source, { loader: url.endsWith('x') ? 'tsx' : 'ts', jsx: 'automatic', format: 'esm', target: 'node22', sourcefile: fileURLToPath(url) });
    return { format: 'module', source: code, shortCircuit: true };
  }
  return next(url, context);
}
