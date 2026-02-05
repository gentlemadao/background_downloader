import { common } from "@kit.AbilityKit";
import BDPlugin from "./BDPlugin";
import { ExceptionType, ResumeData, Task, TaskException, TaskStatus } from "./Models";
import { TaskWorker } from "./TaskWorker";
import { preferences } from "@kit.ArkData";
import { ArkTSUtils } from "@kit.ArkTS";
import { NotificationService } from "./Notifications";
import { createDeferred, Deferred } from './Callbacks';


/**
 * Queue that holds [EnqueueItem] items before they are actually enqueued
 *
 * Configure [maxConcurrent], [maxConcurrentByHost] and [maxConcurrentByGroup] to limit which items
 * can be enqueued simultaneously.
 */
export class HoldingQueue {
  public maxConcurrent: number = 1 << 20;
  public maxConcurrentByHost: number = 1 << 20;
  public maxConcurrentByGroup: number = 1 << 20;
  public hostByTaskId: Map<string, string> = new Map<string, string>();
  public enqueuedTaskIds = new Array<string>();
  private concurrent: number = 0;
  private concurrentByHost = new Map<string, number>();
  private concurrentByGroup = new Map<string, number>();
  private queue = new Array<EnqueueItem>(); // Priority queue is simulated by sorting
  private taskFinishedQueue: Task[] = [];
  private processSignal: Deferred<void> | null = null;
  public stateMutex = new ArkTSUtils.locks.AsyncLock();

  constructor() {
    this.startQueueProcessor();
    this.startTaskFinishedProcessor();
  }

  /**
   * Starts the main queue processing loop.
   * A signal on `processSignal` will trigger one iteration.
   */
  private async startQueueProcessor() {
    while (true) {
      try {
        this.processSignal = createDeferred<void>();
        await this.processSignal.promise; // Wait for a signal
        this.processSignal = null;

        await this.stateMutex.lockAsync(async () => {
          if (this.concurrent < this.maxConcurrent) {
            const mustWait: EnqueueItem[] = [];
            let processed = false;
            // Find the first item that can be enqueued
            while (this.queue.length > 0 && !processed) {
              const item = this.queue.shift()!; // Highest priority item
              const host = item.task.host();
              const group = item.task.group;

              if ((this.concurrentByHost.get(host) ?? 0) < this.maxConcurrentByHost &&
                (this.concurrentByGroup.get(group) ?? 0) < this.maxConcurrentByGroup) {
                // Enqueue this item
                this.concurrent++;
                this.concurrentByHost.set(host, (this.concurrentByHost.get(host) ?? 0) + 1);
                this.concurrentByGroup.set(group, (this.concurrentByGroup.get(group) ?? 0) + 1);
                item.enqueue(0);
                processed = true; // Process only one item per signal
              } else {
                mustWait.push(item);
              }
            }
            // Add items that must wait back to the queue and re-sort
            if (mustWait.length > 0) {
              this.queue.unshift(...mustWait);
              this.queue.sort((a, b) => a.compareTo(b));
            }
          }
        });
      } catch (e) {
        const error = e as BusinessError;
        console.error(BDPlugin.TAG, `Error in startQueueProcessor: ${error.message}`);
      }
    }
  }

  /**
   * Starts the processor for the taskFinished queue
   */
  private async startTaskFinishedProcessor() {
    while (true) {
      try {
        if (this.taskFinishedQueue.length > 0) {
          const task = this.taskFinishedQueue.shift()!;
          await this.executeTaskFinished(task);
        } else {
          await sleep(50); // Wait if the queue is empty
        }
      } catch (e) {
        const error = e as BusinessError;
        console.error(BDPlugin.TAG, `Error in startTaskFinishedProcessor: ${error.message}`);
      }
    }
  }


  /**
   * Add [EnqueueItem] [item] to the queue and advance the queue if possible
   */
  public async add(item: EnqueueItem) {
    await this.stateMutex.lockAsync(async () => {
      this.queue.push(item);
      this.queue.sort((a, b) => a.compareTo(b));
      this.enqueuedTaskIds.push(item.task.taskId);
      NotificationService.registerEnqueue(item, true);
    });
    this.advanceQueue();
  }

  /**
   * Signals to the holdingQueue that a [task] has finished
   */
  public async taskFinished(task: Task) {
    this.taskFinishedQueue.push(task);
  }

  /**
   * Processes a finished task, updating concurrency counts and advancing the queue.
   */
  private async executeTaskFinished(task: Task) {
    this.hostByTaskId.delete(task.taskId);
    this.enqueuedTaskIds = this.enqueuedTaskIds.filter(id => id !== task.taskId);
    const host = task.host();
    const group = task.group;
    await this.stateMutex.lockAsync(async () => {
      this.concurrent = Math.max(0, this.concurrent - 1);
      this.concurrentByHost.set(host, Math.max(0, (this.concurrentByHost.get(host) ?? 1) - 1));
      this.concurrentByGroup.set(group, Math.max(0, (this.concurrentByGroup.get(group) ?? 1) - 1));
    });
    this.advanceQueue();
  }


