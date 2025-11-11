import { MethodResult } from '@ohos/flutter_ohos';
import { preferences } from '@kit.ArkData';
import { EnqueueItem } from './HoldingQueue';
import { Task, TaskStatus, TaskParams, NotificationConfig } from './Models';
import { TaskWorker } from './TaskWorker';
import BDPlugin from './BDPlugin';

@Concurrent
export async function enqueueAllTask(
  taskListJsonString: string,
  notificationConfigListJsonString: string,
  result: MethodResult,
  plugin: BDPlugin
) {
  try {
    const taskParamsArray = JSON.parse(taskListJsonString) as TaskParams[];
    const tasks: Task[] = taskParamsArray.map((params: TaskParams) => new Task(params));
    const notificationConfigs: (NotificationConfig | null)[] = JSON.parse(notificationConfigListJsonString);
    const results: boolean[] = [];

    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      const notificationConfig = notificationConfigs[i];
      const notificationConfigJsonString = notificationConfig ? JSON.stringify(notificationConfig) : undefined;
      let success = false;
      try {
        // URL validation
        if (!task.url || !task.url.startsWith('http')) {
          console.warn(BDPlugin.TAG, `Invalid URL for taskId ${task.taskId}: ${task.url}`);
          results.push(false);
          continue;
        }

        if (!BDPlugin.holdingQueue) {
          success = await BDPlugin.doEnqueue(
            BDPlugin.uiContext!,
            task,
            notificationConfigJsonString,
            undefined,
            0,
            plugin
          );
        } else {
          console.log(BDPlugin.TAG, `Enqueueing task with id ${task.taskId} to the HoldingQueue`);
          BDPlugin.holdingQueue.add(
            new EnqueueItem(
              BDPlugin.uiContext!,
              task,
              notificationConfigJsonString,
              undefined,
              plugin
            )
          );
          const options: preferences.Options = { name: 'DEFAULT' };
          const pref_current = await preferences.getPreferences(BDPlugin.uiContext!, options);
          await TaskWorker.processStatusUpdate(task, TaskStatus.ENQUEUED, pref_current, undefined, undefined, undefined,
            undefined, undefined, undefined, BDPlugin.uiContext);
          success = true;
        }
      } catch (e) {
        console.error(`${BDPlugin.TAG} Error processing task ${task.taskId}: ${e}`);
      }
      results.push(success);
    }
    result.success(results);
  } catch (e) {
    console.error(`${BDPlugin.TAG} Error decoding JSON: ${e}`);
    result.error('JSON_DECODING_ERROR', 'Failed to decode JSON', e.toString());
  }
}
