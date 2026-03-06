export interface ZanitizeInstance {
  /** Initialize with optional JSON SanitizerConfig. Returns true on success. */
  init(configJson?: string): boolean;
  /** Sanitize a full HTML string. Returns sanitized document or null. */
  sanitize(html: string): string | null;
  /** Sanitize an HTML fragment. Returns body content only, or null. */
  sanitizeFragment(html: string): string | null;
}

/** Load and initialize the zanitize WASM module. */
export function loadZanitize(wasmUrl: URL | string): Promise<ZanitizeInstance>;