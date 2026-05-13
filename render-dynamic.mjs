import fs from "node:fs";
import path from "node:path";

const [srcDir, outDir] = process.argv.slice(2);

if (!srcDir || !outDir) {
  console.error("usage: node /render-dynamic.mjs <src-dir> <out-dir>");
  process.exit(1);
}

if (!fs.existsSync(srcDir)) {
  console.error(`dynamic config folder not found: ${srcDir}`);
  process.exit(1);
}

const missing = new Set();

function renderText(text, filePath) {
  return text.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, name) => {
    if (process.env[name] === undefined) {
      missing.add(`${name} in ${filePath}`);
      return match;
    }

    return process.env[name];
  });
}

function copyRendered(src, dest) {
  const stat = fs.statSync(src);

  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src)) {
      copyRendered(path.join(src, entry), path.join(dest, entry));
    }
    return;
  }

  const content = fs.readFileSync(src, "utf8");
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, renderText(content, src));
}

fs.rmSync(outDir, { recursive: true, force: true });
copyRendered(srcDir, outDir);

if (missing.size > 0) {
  console.error("missing .env variables:");
  for (const item of missing) {
    console.error(`- ${item}`);
  }
  process.exit(1);
}

console.log(`rendered ${srcDir} to ${outDir}`);
