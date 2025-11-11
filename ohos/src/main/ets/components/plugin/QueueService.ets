import { collections } from '@kit.ArkTS';
import { Task } from './Models';
import { systemDateTime } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import { TaskWorker } from './TaskWorker';
import { createDeferred } from './Callbacks';
import { MethodChannel } from '@ohos/flutter_ohos';


export type PostArgValue = string | number | boolean | collections.Map<string, string> | null | undefined;
export type PostArg = PostArgValue | PostArgValue[];

/**
 * BackgroundPost to be sent via backgroundChannel to Flutter, used in [QueueService]
 */
export class BackgroundPost {
  task: Task;
  method: string;
  arg: PostArg;
  onFail?: () => Promise<void>;

  constructor(task: Task, method: string, arg: PostArg, onFail?: () => Promise<void>) {
    this.task = task;
    this.method = method;
    this.arg = arg;
    this.onFail = onFail;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export class QueueService {
  private static taskIdDeletionQueue: string[] = [];
  private static lastTaskIdAdditionTime: number = 0;
  private static readonly minTaskIdDeletionDelay: number = 2000; //ms

  private static backgroundPostQueue: BackgroundPost[] = [];
  private static isProcessingPosts = false;
  private static isProcessingDeletions = false;

  /**
   * Initializes the service by starting the processing loops.
   * Should be called once when the plugin is initialized.
   */
  public static init() {
    if (!QueueService.isProcessingPosts) {
      QueueService.processBackgroundPosts();
    }
    if (!QueueService.isProcessingDeletions) {
      QueueService.processTaskIdDeletions();
    }
  }

  /**
   * Post this [BackgroundPost] on the background channel
   */
  public static postOnBackgroundChannel(bgPost: BackgroundPost) {
    QueueService.backgroundPostQueue.push(bgPost);
  }

  /**
   * Remove this [taskId] from various maps after a delay
   */
  public static cleanupTaskId(taskId: string) {
    QueueService.lastTaskIdAdditionTime = Date.now();
    QueueService.taskIdDeletionQueue.push(taskId);
  }

  private static async processBackgroundPosts() {
    QueueService.isProcessingPosts = true;
    while (true) {
      if (QueueService.backgroundPostQueue.length > 0) {
        const bgPost = QueueService.backgroundPostQueue.shift()!;
        const success = createDeferred<boolean>();

        // Assuming UI-related tasks must run on the main thread.
        // In ArkTS, we can just await the async operation.
        try {
          const argList: PostArg[] = [JSON.stringify(bgPost.task)];
          if (Array.isArray(bgPost.arg)) {
            argList.push(...bgPost.arg);
          } else {
            argList.push(bgPost.arg);
          }

          const bgChannel = BDPlugin.methodBackgroundChannel(undefined, bgPost.task.taskId);
          if (bgChannel) {
            // The MethodChannel calls should inherently be handled on the correct thread by the Flutter engine.
            bgChannel.invokeMethod(bgPost.method, argList, {
              success: () => success.resolve(true),
              error: () => success.resolve(false),
              notImplemented: () => success.resolve(false),
            });
          } else {
            console.warn(TaskWorker.TAG, `Could not post ${bgPost.method} to background channel`);
            success.resolve(false);
          }
        } catch (e) {
          console.error(TaskWorker.TAG, `Exception trying to post ${bgPost.method} to background channel: ${e.message}`);
          if (!success.promise.then) { // A simple check if it's not already resolved/rejected
            success.resolve(false);
          }
        }

        if (bgPost.onFail && (BDPlugin.forceFailPostOnBackgroundChannel || !(await success.promise))) {
          await bgPost.onFail();
        }
      } else {
        await sleep(50); // Wait if the queue is empty
      }
    }
  }

  private static async processTaskIdDeletions() {
    QueueService.isProcessingDeletions = true;
    while (true) {
      if (QueueService.taskIdDeletionQueue.length > 0) {
        const taskId = QueueService.taskIdDeletionQueue.shift()!;
        const now = Date.now();
        const elapsed = now - QueueService.lastTaskIdAdditionTime;
        if (elapsed < QueueService.minTaskIdDeletionDelay) {
          await sleep(QueueService.minTaskIdDeletionDelay - elapsed);
        }
        BDPlugin.flutterEngineByTaskId.delete(taskId);
        BDPlugin.bgChannelByTaskId.delete(taskId);
        BDPlugin.localResumeData.delete(taskId);
        BDPlugin.notificationConfigJsonStrings.delete(taskId);
      } else {
        await sleep(200); // Wait longer if the queue is empty
      }
    }
  }
}
