import Ajv2020 from "ajv/dist/2020.js";
import taskSpecSchema from "../../schemas/TaskSpec.v1.json";
import type { TaskSpec } from "./types";

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validate = ajv.compile<TaskSpec>(taskSpecSchema);

export { taskSpecSchema };

export function validateTaskSpec(value: unknown): asserts value is TaskSpec {
  if (!validate(value)) {
    const message = ajv.errorsText(validate.errors, { separator: "; " });
    throw new Error(`TaskSpec schema validation failed: ${message}`);
  }
}