  /**
   * Removes all [EnqueueItem] where their taskId is in [taskIds], sends a
   * [TaskStatus.canceled] update and returns a list of
   * taskIds that were cancelled this way
   */
  public async cancelTasksWithIds(context: common.UIAbilityContext, taskIds: string[]): Promise<string[]> {
    const removedTaskIds: string[] = [];
    await this.stateMutex.lockAsync(async () => {
      const toRemove = this.queue.filter(item => taskIds.includes(item.task.taskId));
      this.queue = this.queue.filter(item => !taskIds.includes(item.task.taskId));

      let options: preferences.Options = { name: 'DEFAULT' };
      let prefs = await preferences.getPreferences(context, options);

      for (const item of toRemove) {
        await TaskWorker.processStatusUpdate(item.task, TaskStatus.CANCELED, prefs, undefined, undefined, undefined,
          undefined, undefined, undefined, context);
        console.info(BDPlugin.TAG, `Canceled task with id ${item.task.taskId}`);
        removedTaskIds.push(item.task.taskId);
      }
    });
    return removedTaskIds;
  }

  /**
   * Cancel (delete) all [EnqueueItem] matching [group], send a
   * [TaskStatus.canceled] for each and return the number of items cancelled
   */
  public async cancelAllTasks(context: common.UIAbilityContext, group: string): Promise<number> {
    const taskIds = this.queue.filter(item => item.task.group === group).map(item => item.task.taskId);
    await this.cancelTasksWithIds(context, taskIds);
    return taskIds.length;
  }

  /**
   * Return task matching [taskId], or null
   */
  public taskForId(taskId: string): Task | null {
    const item = this.queue.find(item => item.task.taskId === taskId);
    return item ? item.task : null;
  }

  /**
   * Return list of [Task] for this [group]. If [group] is null, all tasks will be returned
   */
  public allTasks(group: string | null): Task[] {
    return this.queue
      .filter(item => group === null || item.task.group === group)
      .map(item => item.task);
  }

  /**
   * Advance the queue by signalling the queue processing coroutine
   */
  private advanceQueue() {
    if (this.processSignal) {
      this.processSignal.resolve();
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Holds data related to enqueueing a task
 */
export class EnqueueItem {
  context: common.UIAbilityContext;
  task: Task;
  notificationConfigJsonString?: string;
  resumeData?: ResumeData;
  plugin?: BDPlugin;
  created: Date;

  constructor(
    context: common.UIAbilityContext,
    task: Task,
    notificationConfigJsonString?: string,
    resumeData?: ResumeData,
    plugin?: BDPlugin,
    created: Date = new Date()
  ) {
    this.context = context;
    this.task = task;
    this.notificationConfigJsonString = notificationConfigJsonString;
    this.resumeData = resumeData;
    this.plugin = plugin;
    this.created = created;
  }


  /**
   * Execute the re-enqueue after an appropriate delay
   * @param afterDelayMillis minimal delay (ms)
   */
  public async enqueue(afterDelayMillis: number = 1000): Promise<void> {
    const timeSinceCreatedMillis = Date.now() - this.created.getTime();
    if (timeSinceCreatedMillis < afterDelayMillis) {
      await sleep(afterDelayMillis - timeSinceCreatedMillis);
    }

    const success = await BDPlugin.doEnqueue(
      this.context,
      this.task,
      this.notificationConfigJsonString,
      this.resumeData,
      undefined,
      this.plugin,
    );

    if (!success) {
      console.warn(BDPlugin.TAG,
        `Delayed or retried enqueue failed for taskId ${this.task.taskId}`
      );

      let options: preferences.Options = { name: 'DEFAULT' };
      let defaultPref = await preferences.getPreferences(this.context, options);

      await TaskWorker.processStatusUpdate(
        this.task,
        TaskStatus.FAILED,
        defaultPref,
        new TaskException(ExceptionType.GENERAL, undefined, "Delayed or retried enqueue failed"),
        undefined,
        undefined,
        undefined,
        undefined,
        undefined,
        this.context
      );

      BDPlugin.holdingQueue?.taskFinished(this.task);

      NotificationService.registerEnqueue(this, false);
    }
    await sleep(20);
  }

  /**
   * Comparison function: first by priority, then by creationTime
   * A negative number indicates that 'this' has a higher priority (comes first)
   */
  compareTo(other: EnqueueItem): number {
    if (this.task.priority !== other.task.priority) {
      // Lower number means higher priority
      return this.task.priority - other.task.priority;
    }
    // Earlier creation time means higher priority
    return this.created.getTime() - other.created.getTime();
  }
}
