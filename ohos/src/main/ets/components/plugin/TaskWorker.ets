import {
  ExceptionType,
  NotificationConfig,
  ResumeData,
  Task,
  TaskException,
  TaskParams,
  TaskProgressUpdate,
  TaskStatus,
  TaskStatusUpdate,
  TaskStatusUpdateParams
} from './Models';
import { common } from '@kit.AbilityKit';
import { Callbacks } from './Callbacks';
import BDPlugin from './BDPlugin';
import { EnqueueItem } from './HoldingQueue';
import { WiFi } from './WIFI';
import { BackgroundPost, PostArg, QueueService } from './QueueService';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { TaskDatabase } from './TaskDatabase';
import { collections } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { rcp } from '@kit.RemoteCommunicationKit';

// Define explicit type for task key-value pairs
type TaskKeyValuePair = [string, Task];

export class TaskWorker {
  static readonly TAG = 'TaskWorker'
  static readonly CHUNK_GROUP = 'chunk'
  static readonly KEY_TASK = 'Task'
  static readonly KEY_NOTIFICATION_CONFIG = 'notificationConfig'
  static readonly KEY_RESUME_DATA_DATA = 'tempFilename'
  static readonly KEY_START_BYTE = 'startByte'
  static readonly KEY_ETAG = 'eTag'
  static readonly BUFFER_SIZE = 2 << 12;
  static readonly TASK_TIMEOUT_MILLIS = 9 * 60 * 1000; // 9 minutes
  task: Task | undefined = undefined;
  // properties related to pause/resume functionality and progress
  startByte = 0 // actual starting position within the task range, used for resume
  bytesTotal = 0 // total bytes read in this download session
  taskCanResume = false // whether task is able to resume
  isResume = false // whether task is a resume
  private bytesTotalAtLastProgressUpdate = 0
  private lastProgressUpdateTime = 0 // in millis
  private lastProgressUpdate = 0.0
  private nextProgressUpdateTime = 0
  networkSpeed = -1.0 // in MB/s
  protected isTimedOut = false
  // properties related to notifications
  notificationConfigJsonString?: string
  notificationConfig?: NotificationConfig
  notificationId = 0
  notificationProgress = 2.0 // indeterminate

  // additional parameters for final TaskStatusUpdate
  taskException?: TaskException
  responseBody?: string
  protected  responseHeaders?: Map<string, string>
  responseStatusCode?: number
  private mimeType?: string // derived from Content-Type header
  private charSet?: string // derived from Content-Type header

  // related to foreground tasks
  private runInForegroundFileSize: number = -1
  canRunInForeground = false
  runInForeground = false;
  protected hasDeliveredResult = false;
  protected isCancelled = false;
  public isPaused = false;

  get isActive(): boolean {
    return !this.hasDeliveredResult && !this.isCancelled && !this.isPaused;
  }

  public cancel(): void {
    this.isCancelled = true;
  }

  public pause(): void {
    this.isPaused = true;
  }

