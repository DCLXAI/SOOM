export interface ProcessCLIArguments {
  command: "process";
  sessionPath: string;
  exportPath: string;
}

const allowedFlags = new Set(["--session", "--export"]);

export function parseCLIArguments(arguments_: string[]): ProcessCLIArguments {
  if (arguments_[0] !== "process") {
    throw new Error("Usage: soom-worker process --session <path> --export <path>");
  }

  const values = new Map<string, string>();
  for (let index = 1; index < arguments_.length; index += 2) {
    const flag = arguments_[index];
    const value = arguments_[index + 1];
    if (!flag || !allowedFlags.has(flag)) throw new Error(`Unknown CLI flag: ${flag ?? "<missing>"}`);
    if (values.has(flag)) throw new Error(`Duplicate CLI flag: ${flag}`);
    if (!value || value.startsWith("--") || value.includes("\0")) {
      throw new Error(`Missing or invalid value for ${flag}`);
    }
    values.set(flag, value);
  }

  if (arguments_.length !== 5 || !values.has("--session") || !values.has("--export")) {
    throw new Error("Both --session and --export are required and no other flags are accepted");
  }
  return {
    command: "process",
    sessionPath: values.get("--session")!,
    exportPath: values.get("--export")!,
  };
}
