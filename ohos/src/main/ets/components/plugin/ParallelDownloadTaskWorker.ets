import {
  Task,
  TaskStatus,
  ExceptionType,
  TaskException,
  TaskParams,
  TaskWantParams,
} from './Models';
import { TaskWorker } from './TaskWorker';
import { common } from '@kit.AbilityKit';
import {http} from '@kit.NetworkKit';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import Want from '@ohos.app.ability.Want';
import { NotificationService } from './Notifications';
import dataPreferences from '@ohos.data.preferences';
import { DownloadTaskWorker } from './DownloadTaskWorker';
import { collections } from '@kit.ArkTS';

export class ParallelDownloadTaskWorker extends TaskWorker {
  private chunkTasks: DownloadTaskWorker[] = [];

  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    super(applicationContext, want);
  }

  override async doWork(): Promise<void> {
    const options: dataPreferences.Options = { name: 'DEFAULT' };
    this.prefs = await dataPreferences.getPreferences(this.applicationContext, options);
    const params = new TaskWantParams(this.want.parameters as Record<string, Object>);
    this.task = Task.fromObject(JSON.parse(params.keyTask));
    this.notificationConfigJsonString = params.keyNotificationConfig;

    console.info(ParallelDownloadTaskWorker.TAG, `Starting parallel download task with taskId ${this.task.taskId}`);
    await TaskWorker.processStatusUpdate(this.task, TaskStatus.RUNNING, this.prefs);
    await TaskWorker.processProgressUpdate(this.task, 0.0, this.prefs);
    NotificationService.updateNotification(this, TaskStatus.RUNNING);

    const status = await this.doTaskInternal();

    await TaskWorker.processStatusUpdate(
      this.task,
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
    if (status !== TaskStatus.FAILED || this.task.retriesRemaining === 0) {
      NotificationService.updateNotification(this, status);
    }
    if (status !== TaskStatus.CANCELED) {
      BDPlugin.holdingQueue?.taskFinished(this.task);
    }
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    try {
      // Get the total file size
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(this.task.url, { method: http.RequestMethod.HEAD });
      const contentLength = parseInt(response.header['Content-Length'] as string ?? '-1');

      if (contentLength <= 0) {
        // Fallback to a single download
        const downloadWorker = new DownloadTaskWorker(this.applicationContext, this.want);
        await downloadWorker.doWork();
        return TaskStatus.COMPLETE;
      }

      const chunkSize = Math.ceil(contentLength / this.task.chunks);
      const promises: Promise<void>[] = [];

      for (let i = 0; i < this.task.chunks; i++) {
        const start = i * chunkSize;
        const end = Math.min(start + chunkSize - 1, contentLength - 1);

        const chunkHeaders = new collections.Map(this.task.headers.entries());
        chunkHeaders.set('Range', `bytes=${start}-${end}`);

        const chunkTaskParams: TaskParams = {
          taskId: `${this.task.taskId}-chunk-${i}`,
          url: this.task.url,
          urls: this.task.urls,
          filename: this.task.filename,
          headers: chunkHeaders,
          httpRequestMethod: this.task.httpRequestMethod,
          chunks: this.task.chunks,
          post: this.task.post,
          fileField: this.task.fileField,
          mimeType: this.task.mimeType,
          fields: this.task.fields,
          directory: this.task.directory,
          baseDirectory: this.task.baseDirectory,
          group: this.task.group,
          updates: this.task.updates,
          requiresWiFi: this.task.requiresWiFi,
          retries: this.task.retries,
          retriesRemaining: this.task.retriesRemaining,
          allowPause: this.task.allowPause,
          priority: this.task.priority,
          metaData: this.task.metaData,
          displayName: this.task.displayName,
          creationTime: this.task.creationTime,
          options: this.task.options,
          taskType: this.task.taskType,
        };

        const chunkParams = new TaskWantParams();
        chunkParams.keyTask = JSON.stringify(chunkTaskParams);

        const chunkWant: Want = {
          bundleName: this.want.bundleName,
          abilityName: this.want.abilityName,
          action: 'com.bbflight.background_downloader.chunk',
          parameters: {
            keyTask: chunkParams.keyTask,
            keyNotificationConfig: chunkParams.keyNotificationConfig,
            keyResumeDataData: chunkParams.keyResumeDataData,
            keyStartByte: chunkParams.keyStartByte,
            keyETag: chunkParams.keyETag
          }
        };
        const chunkWorker = new DownloadTaskWorker(this.applicationContext, chunkWant);
        this.chunkTasks.push(chunkWorker);
        promises.push(chunkWorker.doWork());
      }

      await Promise.all(promises);

      // Combine the chunks
      const destFilePath = this.task.filePath(this.applicationContext);
      const destFile = fs.openSync(destFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      for (const chunkWorker of this.chunkTasks) {
        const chunkFilePath = chunkWorker.task.filePath(this.applicationContext);
        const chunkFile = fs.openSync(chunkFilePath, fs.OpenMode.READ_ONLY);
        const buffer = new ArrayBuffer(fs.statSync(chunkFilePath).size);
        fs.readSync(chunkFile.fd, buffer);
        fs.writeSync(destFile.fd, buffer);
        fs.closeSync(chunkFile);
        fs.unlinkSync(chunkFilePath);
      }
      fs.closeSync(destFile);


      return TaskStatus.COMPLETE;
    } catch (e) {
      const error = e as BusinessError;
      this.setTaskException(error);
      console.error(ParallelDownloadTaskWorker.TAG, `Error for taskId ${this.task.taskId}: ${error.message}`);
    }
    return TaskStatus.FAILED;
  }

  protected  setTaskException(e: BusinessError) {
    let exceptionType = ExceptionType.GENERAL;
    if (e.code === 200 || e.code === 201) { // ETIMEDOUT or ENETUNREACH
      exceptionType = ExceptionType.CONNECTION;
    }
    this.taskException = new TaskException(exceptionType, -1, e.message);
  }
}
