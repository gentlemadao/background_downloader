import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { NotificationConfig, Task, TaskParams, TaskStatus, TaskWantParams } from './Models';
import { NotificationService } from './Notifications';
import { TaskWorker } from './TaskWorker';

export class UpdateNotificationWorker extends TaskWorker {
  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    super(applicationContext, want);
  }

  override async doWork(): Promise<void> {
    const params = new TaskWantParams(this.want.parameters);

    this.task = Task.fromObject(JSON.parse(params.keyTask) as ESObject);
    this.notificationConfigJsonString = params.keyNotificationConfig;
    if (this.notificationConfigJsonString) {
      this.notificationConfig =  NotificationConfig.fromObject(JSON.parse(this.notificationConfigJsonString) as ESObject);
    }
    const taskStatusOrdinal = this.want.parameters?.taskStatusOrdinal as number | undefined;
    const status = taskStatusOrdinal !== undefined ? TaskStatus.from(taskStatusOrdinal) : TaskStatus.ENQUEUED;
    await NotificationService.updateNotification(this, status);
  }
}
