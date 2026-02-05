# OpenHarmony (ohos) Development Rules

## 1. Context & Tech Stack
- **Platform:** OpenHarmony (API 11+ / HarmonyOS NEXT).
- **Language:** ArkTS (TypeScript tailored for OpenHarmony).
- **Integration:** Flutter Plugin development (`@ohos/flutter_ohos`).
- **Scope:** These rules apply to both the plugin code in `ohos/` and the example app in `example/ohos/`.
- **Imports:** Use the modern Modular Imports (`@kit.*`) style (e.g., `@kit.AbilityKit`, `@kit.ArkTS`).

## 2. Code Style & Conventions
- **Naming:** Use `PascalCase` for classes/components, `camelCase` for methods/variables, and `UPPER_SNAKE_CASE` for constants.
- **Typing:** Strict typing is required. Avoid `any`. Use explicit interfaces for JSON parsing/serialization.
- **Async/Await:** Prefer `async/await` over raw Promises for readability.
- **Null Safety:** Use strict null checks. Handle `undefined` and `null` explicitly using optional chaining (`?.`) or nullish coalescing (`??`).
- **Strict Equality:** Always use `===` and `!==` instead of `==` and `!=`.
- **Logging:** 
  - **FORBIDDEN:** `console.log` (lacks log level and categorization).
  - **REQUIRED:** Use `console.info`, `console.warn`, or `console.error`.
  - **TAG:** Always include a consistent `TAG` as the first argument.
  - *Example:* `console.info(TAG, "Task started");`

## 3. Flutter Plugin Architecture
Implement the standard interfaces from `@ohos/flutter_ohos`:
- **`FlutterPlugin`:** For plugin lifecycle (`onAttachedToEngine`, `onDetachedFromEngine`).
- **`MethodCallHandler`:** For handling method channel calls (`onMethodCall`).
- **`AbilityAware`:** For access to `UIAbilityContext` (`onAttachedToAbility`, `onDetachedFromAbility`).

### Example Structure
```typescript
import { 
  FlutterPlugin, 
  FlutterPluginBinding, 
  MethodCall, 
  MethodCallHandler, 
  MethodChannel,
  MethodResult,
  AbilityAware,
  AbilityPluginBinding
} from "@ohos/flutter_ohos";
import { common } from "@kit.AbilityKit";

export default class MyPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel?: MethodChannel;
  private context?: common.UIAbilityContext;

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "com.example/channel_name");
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.context = undefined;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    // Handle methods
  }
}
```

## 4. Specific OHOS Capabilities

### Imports (Modernization)
- **FORBIDDEN:** Legacy `@ohos.*` imports.
- **REQUIRED:** Modern `@kit.*` imports.
  - `@ohos.file.fs` -> `@kit.CoreFileKit` (import `{ fileIo as fs }`)
  - `@ohos.app.ability.Want` -> `@kit.AbilityKit` (import `{ Want }`)
  - `@ohos.data.preferences` -> `@kit.ArkData` (import `{ preferences }`)
  - `@ohos.util` -> `@kit.ArkTS` (import `{ util }`)

### Data Persistence
- Use `@kit.ArkData.preferences` for key-value storage.
- **CRITICAL:** Use `ArkTSUtils.locks.AsyncLock` when accessing Preferences from multiple threads or async contexts to prevent data races.

### Concurrency
- Use `@kit.ArkTS.taskpool` for CPU-intensive tasks.
- Avoid blocking the main UI thread.

### Logging
- Use standard `console` with a consistent `TAG`.
- Example: `console.info(TAG, "Message");`, `console.error(TAG, "Error: " + error);`

## 5. Common Pitfalls to Avoid
1.  **Context Loss:** Always check if `this.context` (UIAbilityContext) is valid before using it. Return a clear error code (e.g., `NO_CONTEXT`) to Flutter if it's missing.
2.  **MethodResult Handling:** Ensure `result.success()`, `result.error()`, or `result.notImplemented()` is called **exactly once** for every method call.
3.  **JSON Marshaling:** When passing complex objects between Flutter and OHOS, prefer passing JSON strings and parsing them in ArkTS to ensure type safety on both ends.

## 6. Directory Structure
- **`src/main/ets/components/plugin/`**: Logic files.
- **`oh-package.json5`**: Dependencies.
- **`build-profile.json5`**: Build configuration.

## 7. ArkTS (.ets) vs TypeScript (.ts)
- **File Extensions:**
  - **`.ets` (ArkTS):** The primary file type for OpenHarmony/HarmonyOS applications. It supports the ArkUI declarative syntax (e.g., `struct`, `@Component`, `build()`) and enforces "ArkTS Strict" rules. **Use `.ets` for all source code in `src/main/ets`**, including logic-only classes.
  - **`.ts` (TypeScript):** Typically used for build scripts (e.g., `hvigorfile.ts`) or legacy logic.

- **ArkTS Strictness (applied in `.ets`):**
  - **No `any`:** The `any` type is strictly prohibited. Use explicit types, generics, or `Object` (if absolutely necessary and safe).
  - **Static Layout:** Objects cannot be modified dynamically at runtime. You cannot add or remove properties from an object after it is created. All properties must be declared in the class or interface.
    ```typescript
    // BAD (Valid TS, Invalid ArkTS)
    let obj = {};
    obj.name = "Test"; 
    
    // GOOD
    class MyObj {
      name: string = "";
    }
    let obj = new MyObj();
    obj.name = "Test";
    ```
  - **Structural Typing:** ArkTS relies more on nominal typing for classes compared to TypeScript's structural typing.

- **UI Syntax (ArkUI in `.ets`):**
  - **Structs:** UI components are defined as `struct`, not `class`.
  - **Decorators:** Extensive use of decorators for state management:
    - `@State`: Component-internal mutable state.
    - `@Prop`: One-way sync from parent.
    - `@Link`: Two-way sync with parent.
    - `@Builder`: For declarative UI construction functions.

## 8. Verification Workflow (Mandatory)
After every code modification in the `ohos/` directory, you **MUST** verify the build to ensure no ArkTS/TS errors were introduced.

**Verification Command (Run from 'example/ohos/' directory):**

```bash
$TOOL_HOME/tools/node/bin/node $TOOL_HOME/tools/hvigor/bin/hvigorw.js --mode module -p product=default -p module=entry @default assembleHap --analyze=normal --parallel --incremental --daemon
```

*Note: This command performs full compilation and ArkTS static analysis. A "BUILD SUCCESSFUL" result ensures the code adheres to strict HarmonyOS NEXT requirements.*
