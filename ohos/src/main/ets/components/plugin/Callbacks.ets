import { FlutterCallbackInformation, FlutterEngine, MethodChannel, MethodResult } from '@ohos/flutter_ohos'
import { ArkTSUtils } from '@kit.ArkTS'
import { common } from '@kit.AbilityKit'
import { Task, TaskStatusUpdate } from './Models'
import { preferences } from '@kit.ArkData';
import BDPlugin from './BDPlugin';

export interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: string) => void;
}

export function createDeferred<T>(): Deferred<T> {
  let resolveFunc: (value: T | PromiseLike<T>) => void = () => {};
  let rejectFunc: (reason?: string) => void = () => {};
  const promise = new Promise<T>((res, rej) => {
    resolveFunc = res;
    rejectFunc = rej;
  });
  return { promise, resolve: resolveFunc, reject: rejectFunc };
}

function FlutterResultHandlerArkTS(completer: Deferred<string | undefined>): MethodResult {
  return {
    // When Flutter call is successful
    success: (result?: Object) => {
      try {
        // If a JSON string is returned, it can be resolved directly
        completer.resolve(result !== undefined ? result as string : undefined);
      } catch (e) {
        // Prevent duplicate resolve errors
        console.error("resolve error:", e);
      }
    },
    // When Flutter call fails
    error: (errorCode: string, errorMessage?: string, details?: Object) => {
      try {
        // Depending on your needs, strict mode can reject, and lenient mode can resolve(null)
        completer.reject(`${errorCode}: ${errorMessage ?? ''}`);
      } catch (e) {
        console.error("reject error:", e);
      }
    },
    // Not implemented on the Flutter side
    notImplemented: () => {
      try {
        completer.reject("Method not implemented on Dart side");
      } catch (e) {
        console.error("reject error:", e);
      }
    }
  };
}

export class Callbacks {
  static readonly TAG = "Callbacks"
  private static callbackMethodChannel?: MethodChannel
  private static methodChannelMutex: ArkTSUtils.locks.AsyncLock

  /**
   * Retrieves the [MethodChannel] used for communication with the Flutter background isolate.
   *
   * This method initializes the `MethodChannel` if it hasn't been created yet. It does so by:
   * 1. Obtaining the `callbackDispatcherRawHandle` from shared preferences.
   * 2. Creating a new [FlutterEngine] and executing the Dart callback dispatcher.
   * 3. Creating a [MethodChannel] using the engine's binary messenger.
   *
   * The initialization process happens on the UI thread to avoid potential issues.
   *
   * This method is thread-safe due to the use of a mutex.
   *
   * @param context The [Context] required for accessing resources and the UI thread.
   * @return The [MethodChannel] instance, or `null` if initialization fails.
   */
  private static async getMethodChannel(context: common.UIAbilityContext): Promise<MethodChannel | undefined> {
    const result = await Callbacks.methodChannelMutex.lockAsync<MethodChannel | undefined>(async () => {
      if (Callbacks.callbackMethodChannel === undefined) {
        let methodChannelCompleter = createDeferred<MethodChannel | undefined>();
        new Promise<void>((resolve, reject) => {
          try {
            let options: preferences.Options = { name: 'DEFAULT' };
            let prefs = preferences.getPreferencesSync(context, options);
            let rawHandle =
              prefs.getSync(BDPlugin.KEY_CALLBACK_DISPATCHER_RAW_HANDLE, -1) as number;
            if (rawHandle === -1) {
              console.warn(
                Callbacks.TAG,
                "getMethodChannel without registered callbackDispatcherRawHandle"
              )
              return;
            }

            let flutterEngine = new FlutterEngine(context, null, null, null)
            let callbackDispatcherCallback = FlutterCallbackInformation.lookupCallbackInformation(rawHandle);

            if (callbackDispatcherCallback === null) {
              console.warn(
                Callbacks.TAG,
                "invokeOnStartCallback failed to find callbackDispatcher"
              )
              return;
            }
            Callbacks.callbackMethodChannel = new MethodChannel(
              flutterEngine.dartExecutor.getBinaryMessenger(),
              "com.bbflight.background_downloader.callbacks"
            )
            methodChannelCompleter.resolve(Callbacks.callbackMethodChannel);
          } catch (e) {
            console.error(Callbacks.TAG, "Error creating MethodChannel", e)
            methodChannelCompleter.resolve(undefined);
          }

          return methodChannelCompleter.promise;

          // The code here executes on the main thread - equivalent to Android's Handler(Looper.getMainLooper()).post { ... }
        });
      }

      return Callbacks.callbackMethodChannel;

      // Execute some operations
    });

    return result;
  }

