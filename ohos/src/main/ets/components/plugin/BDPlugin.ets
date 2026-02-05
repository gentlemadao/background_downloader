import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityAware,
  AbilityPluginBinding,
  FlutterEngine,
  BinaryMessenger
} from "@ohos/flutter_ohos";
import {
  common, Want, WantAgent, wantAgent,
} from "@kit.AbilityKit";

import { ArkTSUtils, List, taskpool } from "@kit.ArkTS";
import { preferences } from "@kit.ArkData";
import TransferManager from './TransferManager';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError as BusinessAbilityError } from '@kit.BasicServicesKit';

import { HoldingQueue } from './HoldingQueue';
import { ResumeData, Task, RequireWiFi } from './Models';
import { enqueueAllTask } from './EnqueueAllTask';

import { BusinessError } from "@kit.BasicServicesKit";
import { getTaskMap } from "./TaskWorker";
import { NotificationService } from "./Notifications";
import { PermissionsService, PermissionType } from './PermissionsService';
import { QueueService } from "./QueueService";


export default class BDPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  public static readonly TAG = 'BackgroundDownloader'
  public static readonly KEY_TASKS_MAP = 'com.bbflight.background_downloader.taskMap.v2'
  public static readonly KEY_RESUME_DATA_MAP = 'com.bbflight.background_downloader.resumeDataMap.v2'
  public static readonly KEY_STATUS_UPDATE_MAP = 'com.bbflight.background_downloader.statusUpdateMap.v2'
  public static readonly KEY_PROGRESS_UPDATE_MAP = 'com.bbflight.background_downloader.progressUpdateMap.v2'
  public static readonly KEY_REQUIRE_WIFI =
    'com.bbflight.background_downloader.requireWifi'
  public static readonly KEY_CALLBACK_DISPATCHER_RAW_HANDLE =
    'com.bbflight.background_downloader.callbackDispatcherRawHandle'
  public static readonly KEY_CONFIG_FOREGROUND_FILE_SIZE =
    'com.bbflight.background_downloader.config.foregroundFileSize'
  public static readonly KEY_CONFIG_PROXY_ADDRESS = 'com.bbflight.background_downloader.config.proxyAddress'
  public static readonly KEY_CONFIG_PROXY_PORT = 'com.bbflight.background_downloader.config.proxyPort'
  public static readonly KEY_CONFIG_REQUEST_TIMEOUT =
    'com.bbflight.background_downloader.config.requestTimeout'
  public static readonly KEY_CONFIG_CHECK_AVAILABLE_SPACE =
    'com.bbflight.background_downloader.config.checkAvailableSpace'
  public static readonly KEY_CONFIG_USE_CACHE_DIR = 'com.bbflight.background_downloader.config.useCacheDir'
  public static readonly KEY_CONFIG_USE_EXTERNAL_STORAGE =
    'com.bbflight.background_downloader.config.useExternalStorage'
  public static notificationButtonText = new Map<string, string>()
  public static firstBackgroundChannel?: MethodChannel;
  public static bgChannelByTaskId = new Map<string, MethodChannel>()
  public static flutterEngineByTaskId = new Map<string, FlutterEngine>();
  public static requireWifi = RequireWiFi.AS_SET_BY_TASK
  public static localResumeData = new Map<string, ResumeData>()
  public static cancelUpdateSentForTaskId = new Map<string, number>()
  public static pausedTaskIds = new Set<String>()
  public static canceledTaskIds = new Set<String>()
  public static tasksToReEnqueue = new Set<Task>()
  public static taskIdsRequiringWiFi = new Set<string>()
  public static notificationConfigJsonStrings = new Map<string, string>()
  public static forceFailPostOnBackgroundChannel = false
  public static prefsLock = new ArkTSUtils.locks.AsyncLock()
  public static remainingBytesToDownload = new Map<string, number>()
  public static haveLoggedProxyMessage = false
  public static holdingQueue?: HoldingQueue

  static async doEnqueue(
    context: common.UIAbilityContext,
    task: Task,
    notificationConfigJsonString?: string,
    resumeData?: ResumeData,
    initialDelayMillis: number = 0,
    plugin?: BDPlugin
  ): Promise<boolean> {

    console.info(BDPlugin.TAG, `Enqueuing task with id ${task.taskId}`);
    const bgChannel = BDPlugin.methodBackgroundChannel(plugin);
    if (bgChannel) {
      BDPlugin.bgChannelByTaskId.set(task.taskId, bgChannel);
    } else {
      console.warn(BDPlugin.TAG, `Could not find backgroundChannel for taskId ${task.taskId}`);
    }
    BDPlugin.holdingQueue?.hostByTaskId?.set(task.taskId, task.host());
    BDPlugin.canceledTaskIds.delete(task.taskId);
    BDPlugin.cancelUpdateSentForTaskId.delete(task.taskId);

    if (notificationConfigJsonString) {
      BDPlugin.notificationConfigJsonStrings.set(task.taskId, notificationConfigJsonString);
    }

    const taskRequiresWifi = BDPlugin.taskRequiresWifi(task);
    if (taskRequiresWifi) {
      BDPlugin.taskIdsRequiringWiFi.add(task.taskId);
    }

    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      action: 'com.bbflight.background_downloader.enqueue',
      parameters: {
        keyTask: JSON.stringify(task),
        keyNotificationConfig: notificationConfigJsonString ?? '',
        keyResumeDataData: resumeData ? resumeData.data : '',
        keyStartByte: resumeData ? resumeData.requiredStartByte : -1,
        keyETag: resumeData ? resumeData.eTag ?? '' : ''
      }
    };


    const transferManager = TransferManager.getInstance(context);
    if (transferManager.getActiveTasksCount() === 0) {
      BDPlugin.startBackgroundTask(context);
    }
    await transferManager.enqueue(task, want);
    return true;
  }

  public static uiContext?: common.UIAbilityContext;
  private channel?: MethodChannel
  private backgroundChannel?: MethodChannel
  private binaryMessenger?: BinaryMessenger

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    QueueService.init();
    this.binaryMessenger = binding.getBinaryMessenger()
    this.backgroundChannel =
      new MethodChannel(binding.getBinaryMessenger(), 'com.bbflight.background_downloader.background');
    if (BDPlugin.firstBackgroundChannel === undefined) {
      BDPlugin.firstBackgroundChannel = this.backgroundChannel;
    }
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.bbflight.background_downloader')
    this.channel?.setMethodCallHandler(this)
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;

    BDPlugin.bgChannelByTaskId = new Map(
      Array.from(BDPlugin.bgChannelByTaskId).filter(entry => entry[1] !== this.backgroundChannel)
    );

    if (BDPlugin.firstBackgroundChannel == this.backgroundChannel) {
      BDPlugin.firstBackgroundChannel = undefined;
    }

    this.backgroundChannel = undefined;
    this.binaryMessenger = undefined;
  }


  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {

    console.info(BDPlugin.TAG, 'Received method call: ' + call.method);
    switch (call.method) {
      case 'enqueue':
        await this.methodEnqueue(call, result);
        break;
      case 'cancelTasksWithIds':
        await this.methodCancelTasksWithIds(call, result);
        break;
      case 'taskForId':
        await this.methodTaskForId(call, result);
        break;
      case 'reset':
        await this.methodReset(call, result);
        break;
      case 'allTasks':
        await this.methodAllTasks(call, result);
        break;
      case 'popStatusUpdates':
        await this.methodPopStatusUpdates(result);
        break;
      case 'popProgressUpdates':
        await this.methodPopProgressUpdates(result);
        break;
      case 'permissionStatus':
        await this.methodPermissionStatus(call, result);
        break;
      case 'requestPermission':
        await this.methodRequestPermission(call, result);
        break;
      case 'configHoldingQueue':
        this.methodConfigHoldingQueue(call, result);
        break;
      case 'enqueueAll':
        this.methodEnqueueAll(call, result);
        break;
      case 'updateNotification':
        this.methodUpdateNotification(call, result);
        break;


      default:
        result.notImplemented();
        break;
    }
  }

  private methodUpdateNotification(call: MethodCall, result: MethodResult) {
    const args = call.args as [string, string | undefined, number | undefined];
    const taskJson = args[0];
    const notificationConfigJson = args[1];
    const taskStatusOrdinal = args[2];
    NotificationService.createUpdateNotificationWorker(
      BDPlugin.uiContext!,
      taskJson,
      notificationConfigJson,
      taskStatusOrdinal
    );
    result.success(null);
  }


  getUniqueClassName(): string {
    return 'BDPlugin'
  }

  onAttachedToAbility(binding: AbilityPluginBinding) {
    BDPlugin.uiContext = binding.getAbility().context;
    this.initializePreferences();
  }

  public static startBackgroundTask(context: common.UIAbilityContext) {
    try {
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: context.abilityInfo.name
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      try {
        wantAgent.getWantAgent(wantAgentInfo).then((wantAgentObj: WantAgent) => {
          try {
            backgroundTaskManager.startBackgroundRunning(context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
              wantAgentObj,
              (error: BusinessAbilityError) => {
                if (error) {
                  console.error(BDPlugin.TAG,
                    `Failed to start background running. Code: ${error.code}, Msg: ${error.message}`);
                } else {
                  console.info(BDPlugin.TAG, 'Successfully started background running.');
                }
              });
          } catch (error) {
            console.error(BDPlugin.TAG, `Operation startBackgroundRunning failed. code is ${(error as BusinessError).code} message is ${(error as BusinessError).message}`);
          }
        });
      } catch (error) {
        console.error(BDPlugin.TAG, `Operation getWantAgent failed. code is ${(error as BusinessError).code} message is ${(error as BusinessError).message}`);
      }
    } catch (e) {
      const error = e as BusinessAbilityError;
      console.error(BDPlugin.TAG,
        `Exception when starting background running. Code: ${error.code}, Msg: ${error.message}`);
    }
  }

  public static stopBackgroundTask(context: common.UIAbilityContext) {
    try {
      backgroundTaskManager.stopBackgroundRunning(context, (error: BusinessAbilityError) => {
        if (error) {
          console.error(BDPlugin.TAG, `Failed to stop background running. Code: ${error.code}, Msg: ${error.message}`);
        } else {
          console.info(BDPlugin.TAG, 'Successfully stopped background running.');
        }
      });
    } catch (e) {
      const error = e as BusinessAbilityError;
      console.error(BDPlugin.TAG,
        `Exception when stopping background running. Code: ${error.code}, Msg: ${error.message}`);
    }
  }

  public static pauseTaskWithId(taskId: string): boolean {
    BDPlugin.pausedTaskIds.add(taskId);
    return true;
  }

  public static async cancelTasksWithIds(context: common.UIAbilityContext, taskIds: string[]): Promise<boolean> {
    console.info(BDPlugin.TAG, `Canceling tasks with ids: ${taskIds.join(', ')}`);
    for (const taskId of taskIds) {
      BDPlugin.canceledTaskIds.add(taskId);
    }
    // The running task will check the canceledTaskIds set and stop itself.
    return true;
  }


  onDetachedFromAbility() {
    BDPlugin.uiContext = undefined;
  }

  private async initializePreferences() {
    if (!BDPlugin.uiContext) {
      return;
    }
    try {
      const options: preferences.Options = { name: 'DEFAULT' };
      const prefs = await preferences.getPreferences(BDPlugin.uiContext, options);

      // Since we are not using workScheduler anymore, we can remove this part.
      // const allWorkInfos = await workScheduler.obtainAllWorks();
      // if (allWorkInfos.length === 0) {
      //   await BDPlugin.prefsLock.lockAsync(async () => {
      //     await prefs.delete(BDPlugin.keyTasksMap);
      //     await prefs.flush();
      //   });
      // }

      const requireWifiValue = await prefs.get(BDPlugin.KEY_REQUIRE_WIFI, 0) as number;
      BDPlugin.requireWifi =
        [RequireWiFi.AS_SET_BY_TASK, RequireWiFi.FOR_ALL_TASKS, RequireWiFi.FOR_NO_TASKS].find(e => e.value ===
          requireWifiValue) ?? RequireWiFi.AS_SET_BY_TASK;
    } catch (e) {
      console.error(BDPlugin.TAG, "Failed to initialize preferences", e);
    }
  }

  private async methodPermissionStatus(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot check permission, no ability context.", null);
      return;
    }
    const permissionType = call.args as PermissionType;
    const status = await PermissionsService.getPermissionStatus(permissionType);
    result.success(status.valueOf());
  }

  private async methodRequestPermission(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot request permission, no ability context.", null);
      return;
    }
    const permissionType = call.args as PermissionType;
    const status = await PermissionsService.requestPermission(BDPlugin.uiContext, permissionType);
    result.success(status.valueOf());
  }

  private async methodAllTasks(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot get tasks, no ability context.", null);
      return;
    }
    try {
      const group = call.args as string | null;
      const tasksAsListOfJsonStrings: string[] = [];
      const taskIdsInHoldingQueue = new Set<string>();

      // Get tasks from the holding queue first
      BDPlugin.holdingQueue?.allTasks(group)?.forEach(task => {
        tasksAsListOfJsonStrings.push(JSON.stringify(task));
        taskIdsInHoldingQueue.add(task.taskId);
      });

      // Get tasks from persisted storage, avoiding duplicates
      const options: preferences.Options = { name: 'DEFAULT' };
      const prefs = await preferences.getPreferences(BDPlugin.uiContext, options);
      const tasksMap = await getTaskMap(prefs);
      tasksMap.forEach((task, taskId) => {
        if (!taskIdsInHoldingQueue.has(taskId) && (group === null || task.group === group)) {
          tasksAsListOfJsonStrings.push(JSON.stringify(task));
        }
      });

      console.info(BDPlugin.TAG,
        `Returning ${tasksAsListOfJsonStrings.length} unfinished tasks in group ${group ?? 'any'}`);
      result.success(tasksAsListOfJsonStrings);
    } catch (e) {
      console.error(BDPlugin.TAG, "Error in methodAllTasks", e);
      result.error("ALL_TASKS_FAILED", "An exception occurred while retrieving all tasks.", e.toString());
    }
  }

  private async methodTaskForId(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot get task, no ability context.", null);
      return;
    }
    try {
      const taskId = call.args as string;
      let task = BDPlugin.holdingQueue?.taskForId(taskId);
      if (task) {
        result.success(JSON.stringify(task));
        return;
      }

      const options: preferences.Options = { name: 'DEFAULT' };
      const prefs = await preferences.getPreferences(BDPlugin.uiContext, options);
      const tasksMap = await getTaskMap(prefs);
      task = tasksMap.get(taskId);

      result.success(task ? JSON.stringify(task) : null);
    } catch (e) {
      console.error(BDPlugin.TAG, "Error in methodTaskForId", e);
      result.error("TASK_FOR_ID_FAILED", "An exception occurred while retrieving the task.", e.toString());
    }
  }

  private async methodReset(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot reset, no ability context.", null);
      return;
    }
    try {
      const group = call.args as string;
      let canceledCount = await BDPlugin.holdingQueue?.cancelAllTasks(BDPlugin.uiContext, group) ?? 0;

      const transferManager = TransferManager.getInstance(BDPlugin.uiContext);
      const activeTasksToCancel = transferManager.getTasksByGroup(group);
      const activeTaskIdsToCancel = activeTasksToCancel.map(task => task.taskId);

      if (activeTaskIdsToCancel.length > 0) {
        await BDPlugin.cancelTasksWithIds(BDPlugin.uiContext, activeTaskIdsToCancel);
        canceledCount += activeTaskIdsToCancel.length;
      }

      console.info(BDPlugin.TAG, `methodReset removed ${canceledCount} unfinished tasks in group ${group}`);
      result.success(canceledCount);
    } catch (e) {
      console.error(BDPlugin.TAG, "Error in methodReset", e);
      result.error("RESET_FAILED", "An exception occurred during reset.", e.toString());
    }
  }

  private async methodPopStatusUpdates(result: MethodResult): Promise<void> {
    await this.popLocalStorage(BDPlugin.KEY_STATUS_UPDATE_MAP, result);
  }

  private async methodPopProgressUpdates(result: MethodResult): Promise<void> {
    await this.popLocalStorage(BDPlugin.KEY_PROGRESS_UPDATE_MAP, result);
  }

  private async popLocalStorage(prefsKey: string, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.success("{}"); // Return empty map if context is not available
      return;
    }
    await BDPlugin.prefsLock.lockAsync(async () => {
      try {
        const options: preferences.Options = { name: 'DEFAULT' };
        const prefs = await preferences.getPreferences(BDPlugin.uiContext!, options);
        const jsonString = await prefs.get(prefsKey, "{}") as string;
        await prefs.delete(prefsKey);
        await prefs.flush();
        result.success(jsonString);
      } catch (e) {
        console.error(BDPlugin.TAG, `Error popping local storage for key ${prefsKey}`, e);
        result.success("{}"); // Return empty map on error
      }
    });
  }

  private async methodCancelTasksWithIds(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Cannot cancel tasks, no ability context.", null);
      return;
    }
    try {
      const taskIds = call.args as string[];
      console.info(BDPlugin.TAG, `Canceling tasks with ids: ${taskIds.join(', ')}`);

      // Cancel tasks in the holding queue
      const canceledInQueue = await BDPlugin.holdingQueue?.cancelTasksWithIds(BDPlugin.uiContext, taskIds) ?? [];
      const remainingTaskIds = taskIds.filter(id => !canceledInQueue.includes(id));

      // Cancel active tasks
      if (remainingTaskIds.length > 0) {
        await BDPlugin.cancelTasksWithIds(BDPlugin.uiContext, remainingTaskIds);
      }

      result.success(true);
    } catch (e) {
      console.error(BDPlugin.TAG, "Error in methodCancelTasksWithIds", e);
      result.error("CANCEL_FAILED", "An exception occurred during cancellation.", e.toString());
    }
  }

  private async methodEnqueue(call: MethodCall, result: MethodResult): Promise<void> {
    if (!BDPlugin.uiContext) {
      result.error("NO_CONTEXT", "Plugin is not attached to an ability.", null);
      return;
    }
    try {
      const args = call.args as Array<string | number | undefined>;
      const taskJsonMapString = args[0] as string;
      console.info(BDPlugin.TAG, taskJsonMapString);
      const task = Task.fromObject(JSON.parse(taskJsonMapString) as ESObject);
      const notificationConfigJsonString = args[1] as string | undefined;

      const isResume = args.length >= 4;
      const resumeData: ResumeData | undefined = isResume
        ? new ResumeData({
          task: task,
          data: args[2] as string,
          requiredStartByte: args[3] as number,
          eTag: args.length > 4 ? (args[4] as string | undefined) : undefined,
        })
        : undefined;

      if (!task.url || !task.url.startsWith('http')) {
        console.warn(BDPlugin.TAG, `Invalid URL for taskId ${task.taskId}: ${task.url}`);
        result.success(false);
        return;
      }

      const success = await BDPlugin.doEnqueue(
        BDPlugin.uiContext,
        task,
        notificationConfigJsonString,
        resumeData,
        0,
        this
      );
      result.success(success);

    } catch (e) {
      console.error(BDPlugin.TAG, "Error in methodEnqueue", e);
      result.error("ENQUEUE_FAILED", "An exception occurred during enqueue.", e.toString());
    }
  }

  private methodConfigHoldingQueue(call: MethodCall, result: MethodResult) {
    let args: Array<number> = call.args as Array<number>;
    if (args.length === 0) {
      BDPlugin.holdingQueue = undefined;
    } else {
      BDPlugin.holdingQueue = BDPlugin.holdingQueue ?? new HoldingQueue();
      BDPlugin.holdingQueue.maxConcurrent = args[0] as number;
      BDPlugin.holdingQueue.maxConcurrentByHost = args[1] as number;
      BDPlugin.holdingQueue.maxConcurrentByGroup = args[2] as number
    }
    result.success(null);
  }

  static methodBackgroundChannel(
    plugin: BDPlugin | undefined = undefined,
    taskId: string = "bgd_non_existent_id"
  ): MethodChannel | undefined {
    return plugin?.backgroundChannel ?? BDPlugin.bgChannelByTaskId.get(taskId) ?? BDPlugin.firstBackgroundChannel;
  }

  static taskRequiresWifi(task: Task): boolean {
    return (BDPlugin.requireWifi.value == RequireWiFi.FOR_ALL_TASKS.value ||
      (BDPlugin.requireWifi.value == RequireWiFi.AS_SET_BY_TASK.value && task.requiresWiFi))
  }

  private methodEnqueueAll(call: MethodCall, result: MethodResult) {
    const args = call.args as List<string>;
    const taskListJsonString = args[0] as string;
    const notificationConfigListJsonString = args[1] as string;

    const task = new taskpool.Task(enqueueAllTask, taskListJsonString, notificationConfigListJsonString, result, this);
    taskpool.execute(task).then(() => {
      console.info(BDPlugin.TAG, 'execute methodEnqueueAll success');
    }).catch((e: BusinessError) => {
      console.error(BDPlugin.TAG, `execute methodEnqueueAll error: ${e.message}`);
    })
  }
}
