import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { zodToJsonSchema } from "zod-to-json-schema";

import { schemaDefinitions } from "../src/schemas.mjs";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outputFlag = process.argv.indexOf("--output-dir");
const outputDir = outputFlag >= 0 ? path.resolve(process.argv[outputFlag + 1]) : path.join(projectRoot, "contracts");

if (outputFlag >= 0 && !process.argv[outputFlag + 1]) {
  throw new Error("--output-dir 需要目录参数");
}

await mkdir(outputDir, { recursive: true, mode: 0o700 });
for (const [fileName, schema] of Object.entries(schemaDefinitions)) {
  const jsonSchema = zodToJsonSchema(schema, {
    $refStrategy: "none",
    target: "jsonSchema7",
  });
  await writeFile(path.join(outputDir, fileName), `${JSON.stringify(jsonSchema, null, 2)}\n`, { mode: 0o600 });
}