  private static async invokeCallback(context: common.UIAbilityContext,
    methodName: string,
    task?: Task,
    statusUpdate?: TaskStatusUpdate,
  ): Promise<Task | TaskStatusUpdate | undefined> {
    let methodChannel = await Callbacks.getMethodChannel(context);
    if (methodChannel === undefined) {
      return;
    }
    return Callbacks.methodChannelMutex.lockAsync<ESObject>(async () => {
      let resultingObjectAsJsonStringCompleter = createDeferred<string | undefined>();
      new Promise<void>((_resolve) => {
        let arg = task !== undefined ? JSON.stringify(task) : JSON.stringify(statusUpdate);
        console.info(Callbacks.TAG, "Invoking" + methodName + " for taskId " + task?.taskId);
        methodChannel!.invokeMethod(
          methodName,
          arg, // either task or update
          FlutterResultHandlerArkTS(resultingObjectAsJsonStringCompleter)
        )

      });

      let objectAsJsonString = await resultingObjectAsJsonStringCompleter.promise;
      return (objectAsJsonString === undefined) ? undefined :
        (methodName == "beforeTaskStartCallback" ? TaskStatusUpdate.fromObject(JSON.parse(objectAsJsonString) as ESObject) :
        Task.fromObject(JSON.parse(objectAsJsonString) as ESObject))

    });

  }

  /**
   * Invoke the beforeTaskStartCallback and return the result
   */
  public static async invokeBeforeTaskStartCallback(context: common.UIAbilityContext,
    task: Task): Promise<TaskStatusUpdate | undefined> {
    try {
      const statusUpdate = await Callbacks.invokeCallback(
        context,
        "beforeTaskStartCallback",
        task
      );
      return (statusUpdate instanceof TaskStatusUpdate) ? statusUpdate : undefined;
    } catch (e) {
      console.error(Callbacks.TAG, "Error in invokeBeforeTaskStartCallback", e);
    }
    return undefined;
  }

  /**
   * Invoke the onTaskStartCallback and return the result
   */
  public static async invokeOnTaskStartCallback(context: common.UIAbilityContext,
    task: Task): Promise<Task | undefined> {
    try {
      const taskResult = await Callbacks.invokeCallback(context, "onTaskStartCallback", task);
      return (taskResult instanceof Task) ? taskResult : undefined;
    } catch (e) {
      console.error(Callbacks.TAG, "Error in invokeOnTaskStartCallback", e);
    }
    return undefined;
  }

  /**
   * Invoke the invokeOnAuthCallback and return the result
   */
  public static async invokeOnAuthCallback(context: common.UIAbilityContext, task: Task): Promise<Task | undefined> {
    try {
      const taskResult = await Callbacks.invokeCallback(context, "onAuthCallback", task);
      return (taskResult instanceof Task) ? taskResult : undefined;
    } catch (e) {
      console.error(Callbacks.TAG, "Error in invokeOnAuthCallback", e);
    }
    return undefined;
  }

  /**
   * Invoke the onTaskFinishedCallback
   */
  public static async invokeOnTaskFinishedCallback(context: common.UIAbilityContext, statusUpdate: TaskStatusUpdate) {
    try {
      Callbacks.invokeCallback(
        context,
        "onTaskFinishedCallback",
        undefined,
        statusUpdate
      ) //as Task?
    } catch (e) {
      console.error(Callbacks.TAG, "Error in invokeOnTaskFinishedCallback", e)
    }
  }
}
