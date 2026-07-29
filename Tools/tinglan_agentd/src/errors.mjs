export class AgentError extends Error {
  constructor(code, message, { status = 400, details = [], cause } = {}) {
    super(message, { cause });
    this.name = "AgentError";
    this.code = code;
    this.status = status;
    this.details = details;
  }
}
