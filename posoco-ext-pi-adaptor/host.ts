import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export interface PiAdaptorModule {
  pi_adaptor_new(): unknown;
  pi_adaptor_set_cwd(adaptor: unknown, cwd: string): void;
  pi_adaptor_set_project_trusted(adaptor: unknown, trusted: boolean): void;
  pi_adaptor_set_ui_callbacks(
    adaptor: unknown,
    onRequest: (requestJson: string) => Promise<string>,
    onRender: (renderJson: string) => void,
  ): void;
  pi_adaptor_set_hidden_tools_json(adaptor: unknown, namesJson: string): void;
  pi_adaptor_load(adaptor: unknown, specifier: string): Promise<number>;
  pi_adaptor_catalog_json(adaptor: unknown): string;
  pi_adaptor_catalog_snapshot_json(adaptor: unknown): string;
  pi_adaptor_execute_json_async(
    adaptor: unknown,
    name: string,
    callId: string,
    argumentsJson: string,
  ): Promise<string>;
  pi_adaptor_execute_effect_json_async(
    adaptor: unknown,
    effectId: number,
    name: string,
    callId: string,
    argumentsJson: string,
  ): Promise<string>;
  pi_adaptor_execute_effect_via_runtime(
    adaptor: unknown,
    effectId: number,
    name: string,
    callId: string,
    argumentsJson: string,
    callback: (outcomeJson: string) => void,
  ): void;
  pi_adaptor_emit_event(adaptor: unknown, event: string, payloadJson: string): Promise<number>;
  pi_adaptor_seed_entry(adaptor: unknown, customType: string, dataJson: string): void;
  pi_adaptor_cancel_call(adaptor: unknown, callId: string): boolean;
  pi_adaptor_cancel_effects_json(adaptor: unknown, effectIdsJson: string, reasonJson: string): string;
  pi_adaptor_inflight_count(adaptor: unknown): number;
  pi_adaptor_event_names_json(adaptor: unknown): string;
  pi_adaptor_shortcuts_json(adaptor: unknown): string;
  pi_adaptor_commands_json(adaptor: unknown): string;
  pi_adaptor_invoke_command_json_async(
    adaptor: unknown,
    id: string,
    argsJson: string,
  ): Promise<string>;
  pi_adaptor_exec_json_async(
    adaptor: unknown,
    command: string,
    argsJson: string,
    optionsJson: string,
  ): Promise<string>;
  pi_adaptor_entries_json(adaptor: unknown): string;
  pi_adaptor_messages_json(adaptor: unknown): string;
  pi_adaptor_updates_json(adaptor: unknown): string;
  pi_adaptor_take_updates_json(adaptor: unknown): string;
  pi_adaptor_take_followups_json(adaptor: unknown): string;
  pi_adaptor_set_custom_entry_callback(
    adaptor: unknown,
    callback: (customType: string, dataJson: string) => void,
  ): void;
  pi_adaptor_take_custom_entries_json(adaptor: unknown): string;
}

export interface LoadedPiPackage {
  name: string;
  version: string;
  root: string;
  extensions: string[];
  registeredTools: number;
}

/**
 * Host UI bridge for ExtensionContext.ui: `request` receives a UiPort
 * ui_request JSON string and resolves to the correlated ui_response JSON
 * string; `render` receives a ui_render JSON string. Wire shapes match the
 * cetas-js JsUiPort protocol. Absent callbacks keep the headless no-op ui.
 */
export interface PiUiCallbacks {
  request: (requestJson: string) => Promise<string>;
  render: (renderJson: string) => void;
}

export class PiPackageHost {
  readonly adaptor: unknown;
  readonly cwd: string;
  readonly module: PiAdaptorModule;

  constructor(
    module: PiAdaptorModule,
    options: { cwd?: string; projectTrusted?: boolean; ui?: PiUiCallbacks } = {},
  ) {
    this.module = module;
    this.cwd = resolve(options.cwd ?? process.cwd());
    this.adaptor = module.pi_adaptor_new();
    module.pi_adaptor_set_cwd(this.adaptor, this.cwd);
    module.pi_adaptor_set_project_trusted(this.adaptor, options.projectTrusted ?? false);
    if (options.ui) this.setUiCallbacks(options.ui);
  }

  /** Install (or, with undefined, keep absent) the ExtensionContext.ui bridge. */
  setUiCallbacks(ui: PiUiCallbacks): void {
    this.module.pi_adaptor_set_ui_callbacks(this.adaptor, ui.request, ui.render);
  }

  static async fromModuleUrl(
    moduleUrl: string | URL,
    options: { cwd?: string; projectTrusted?: boolean } = {},
  ): Promise<PiPackageHost> {
    const module = await import(String(moduleUrl)) as PiAdaptorModule;
    return new PiPackageHost(module, options);
  }

