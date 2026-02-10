# OpenHarmony (ArkTS/OHOS) 开发规范与最佳实践

## 1. 核心上下文与技术栈
- **平台:** OpenHarmony (API 11+ / HarmonyOS NEXT).
- **语言:** ArkTS (基于 TypeScript 的定制语言，强制执行严格模式).
- **集成:** Flutter Plugin 插件开发 (`@ohos/flutter_ohos`).
- **范围:** 适用于 `ohos/` 插件目录及 `example/ohos/` 示例工程。

## 2. ArkTS 严格模式与类型系统 (API 11+)

### 类型定义与安全
- **禁止使用 `any` 和 `unknown`**：必须使用明确的类型声明。对于 JSON 或动态数据，优先使用 `ESObject` 或 `Record<string, ESObject>`。
- **强制类型断言**：在处理来自 `Want` 或外部对象的属性时，必须转换（如 `as ESObject`）。
- **禁止无类型的对象字面量 (arkts-no-untyped-obj-literals)**：
  - *错误示范*：`const config: ESObject = { transfer: { timeout: 1000 } };`（嵌套的字面量未对应显式类/接口）。
  - *正确示范*：分别定义各级接口对象，如 `const transfer: rcp.TransferConfiguration = { timeout: { ... } };`，再组合。
- **Definite Assignment Assertion (`!`) 限制**：尽量通过构造函数初始化。在 `.ets` 文件中，必须初始化的属性若不能立即赋值，需考虑可空类型。
- **静态布局**：禁止动态向对象添加/删除属性。所有属性必须在类或接口中声明。

### Concurrency & Sendable
- **Sendable 约束**：
  - 标记为 `@Sendable` 的类，其所有属性必须是基础类型、`collections.Map`、`collections.Array` 或其他 `@Sendable` 类。
  - **枚举 (Enum)** 不支持 `@Sendable` 装饰器，但枚举值本身可以安全地在多线程任务间传递。

## 3. Flutter 插件架构 (ArkTS 实现)

### 核心接口
实现自 `@ohos/flutter_ohos` 的标准接口：
- **`FlutterPlugin`**: 处理生命周期 (`onAttachedToEngine`, `onDetachedFromEngine`)。
- **`MethodCallHandler`**: 处理 MethodChannel 调用。
- **`AbilityAware`**: 获取 `UIAbilityContext`（必须在 `onAttachedToAbility` 中保存 context）。

### 常用导入 (Modular Imports)
- **REQUIRED:** 使用 `@kit.*` 模块化导入风格。
  - `@kit.AbilityKit` (含 `Want`, `common`)
  - `@kit.ArkTS` (含 `util`, `taskpool`)
  - `@kit.ArkData` (含 `preferences`)
  - `@kit.CoreFileKit` (含 `fileIo as fs`)
  - `@kit.RemoteCommunicationKit` (含 `rcp`)

## 4. 网络通信 (RCP Kit) 最佳实践

- **超时配置**：优先在 `request.configuration.transfer.timeout` 中设置，利用显式的 `TransferConfiguration` 接口避免字面量类型错误。
- **Session 管理**：`rcp.createSession()` 后的 session 使用完必须调用 `session.close()`。
- **代理与安全**：由于 RCP 版本差异，若 `HttpProxy` 或 `remoteVerification` 属性在当前 SDK 不可见，可使用 `ESObject` 强制映射或暂时通过扁平化配置规避。

## 5. 日志与调试规范

- **禁止 `console.log`**：无法进行日志分级和类别过滤。
- **必须使用 `console.info`, `console.warn`, `console.error`**。
- **TAG 规范**：第一个参数必须是类名或模块名定义的 `TAG` 字符串。
  - `console.info(TAG, "Task started");`

## 6. 系统交互与权限

- **打开文件**：使用 `context.startAbility` 发送 `Want`（Action: `ohos.want.action.viewData`）。URI 必须通过 `fileUri.getUriFromPath` 生成。
- **相册存储**：使用 `@kit.MediaLibraryKit` 的 `photoAccessHelper`，需申请 `ohos.permission.WRITE_IMAGEVIDEO` 权限。
- **持久化**：使用 `preferences` 存储配置。异步访问建议配合 `ArkTSUtils.locks.AsyncLock` 防止竞争。

## 7. 验证工作流 (Mandatory)
每次修改代码后，**必须**在 `example/ohos/` 目录下运行以下命令进行全量编译和 ArkTS 静态分析：

```bash
$TOOL_HOME/tools/node/bin/node $TOOL_HOME/tools/hvigor/bin/hvigorw.js --mode module -p product=default -p module=entry @default assembleHap --analyze=normal --parallel --incremental --daemon
```
*只有看到 "BUILD SUCCESSFUL" 才意味着代码符合 HarmonyOS NEXT 的上架/运行要求。*
