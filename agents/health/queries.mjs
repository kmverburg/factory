// Prints every read-only GraphQL query (not mutations) that the relay and the agents send to Linear, as JSON:
// [{file, query, variables: [{name, type}]}]. Used by the health check to run each one against the real API.
// Usage: node agents/health/queries.mjs [repo root]
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = process.argv[2] || process.cwd();
const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    if (name === "node_modules" || name === "fixtures") return [];
    return statSync(p).isDirectory() ? walk(p) : [p];
  });

const found = [];
const add = (file, query) => {
  const clean = query.replace(/\s+/g, " ").trim();
  const header = clean.match(/^query\s*\w*\s*(\(([^)]*)\))?/);
  const variables = [...(header?.[2] ?? "").matchAll(/\$(\w+)\s*:\s*([\w\[\]!]+)/g)].map((m) => ({ name: m[1], type: m[2] }));
  found.push({ file: relative(root, file), query: clean, variables });
};
for (const file of [...walk(join(root, "relay/src")), ...walk(join(root, "agents"))]) {
  const text = readFileSync(file, "utf8");
  if (file.endsWith(".ts")) for (const m of text.matchAll(/`\s*(query\b[^`]*)`/g)) add(file, m[1]);
  if (file.endsWith(".sh")) for (const m of text.matchAll(/linear_gql\s+'(query\b[^']*)'/g)) add(file, m[1]);
}
console.log(JSON.stringify(found));
