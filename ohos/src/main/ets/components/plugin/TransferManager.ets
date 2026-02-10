import { Task, TaskStatus } from './Models';
import { DownloadTaskWorker } from './DownloadTaskWorker';
import { UploadTaskWorker } from './UploadTaskWorker';
import { ParallelDownloadTaskWorker } from './ParallelDownloadTaskWorker';
import { DataTaskWorker } from './DataTaskWorker';
import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { TaskWorker } from './TaskWorker';
import BDPlugin from './BDPlugin';
import { Constraints } from './Constraints';
import { preferences } from '@kit.ArkData';

const TAG = "TransferManager";

class TransferManager {
  private static instance: TransferManager;
  private activeTasks: Map<string, TaskWorker> = new Map();
  private context: common.UIAbilityContext;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  public static getInstance(context: common.UIAbilityContext): TransferManager {
    if (!TransferManager.instance) {
      TransferManager.instance = new TransferManager(context);
    }
    return TransferManager.instance;
  }

  public async enqueue(task: Task, want: Want) {
    if (this.activeTasks.has(task.taskId)) {
      console.warn(TAG, `Task with id ${task.taskId} is already active.`);
      return;
    }

    if (!(await Constraints.meetsConstraints(task, this.context))) {
      console.info(TAG, `Task ${task.taskId} constraints not met.`);
      const options: preferences.Options = { name: 'DEFAULT' };
      const prefs = await preferences.getPreferences(this.context, options);
      await TaskWorker.processStatusUpdate(
        task,
        TaskStatus.WAITING_TO_RETRY,
        prefs,
        undefined, undefined, undefined, undefined, undefined, undefined,
        this.context
      );
      return;
    }

    let worker: TaskWorker;
    if (task.isParallelDownloadTask()) {
      worker = new ParallelDownloadTaskWorker(this.context, want);
    } else if (task.isUploadTask()) {
      worker = new UploadTaskWorker(this.context, want);
    } else if (task.isDataTask()) {
      worker = new DataTaskWorker(this.context, want);
    } else {
      worker = new DownloadTaskWorker(this.context, want);
    }

    this.activeTasks.set(task.taskId, worker);
    console.info(TAG, `Enqueued task with id ${task.taskId}. Total active tasks: ${this.activeTasks.size}`);

    try {
      await worker.doWork();
    } catch (e) {
      console.error(TAG, "Error doWork", e)
    }finally {
      this.activeTasks.delete(task.taskId);
      console.info(TAG, `Finished task with id ${task.taskId}. Total active tasks: ${this.activeTasks.size}`);
      if (this.activeTasks.size === 0) {
        BDPlugin.stopBackgroundTask(this.context);
      }
    }
  }

  public getActiveTasksCount(): number {
    return this.activeTasks.size;
  }

  public cancelTaskById(taskId: string): void {
    const worker = this.activeTasks.get(taskId);
    if (worker) {
      console.info(TAG, `Canceling task with id ${taskId}`);
      worker.cancel();
    } else {
      console.warn(TAG, `Could not find active task with id ${taskId} to cancel.`);
    }
  }

  public pauseTaskById(taskId: string): void {
    const worker = this.activeTasks.get(taskId);
    if (worker) {
      console.info(TAG, `Pausing task with id ${taskId}`);
      worker.pause();
    } else {
      console.warn(TAG, `Could not find active task with id ${taskId} to pause.`);
    }
  }

  public isPaused(taskId: string): boolean {
    return this.activeTasks.get(taskId)?.isPaused ?? false;
  }

  public getTaskById(taskId: string): Task | undefined {
    return this.activeTasks.get(taskId)?.getTask();
  }

  public getAllActiveTasks(): Task[] {
    const tasks: Task[] = [];
    this.activeTasks.forEach((worker) => {
      const task = worker.getTask();
      if (task) {
        tasks.push(task);
      }
    });
    return tasks;
  }

  public getTasksByGroup(group: string): Task[] {
    const tasksInGroup: Task[] = [];
    this.activeTasks.forEach((worker) => {
      const task = worker.getTask();
      if (task && task.group === group) {
        tasksInGroup.push(task);
      }
    });
    return tasksInGroup;
  }
}

export default TransferManager;
