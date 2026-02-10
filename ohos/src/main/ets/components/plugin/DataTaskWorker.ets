import {
  Task,
  TaskStatus,
  ExceptionType,
  TaskException,
  TaskWantParams,
} from './Models';
import { TaskWorker } from './TaskWorker';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import { Want } from '@kit.AbilityKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { NotificationService } from './Notifications';

export class DataTaskWorker extends TaskWorker {
  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    super(applicationContext, want);
  }

  override async doWork(): Promise<void> {
    try {
      this.startTimeout();
      const options: preferences.Options = { name: 'DEFAULT' };
      this.prefs = await preferences.getPreferences(this.applicationContext, options);
      
      const params = new TaskWantParams(this.want.parameters);
      this.task = Task.fromObject(JSON.parse(params.keyTask) as ESObject);
      
      const task = this.task;
      if (!task) {
        return;
      }

      console.info(DataTaskWorker.TAG, `Starting data task with taskId ${task.taskId}`);
      await TaskWorker.processStatusUpdate(task, TaskStatus.RUNNING, this.prefs);
      NotificationService.updateNotification(this, TaskStatus.RUNNING);

      const status = await this.doTaskInternal();

      await TaskWorker.processStatusUpdate(
        task,
        status,
        this.prefs,
        this.taskException,
        this.responseBody,
        undefined, // responseHeaders
        this.responseStatusCode,
        undefined, // mimeType
        undefined, // charSet
        this.applicationContext
      );
      
      BDPlugin.holdingQueue?.taskFinished(task);
      
    } catch (e) {
      const error = e as BusinessError;
      console.error(DataTaskWorker.TAG, `Fatal error in DataTaskWorker: ${error.message}`);
    } finally {
      this.hasDeliveredResult = true;
    }
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    const task = this.task;
    if (!task || !this.prefs) return TaskStatus.FAILED;

    const configTimeout = await this.prefs.get(BDPlugin.KEY_CONFIG_REQUEST_TIMEOUT, TaskWorker.TASK_TIMEOUT_MILLIS) as number;

    // 创建最基础的 Session，不包含可能引起类型错误的嵌套字面量
    const session = await TaskWorker.createSession(this.prefs!);
    try {
      const url = task.url;
      const method = task.httpRequestMethod.toUpperCase();
      const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;
      for (const entry of task.headers.entries()) {
        headers[entry[0]] = entry[1];
      }

      const request = new rcp.Request(url, method);
      request.headers = headers;
      
      // 仅设置顶层支持的超时
      request.configuration = {
        transfer: {
            timeout: {
                transferMs: configTimeout
            }
        }
      };
      
      if (method === 'POST' && task.post) {
          request.content = task.post;
      }

      const response = await session.fetch(request);

      this.responseStatusCode = response.statusCode;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body) {
          this.responseBody = new util.TextDecoder().decodeToString(new Uint8Array(response.body));
        }
        return TaskStatus.COMPLETE;
      } else {
        this.taskException = new TaskException(ExceptionType.HTTP_RESPONSE, response.statusCode, "HTTP Error");
        return TaskStatus.FAILED;
      }
    } catch (e) {
      const error = e as BusinessError;
      console.error(DataTaskWorker.TAG, `Data task error: ${error.message}`);
      this.setTaskException(error);
      return TaskStatus.FAILED;
    } finally {
      session.close();
    }
  }
}
