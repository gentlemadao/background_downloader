import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { EnqueueItem } from './HoldingQueue';
import { NotificationConfig, Task, TaskStatus } from './Models';
import { notificationManager } from '@kit.NotificationKit';
import { TaskWorker } from './TaskWorker';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';

const TAG = "NotificationService";
const NOTIFICATION_CHANNEL_ID = "background_downloader";

// Simple string hash function to get a consistent integer ID for a string
function hashCode(str: string): number {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash |= 0; // Convert to 32bit integer
  }
  return hash;
}

enum NotificationType { running, complete, error, paused, canceled }

export class NotificationService {
  private static createdNotificationChannel = false;

  /**
   * Create or update the notification for this [taskWorker]
   */
  public static async updateNotification(worker: TaskWorker, status: TaskStatus, progress: number = 2.0,
    timeRemaining: number = -1) {
    const task = worker.task;
    if (!task) {
      console.warn(TAG, "Cannot update notification: task is undefined");
      return;
    }
    const notificationType = NotificationService.notificationTypeForTaskStatus(status);
    const config = worker.notificationConfig;

    if (!config) {
      await NotificationService.cancelNotification(task.taskId);
      return;
    }

    const notification = NotificationService.notificationForType(notificationType, config);

    if (!notification) {
      await NotificationService.cancelNotification(task.taskId);
      return;
    }

    if (!NotificationService.createdNotificationChannel) {
      await NotificationService.createNotificationChannel();
    }

    const notificationId = hashCode(task.taskId);
    const title =
      NotificationService.replaceTokens(notification.title, task, progress, worker.networkSpeed, timeRemaining);
    const body =
      NotificationService.replaceTokens(notification.body, task, progress, worker.networkSpeed, timeRemaining);

    let request: notificationManager.NotificationRequest;

    const wantsProgress = config.progressBar &&
      (notificationType === NotificationType.running || notificationType === NotificationType.paused);

    if (wantsProgress) {
      worker.notificationProgress =
        (notificationType === NotificationType.paused) ? worker.notificationProgress : progress;
      const currentProgress = Math.round(worker.notificationProgress * 100);

      const isTemplateSupported =
        await notificationManager.isSupportTemplate('downloadTemplate').catch((err: BusinessError) => {
          console.error(TAG, `Failed to check template support. Code is ${err.code}, message is ${err.message}`);
          return false;
        });

      if (isTemplateSupported) {
        request = {
          id: notificationId,
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: title,
              text: body,
            }
          },
          template: {
            name: 'downloadTemplate',
            data: {
              title: title,
              fileName: task.filename,
              progressValue: currentProgress,
              progressMaxValue: 100
            }
          },
          actionButtons: await NotificationService.createActionButtons(worker, notificationType),
        };
      } else {
        // Fallback to basic text notification as requested
        request = {
          id: notificationId,
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: title,
              text: body,
            },
          },
          actionButtons: await NotificationService.createActionButtons(worker, notificationType),
        };
      }
    } else {
      request = {
        id: notificationId,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: body,
          },
        },
        actionButtons: await NotificationService.createActionButtons(worker, notificationType),
      };
    }

    try {
      await notificationManager.publish(request);
    } catch (e) {
      const error = e as BusinessError;
      console.error(TAG, `Failed to publish notification. Code: ${error.code}, Msg: ${error.message}`);
    }
  }

  public static async cancelNotification(taskId: string) {
    try {
      await notificationManager.cancel(hashCode(taskId));
    } catch (e) {
      const error = e as BusinessError;
      console.error(TAG, `Failed to cancel notification. Code: ${error.code}, Msg: ${error.message}`);
    }
  }


  private static async createActionButtons(worker: TaskWorker,
    type: NotificationType): Promise<notificationManager.NotificationActionButton[]> {
    const task = worker.task;
    if (!task) return [];
    const buttons: notificationManager.NotificationActionButton[] = [];
    const taskId = task.taskId;

    if (type === NotificationType.running) {
      buttons.push({
        title: "Cancel",
        wantAgent: await NotificationService.createWantAgent(worker, taskId, "cancel")
      });
      if (worker.taskCanResume && worker.notificationConfig?.paused) {
        buttons.push({
          title: "Pause",
          wantAgent: await NotificationService.createWantAgent(worker, taskId, "pause")
        });
      }
    }

    if (type === NotificationType.paused) {
      buttons.push({
        title: "Cancel",
        wantAgent: await NotificationService.createWantAgent(worker, taskId, "cancel")
      });
      buttons.push({
        title: "Resume",
        wantAgent: await NotificationService.createWantAgent(worker, taskId, "resume")
      });
    }
    return buttons;
  }

  private static async createWantAgent(worker: TaskWorker, taskId: string, action: string): Promise<WantAgent> {
    const want: Want = {
      action: `com.bbflight.background_downloader.${action}`,
      parameters: {
        taskId: taskId,
        taskJson: JSON.stringify(BDPlugin.holdingQueue?.taskForId(taskId) ?? {}), // Pass task details if needed
        notificationConfigJson: worker.notificationConfigJsonString ?? ""
      }
    };
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [want],
      operationType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: hashCode(`${taskId}_${action}`),
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(wantAgentInfo);
  }


  private static async createNotificationChannel() {
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      NotificationService.createdNotificationChannel = true;
    } catch (e) {
      const error = e as BusinessError;
      console.error(TAG, `Failed to add notification slot. Code is ${error.code}, Msg: ${error.message}`);
    }
  }

  private static notificationTypeForTaskStatus(status: TaskStatus): NotificationType {
    switch (status.value) {
      case TaskStatus.ENQUEUED.value:
      case TaskStatus.RUNNING.value:
        return NotificationType.running;
      case TaskStatus.COMPLETE.value:
        return NotificationType.complete;
      case TaskStatus.PAUSED.value:
        return NotificationType.paused;
      case TaskStatus.CANCELED.value:
        return NotificationType.canceled;
      default:
        return NotificationType.error;
    }
  }

  private static notificationForType(type: NotificationType, config: NotificationConfig) {
    switch (type) {
      case NotificationType.running:
        return config.running;
      case NotificationType.complete:
        return config.complete;
      case NotificationType.error:
        return config.error;
      case NotificationType.paused:
        return config.paused;
      case NotificationType.canceled:
        return config.canceled;
    }
  }

  private static replaceTokens(input: string, task: Task, progress: number, networkSpeed: number,
    timeRemaining: number): string {
    let output = input;
    output = output.replace(/{displayName}/g, task.displayName);
    output = output.replace(/{filename}/g, task.filename);
    output = output.replace(/{metadata}/g, task.metaData);

    const progressString = (progress >= 0 && progress <= 1) ? `${Math.round(progress * 100)}%` : '';
    output = output.replace(/{progress}/g, progressString);

    const speedString = networkSpeed <= 0 ? '-- MB/s' :
      networkSpeed > 1 ? `${Math.round(networkSpeed)} MB/s` : `${Math.round(networkSpeed * 1000)} kB/s`;
    output = output.replace(/{networkSpeed}/g, speedString);

    if (timeRemaining !== null) {
      const hours = Math.floor(timeRemaining / 3600000);
      const minutes = Math.floor((timeRemaining % 3600000) / 60000);
      const seconds = Math.floor((timeRemaining % 60000) / 1000);
      const timeString = timeRemaining < 0 ? '--:--' :
        hours > 0 ? `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString()
          .padStart(2, '0')}` :
          `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
      output = output.replace(/{timeRemaining}/g, timeString);
    }
    return output;
  }


  public static registerEnqueue(item: EnqueueItem, success: boolean) {
    const notificationConfigJsonString = item.notificationConfigJsonString;
    if (!notificationConfigJsonString) {
      return;
    }
    const notificationConfig = NotificationConfig.fromObject(JSON.parse(notificationConfigJsonString) as ESObject);
    const groupNotificationId = notificationConfig.groupNotificationId;
    if (groupNotificationId) {
      NotificationService.createUpdateNotificationWorker(
        item.context,
        JSON.stringify(item.task),
        notificationConfigJsonString,
        success ? TaskStatus.ENQUEUED.value : TaskStatus.FAILED.value
      );
    }
  }

  public static async createUpdateNotificationWorker(context: common.UIAbilityContext, taskJson: string,
    notificationConfigJson: string | undefined, taskStatusOrdinal: number | undefined) {
    const UpdateNotificationWorkerFile = await import('./UpdateNotificationWorker');
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      action: "com.bbflight.background_downloader.update_notification",
      parameters: {
        keyTask: taskJson,
        keyNotificationConfig: notificationConfigJson ?? '',
        taskStatusOrdinal: taskStatusOrdinal ?? 0
      }
    };
    // UpdateNotificationWorker is not a long-running task, so we can run it directly.
    const worker = new UpdateNotificationWorkerFile.UpdateNotificationWorker(context, want);
    await worker.doWork();
  }
}
