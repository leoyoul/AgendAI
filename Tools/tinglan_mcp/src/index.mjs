#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.mjs";
import { createMcpServer, HandoffService } from "./server.mjs";

let service;
let server;

async function shutdown() {
  try {
    await server?.close();
  } finally {
    service?.close();
  }
}

process.on("SIGINT", () => shutdown().finally(() => process.exit(0)));
process.on("SIGTERM", () => shutdown().finally(() => process.exit(0)));

try {
  const config = loadConfig();
  service = new HandoffService(config);
  server = createMcpServer(service);
  await server.connect(new StdioServerTransport());
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  await shutdown().catch(() => {});
  process.exitCode = 1;
}