  async loadPackage(specifier: string): Promise<LoadedPiPackage> {
    const root = await resolvePackageRoot(specifier, this.cwd);
    const packageJsonPath = join(root, "package.json");
    const manifest = JSON.parse(await readFile(packageJsonPath, "utf8")) as {
      name?: string;
      version?: string;
      pi?: { extensions?: unknown };
    };
    const extensions = manifest.pi?.extensions;
    if (!Array.isArray(extensions) || extensions.length === 0 || extensions.some((v) => typeof v !== "string")) {
      throw new Error(`Pi package '${specifier}' has no valid package.json.pi.extensions array`);
    }

    let registeredTools = this.catalog().length;
    for (const entry of extensions as string[]) {
      const entryUrl = pathToFileURL(resolve(root, entry)).href;
      registeredTools = await this.module.pi_adaptor_load(this.adaptor, entryUrl);
    }
    return {
      name: manifest.name ?? specifier,
      version: manifest.version ?? "0.0.0",
      root,
      extensions: [...extensions] as string[],
      registeredTools,
    };
  }

  catalog(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_catalog_json(this.adaptor));
  }

  catalogSnapshot(): { version: number; tools: Array<Record<string, unknown>> } {
    return JSON.parse(this.module.pi_adaptor_catalog_snapshot_json(this.adaptor));
  }

  async execute(name: string, callId: string, args: unknown): Promise<Record<string, unknown>> {
    return JSON.parse(await this.module.pi_adaptor_execute_json_async(
      this.adaptor,
      name,
      callId,
      JSON.stringify(args ?? {}),
    ));
  }

  async executeEffect(
    effectId: number,
    name: string,
    callId: string,
    args: unknown,
  ): Promise<Record<string, unknown>> {
    return JSON.parse(await this.module.pi_adaptor_execute_effect_json_async(
      this.adaptor,
      effectId,
      name,
      callId,
      JSON.stringify(args ?? {}),
    ));
  }

  emit(event: string, payload: unknown = {}): Promise<number> {
    return this.module.pi_adaptor_emit_event(this.adaptor, event, JSON.stringify(payload));
  }

  startSession(payload: unknown = {}): Promise<number> {
    return this.emit("session_start", payload);
  }

  seedEntry(customType: string, data: unknown): void {
    this.module.pi_adaptor_seed_entry(this.adaptor, customType, JSON.stringify(data));
  }

  cancel(callId: string): boolean {
    return this.module.pi_adaptor_cancel_call(this.adaptor, callId);
  }

  cancelEffects(effectIds: number[], reason: unknown): Array<{ effectId: number; disposition: string }> {
    return JSON.parse(this.module.pi_adaptor_cancel_effects_json(
      this.adaptor,
      JSON.stringify(effectIds),
      JSON.stringify(reason ?? null),
    ));
  }

  inflightCount(): number {
    return this.module.pi_adaptor_inflight_count(this.adaptor);
  }

  eventNames(): string[] {
    return JSON.parse(this.module.pi_adaptor_event_names_json(this.adaptor));
  }

  shortcuts(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_shortcuts_json(this.adaptor));
  }

  commands(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_commands_json(this.adaptor));
  }

  async invokeCommand(id: string, args: unknown = {}): Promise<Record<string, unknown>> {
    return JSON.parse(await this.module.pi_adaptor_invoke_command_json_async(
      this.adaptor,
      id,
      JSON.stringify(args ?? {}),
    ));
  }

  async exec(
    command: string,
    args: string[] = [],
    options: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    return JSON.parse(await this.module.pi_adaptor_exec_json_async(
      this.adaptor,
      command,
      JSON.stringify(args),
      JSON.stringify(options),
    ));
  }

  entries(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_entries_json(this.adaptor));
  }

  messages(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_messages_json(this.adaptor));
  }

  updates(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_updates_json(this.adaptor));
  }

  takeUpdates(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_take_updates_json(this.adaptor));
  }

  takeFollowUps(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_take_followups_json(this.adaptor));
  }

  /** Install the callback fired on every pi appendEntry: (customType, dataJson). */
  onCustomEntry(callback: (customType: string, dataJson: string) => void): void {
    this.module.pi_adaptor_set_custom_entry_callback(this.adaptor, callback);
  }

  /** Drain custom entries appended since the last drain (never seeded ones). */
  takeCustomEntries(): Array<Record<string, unknown>> {
    return JSON.parse(this.module.pi_adaptor_take_custom_entries_json(this.adaptor));
  }
}

async function resolvePackageRoot(specifier: string, cwd: string): Promise<string> {
  if (specifier.startsWith("file:")) {
    return dirname(fileURLToPath(new URL("package.json", specifier.endsWith("/") ? specifier : `${specifier}/`)));
  }
  if (isAbsolute(specifier) || specifier.startsWith("./") || specifier.startsWith("../")) {
    return resolve(cwd, specifier);
  }

  const require = createRequire(pathToFileURL(join(cwd, "__posoco_pi_host__.mjs")));
  try {
    return dirname(require.resolve(`${specifier}/package.json`));
  } catch (packageJsonError) {
    try {
      let current = dirname(require.resolve(specifier));
      for (;;) {
        try {
          await readFile(join(current, "package.json"), "utf8");
          return current;
        } catch {
          const parent = dirname(current);
          if (parent === current) throw packageJsonError;
          current = parent;
        }
      }
    } catch {
      throw new Error(`Cannot resolve Pi package '${specifier}' from '${cwd}'`, { cause: packageJsonError });
    }
  }
}