  prefs?: preferences.Preferences
  applicationContext: common.UIAbilityContext
  want: Want

  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    this.applicationContext = applicationContext
    this.want = want
  }

  /**
   * Creates an rcp.Session with global configuration (Proxy, SSL) applied from preferences.
   * Merges with the provided baseConfig if any.
   */
  public static async createSession(prefs: preferences.Preferences, baseConfig?: rcp.SessionConfiguration): Promise<rcp.Session> {
    const config: rcp.SessionConfiguration = baseConfig ?? {};

    if (!config.requestConfiguration) {
      config.requestConfiguration = {};
    }
    if (!config.requestConfiguration.security) {
      config.requestConfiguration.security = {
        remoteValidation: 'system'
      };
    }

    // 1. Proxy Configuration
    const proxyAddress = await prefs.get(BDPlugin.KEY_CONFIG_PROXY_ADDRESS, '') as string;
    const proxyPort = await prefs.get(BDPlugin.KEY_CONFIG_PROXY_PORT, -1) as number;

    if (proxyAddress && proxyAddress.length > 0 && proxyPort > 0) {
      // TODO: Verify rcp.ProxyConfiguration signature for this SDK version.
      // Current attempt { host, port } fails with "host does not exist in type WebProxy".
      /*
      config.requestConfiguration.proxy = {
        host: proxyAddress,
        port: proxyPort,
        exclusions: [] 
      };
      */
      console.warn(TaskWorker.TAG, "Proxy configuration is currently disabled due to SDK type mismatch.");
    }

    // 2. SSL Bypass Configuration
    const bypassSSL = await prefs.get(BDPlugin.KEY_CONFIG_BYPASS_SSL, false) as boolean;
    if (bypassSSL) {
      config.requestConfiguration.security.remoteValidation = 'skip';
    }

    return rcp.createSession(config);
  }

  public async doWork(): Promise<void> {
    // to be implemented by subclasses
  }

  public getTask(): Task | undefined {
    return this.task;
  }

  /**
   * Sets up a timeout for the task
   */
  protected startTimeout() {
    setTimeout(() => {
      this.isTimedOut = true;
    }, TaskWorker.TASK_TIMEOUT_MILLIS);
  }

  /**
   * Returns true if progress update should be sent
   */
  protected shouldSendProgressUpdate(progress: number, now: number): boolean {
    const result = (progress - this.lastProgressUpdate > 0.02 && now > this.lastProgressUpdateTime) ||
      (progress > this.lastProgressUpdate && now > this.lastProgressUpdateTime + 2000);
    if (result) {
      this.lastProgressUpdate = progress;
      this.lastProgressUpdateTime = now;
    }
    return result;
  }

  /**
   * Set the [taskException] variable based on Exception [e]
   */
  protected setTaskException(e: BusinessError) {
    let exceptionType = ExceptionType.GENERAL;
    if (e.code === 200 || e.code === 201) { // ETIMEDOUT or ENETUNREACH from BusinessError
      exceptionType = ExceptionType.CONNECTION;
    }
    this.taskException = new TaskException(exceptionType, e.code, e.message);
  }


  /**
   * Post method message on backgroundChannel with arguments
   *
   * If the post is not successful, execute the [onFail] block, if given
   *
   * [arg] can be single variable or a MutableList
   */
  public static async postOnBackgroundChannel(
    method: string, task: Task, arg: Array<string | number | collections.Map<string, string> | null | undefined>
  ) {
    const bgChannel = BDPlugin.methodBackgroundChannel(undefined, task.taskId);
    if (bgChannel) {
      bgChannel.invokeMethod(method, [JSON.stringify(task), ...arg]);
    } else {
      console.warn(BDPlugin.TAG, `Could not find backgroundChannel for taskId ${task.taskId} to post ${method}`);
      // Here you might want to implement the fallback to storeLocally,
      // similar to how the original onFail was intended.
    }
  }

  /**
   * Processes a change in status for the task
   *
   * Sends status update via the background channel to Flutter, if requested
   * If the task is finished, processes a final progressUpdate update and removes
   * task from persistent storage.
   *
   * Optional [taskException] for status .failed
   * */
  public static async processStatusUpdate(
    task: Task,
    status: TaskStatus,
    prefs: preferences.Preferences,
    taskException?: TaskException,
    responseBody?: string,
    responseHeaders?: Map<string, string>,
    responseStatusCode?: number,
    mimeType?: string,
    charSet?: string,
    context?: common.UIAbilityContext,
  ) {
    if (context) {
      const db = new TaskDatabase(context);
      const progress = status.equals(TaskStatus.COMPLETE) ? 1.0 : (status.equals(TaskStatus.ENQUEUED) ? 0.0 : undefined);
      db.insertOrUpdateTask(task, status, progress);
    }

    // Intercept status updates resulting from re-enqueue request, which
    // themselves are triggered by a change in WiFi requirement
    if (BDPlugin.tasksToReEnqueue.delete(task)) {
      if (status === TaskStatus.PAUSED || status === TaskStatus.CANCELED || status === TaskStatus.FAILED) {
        WiFi.reEnqueue(
          new EnqueueItem(
            context!,
            task,
            BDPlugin.notificationConfigJsonStrings.get(task.taskId),
            BDPlugin.localResumeData.get(task.taskId)
          )
        )
        if (BDPlugin.tasksToReEnqueue.size === 0) {
          WiFi.reEnqueue(undefined) // signal end of batch
        }
        return
      }
    }

    // Normal status update

    // Check if the task was 'programmatically' canceled, in which case a TaskStatus.failed may be
    // incorrectly generated by the WorkManager, so we change it to 'canceled'
    const modifiedStatus =
      BDPlugin.canceledTaskIds.has(task.taskId) ? TaskStatus.CANCELED : status

    // A 'failed' progress update is only provided if
    // a retry is not needed: if it is needed, a `waitingToRetry` progress update
    // will be generated on the Dart side
    const retryNeeded = modifiedStatus === TaskStatus.FAILED && task.retriesRemaining > 0
    let canSendStatusUpdate = true // may become false for cancellations
    // if task is in final state, process a final progressUpdate
    switch (modifiedStatus) {
      case TaskStatus.COMPLETE:
        await TaskWorker.processProgressUpdate(
          task, 1.0, prefs
        )
        break;

      case TaskStatus.FAILED:
        if (!retryNeeded) {
          await TaskWorker.processProgressUpdate(
            task, -1.0, prefs
          )
        }
        break;

      case TaskStatus.CANCELED:
        canSendStatusUpdate = await TaskWorker.canSendCancellation(task)
        if (canSendStatusUpdate) {
          BDPlugin.cancelUpdateSentForTaskId.set(task.taskId,
            systemDateTime.getTime(false))
          await TaskWorker.processProgressUpdate(
            task, -2.0, prefs
          )
        }
        break;

      case TaskStatus.NOT_FOUND:
        await TaskWorker.processProgressUpdate(
          task, -3.0, prefs
        )
        break;

      case TaskStatus.PAUSED:
        await TaskWorker.processProgressUpdate(
          task, -5.0, prefs
        )
        break;

      default:
        break;
    }
    const finalHeaders: collections.Map<string, string> | undefined = responseHeaders ?
    new collections.Map<string, string>(Array.from(responseHeaders.entries())
      .filter((entry) => entry[1] !== undefined)) :
      undefined;

    let para1: TaskStatusUpdateParams = {
      task: task,
      taskStatus: modifiedStatus,
      exception: modifiedStatus.equals(TaskStatus.FAILED) ?
        taskException ?? new TaskException(ExceptionType.GENERAL) : undefined,
      responseBody: responseBody,
      responseHeaders: finalHeaders,
      responseStatusCode: responseStatusCode,
      mimeType: mimeType,
      charSet: charSet
    };
    let para2: TaskStatusUpdateParams = {
      task: task,
      taskStatus: modifiedStatus,
    };

    let taskStatusUpdate =
      modifiedStatus.isFinalState() ? new TaskStatusUpdate(para1) : new TaskStatusUpdate(para2);


    // Post update if task expects one, or if failed and retry is needed
    if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
      const arg = taskStatusUpdate.argList
      try {
        await TaskWorker.postOnBackgroundChannel("statusUpdate", task, arg);
      } catch (e) {
        // unsuccessful post, so store in local prefs
        console.error(TaskWorker.TAG, "Could not post status update -> storing locally")
        await TaskWorker.storeLocally(
          BDPlugin.KEY_STATUS_UPDATE_MAP,
          task.taskId,
          JSON.stringify(taskStatusUpdate),
          prefs
        )
      }
    }
    // if task is in final state, cancel the WorkManager job (if failed),
    // remove task from persistent storage, clean up references to taskId
    // and invoke the onTaskFinishedCallback if necessary
    if (modifiedStatus.isFinalState()) {
      BDPlugin.prefsLock.lockAsync(async () => {
        let tasksMap = await getTaskMap(prefs);
        tasksMap.delete(task.taskId);
        await prefs.put(BDPlugin.KEY_TASKS_MAP, JSON.stringify(Array.from(tasksMap.entries())));
        await prefs.flush();
      });

      QueueService.cleanupTaskId(task.taskId);
      if (task.options?.hasOnFinishCallback() === true && context) {
        Callbacks.invokeOnTaskFinishedCallback(context, taskStatusUpdate);
      }
    }
  }

  /** Return true if we can send a cancellation for this task
   *
   * Cancellation can only be sent if it wasn't already sent by the [BDPlugin]
   *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
   * from the [BDPlugin.cancelUpdateSentForTaskId]
   */
  private static async canSendCancellation(task: Task): Promise<boolean> {
    let now = systemDateTime.getTime(false);
    // Filter out entries older than 3 seconds
    const filteredEntries = Array.from(BDPlugin.cancelUpdateSentForTaskId.entries())
      .filter((entry) => now - entry[1] < 3000);
    BDPlugin.cancelUpdateSentForTaskId = new Map(filteredEntries);

    return !BDPlugin.cancelUpdateSentForTaskId.has(task.taskId);
  }

  /**
   * Processes a progress update for the [task]
   *
   * Sends progress update via the background channel to Flutter, if requested
   */
  public static async processProgressUpdate(
    task: Task, progress: number, prefs: preferences.Preferences, expectedFileSize: number = -1,
    downloadSpeed: number = -1.0, timeRemaining: number = -1000
  ) {
    if (task.providesProgressUpdates()) {
      try {
        await TaskWorker.postOnBackgroundChannel(
          "progressUpdate", task,
          [progress, expectedFileSize, downloadSpeed, timeRemaining]
        );4
      } catch (e) {
        // unsuccessful post, so store in local prefs
        console.error(TaskWorker.TAG, "Could not post progress update -> storing locally")
        await TaskWorker.storeLocally(
          BDPlugin.KEY_PROGRESS_UPDATE_MAP,
          task.taskId,
          JSON.stringify(new TaskProgressUpdate(
            task,
            progress,
            expectedFileSize
          )),
          prefs
        )
      }
    }
  }

  /**
   * Process resume information
   *
   * Attempts to post this to the Dart side via background channel. If that is not
   * successful, stores the resume data in shared preferences, for later retrieval by
   * the Dart side.
   *
   * Also stores a copy in memory locally, to allow notifications to resume a task
   */
  public static async processResumeData(resumeData: ResumeData, prefs: preferences.Preferences) {
    BDPlugin.localResumeData.set(resumeData.task.taskId, resumeData);
    try {
      await TaskWorker.postOnBackgroundChannel(
        "resumeData", resumeData.task,
        [resumeData.data, resumeData.requiredStartByte, resumeData.eTag ?? ""]
      );
    } catch (e) {
      // unsuccessful post, so store in local prefs
      console.error(TaskWorker.TAG, "Could not post resume data -> storing locally");
      await TaskWorker.storeLocally(
        BDPlugin.KEY_RESUME_DATA_MAP,
        resumeData.task.taskId,
        JSON.stringify(resumeData),
        prefs
      );
    }
  }

  /**
   * Stores the item locally in preferences, under the prefsKey
   *
   * Used for failed background channel posts
   */
  private static async storeLocally(
    prefsKey: string,
    taskId: string,
    item: string,
    prefs: preferences.Preferences
  ): Promise<void> {
    await BDPlugin.prefsLock.lockAsync(async () => {
      const jsonString = await prefs.get(prefsKey, "{}") as string;
      let mapByTaskId: Record<string, string>;
      try {
        mapByTaskId = JSON.parse(jsonString) as Record<string, string>;
      } catch (e) {
        mapByTaskId = {};
      }
      mapByTaskId[taskId] = item;
      await prefs.put(prefsKey, JSON.stringify(mapByTaskId));
      await prefs.flush();
    });
  }
}

/** Return the map of tasks stored in preferences */
export async function getTaskMap(prefs: preferences.Preferences): Promise<Map<string, Task>> {
  return await BDPlugin.prefsLock.lockAsync(async () => {
    const tasksMapJson = await prefs.get(BDPlugin.KEY_TASKS_MAP, "[]") as string;
    try {
      // The map is stored as an array of [key, value] pairs
      const taskArray: Array<[string, object]> = JSON.parse(tasksMapJson) as Array<[string, object]>;
      const resultMap = new Map<string, Task>();
      for (let i = 0; i < taskArray.length; i++) {
        const pair = taskArray[i];
        resultMap.set(pair[0], new Task(pair[1] as TaskParams));
      }
      return resultMap;
    } catch (e) {
      console.error(TaskWorker.TAG, "Could not parse tasksMap from JSON", e);
      return new Map<string, Task>();
    }
  });
}
