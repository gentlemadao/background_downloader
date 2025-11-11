import {
  Task,
  TaskStatus,
  ExceptionType,
  TaskException,
  NotificationConfig,
  ResumeData,
  TaskWantParams,
} from './Models';
import { TaskWorker } from './TaskWorker';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import Want from '@ohos.app.ability.Want';
import { rcp } from '@kit.RemoteCommunicationKit';
import { NotificationService } from './Notifications';
import dataPreferences from '@ohos.data.preferences';

export class DownloadTaskWorker extends TaskWorker {
  private eTagHeader: string | undefined;
  private serverAcceptsRanges = false; // if true, send resume data on fail
  private tempFilePath = '';
  private requiredStartByte = 0; // required start byte within the task range
  private taskRangeStartByte = 0; // Start of the Task's download range
  private eTag: string | undefined;

  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    super(applicationContext, want);
  }

  override async doWork(): Promise<void> {
    this.startTimeout();
    const options: dataPreferences.Options = { name: 'DEFAULT' };
    this.prefs = await dataPreferences.getPreferences(this.applicationContext, options);
    console.log(`has prefs1  ${this.prefs ? "true" : " false"}`);
    const params = new TaskWantParams(this.want.parameters);
    console.log(params.keyTask);
    this.task = Task.fromObject(JSON.parse(params.keyTask));
    this.notificationConfigJsonString = params.keyNotificationConfig;
    if (this.notificationConfigJsonString) {
      this.notificationConfig = NotificationConfig.fromObject(JSON.parse(this.notificationConfigJsonString));
    }
    this.isResume = this.determineIfResume();


    console.info(DownloadTaskWorker.TAG,
      `${this.isResume ? 'Resuming' : 'Starting'} task with taskId ${this.task.taskId}`);
    await TaskWorker.processStatusUpdate(this.task, TaskStatus.RUNNING, this.prefs);
    if (!this.isResume) {
      await TaskWorker.processProgressUpdate(this.task, 0.0, this.prefs);
    }
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
    this.hasDeliveredResult = true;
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    try {
      const url = this.task.url;

      const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;

      for (const entry of this.task.headers.entries()) {
        headers[entry[0]] = entry[1];
      }

      if (this.isResume) {
        const taskRangeHeader = this.task.headers.get('Range') ?? '';
        // Implement range parsing
        // For now, assume the whole file is requested
        this.taskRangeStartByte = 0;
        const resumeRangeStart = this.taskRangeStartByte + this.requiredStartByte;
        headers['Range'] = `bytes=${resumeRangeStart}-`;
      }

      const tempDir = this.applicationContext.cacheDir;
      this.tempFilePath = `${tempDir}/com.bbflight.background_downloader${Math.random()}`;
      console.log(DownloadTaskWorker.TAG, `filepath ${this.tempFilePath}`);


      const session = rcp.createSession();

      try {
        console.log(DownloadTaskWorker.TAG, `Going to request ${url}`);

        let downloadToFile: rcp.DownloadToFile = {
          kind: 'file',
          file: (request, _) => {
            request.configuration = {
              transfer:{
                timeout:{
                  transferMs: TaskWorker.TASK_TIMEOUT_MILLIS,
                }
              },
              tracing: {
                httpEventsHandler: {
                  onHeaderReceive: (resp) => {
                    console.log(DownloadTaskWorker.TAG, `response receive ${resp['content-length']}`);
                  },
                  onDownloadProgress: (totalSize: number, transferredSize: number) => {
                    console.log(DownloadTaskWorker.TAG,
                      `response totalSize ${totalSize} transferredSize ${transferredSize}`);
                    if (this.prefs) {
                      const progress =
                        totalSize > 0 ? Math.min(1.0, (transferredSize) / (totalSize)) :
                          -1.0;
                      if (this.shouldSendProgressUpdate(progress, Date.now())) {
                        console.log(DownloadTaskWorker.TAG, `progress ${progress}`);
                        TaskWorker.processProgressUpdate(this.task, progress, this.prefs, totalSize);
                      }
                    }
                  }
                },
              }
            };
            return {
              path: this.tempFilePath
            }
          }
        } as rcp.DownloadToFile

        const resp = await session.downloadToFile(url, downloadToFile);
        console.log(DownloadTaskWorker.TAG, `request response ${url}`);

        return await this.process(resp);

      } catch (e) {
        console.error(`err: err code is ${e.code}, err message is ${JSON.stringify(e)}`);
        console.error(DownloadTaskWorker.TAG, `Error for session ${this.task.taskId}: ${e.message}`);
      } finally {
        session.close();
      }
    } catch (e) {
      const error = e as BusinessError;
      console.error(DownloadTaskWorker.TAG, `Error for taskId ${this.task.taskId}: ${error.message}`);
      this.setTaskException(error);
    }
    return TaskStatus.FAILED;
  }

  private async process(response: rcp.Response): Promise<TaskStatus> {
    this.responseStatusCode = response.statusCode;
    if (response.statusCode >= 200 && response.statusCode <= 206) {
      console.log(DownloadTaskWorker.TAG, 'handle res');
      this.eTagHeader = response.headers['ETag'] as string;
      const acceptRangesHeader = response.headers['Accept-Ranges'] as string;
      this.serverAcceptsRanges = acceptRangesHeader === 'bytes' || response.statusCode === 206;
      if (this.task.allowPause) {
        this.taskCanResume = this.serverAcceptsRanges;
        // processCanResume(this.task, this.taskCanResume);
      }
      this.isResume = this.isResume && response.statusCode === 206;

      if (this.isResume && !this.prepareResume(response)) {
        this.deleteTempFile();
        return TaskStatus.FAILED;
      }

      if (this.isResume && (this.eTagHeader !== this.eTag)) {
        this.deleteTempFile();
        console.info(DownloadTaskWorker.TAG, 'Cannot resume: ETag is not identical');
        this.taskException = new TaskException(
          ExceptionType.RESUME,
          undefined,
          'Cannot resume: ETag is not identical'
        );
        return TaskStatus.FAILED;
      }

      const destFilePath = this.task.filePath(this.applicationContext);
      if (!this.task.filename) {
        // Suggest filename
      }

      const contentLength = parseInt(response.headers['content-length'] as string ?? '-1');
      console.log(DownloadTaskWorker.TAG, `contentLength ${contentLength}`);

      try {
        // This part needs to be adapted to handle streaming the download
        // instead of waiting for the full result.
        // For now, we will simulate the download and then move the file.
        const transferResult = await this.checkTransfer(contentLength);
        if (transferResult === TaskStatus.COMPLETE) {
          // move file
          const destFile = fs.openSync(destFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.copyFileSync(this.tempFilePath, destFilePath);
          fs.closeSync(destFile);
          this.deleteTempFile();

          console.info(DownloadTaskWorker.TAG, `Successfully downloaded taskId ${this.task.taskId} to ${destFilePath}`);
          return TaskStatus.COMPLETE;
        }
        if (transferResult === TaskStatus.PAUSED && this.prefs) {
          BDPlugin.pausedTaskIds.delete(this.task.taskId);
          if (this.taskCanResume) {
            console.info(DownloadTaskWorker.TAG, `Task ${this.task.taskId} paused`);
            await TaskWorker.processResumeData(
              new ResumeData({
                task: this.task,
                data: this.tempFilePath,
                requiredStartByte: this.bytesTotal + this.startByte,
                eTag: this.eTagHeader
              }),
              this.prefs
            );
            return TaskStatus.PAUSED;
          }
        }
        return transferResult;

      } catch (e) {
        const error = e as BusinessError;
        console.log(DownloadTaskWorker.TAG, e);
        this.taskException = new TaskException(ExceptionType.FILESYSTEM, error.code, error.message);
        return TaskStatus.FAILED;
      }
    } else {
      console.info(DownloadTaskWorker.TAG, `Response code ${response.statusCode} for taskId ${this.task.taskId}`);
      this.taskException = new TaskException(
        ExceptionType.HTTP_RESPONSE,
        response.statusCode, response.request.url.toString(),
      );
      return response.statusCode === 404 ? TaskStatus.NOT_FOUND : TaskStatus.FAILED;
    }
  }

  private async checkTransfer(contentLength: number): Promise<TaskStatus> {
    try {
      const file = fs.statSync(this.tempFilePath);
      if (file.size === contentLength) {
        return TaskStatus.COMPLETE
      }
      return TaskStatus.FAILED;
    } catch (e) {
      console.error(DownloadTaskWorker.TAG, e);
      return TaskStatus.FAILED;
    }
  }

  private async transferBytes(outputQueue: rcp.INetworkOutputQueue, contentLength: number): Promise<TaskStatus> {
    try {
      const file = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      if (this.isResume) {
        fs.truncateSync(file.fd, this.startByte);
      }

      let offset = 0;
      while (offset < contentLength) {
        if (this.isCancelled) {
          console.info(DownloadTaskWorker.TAG, `Task ${this.task.taskId} cancelled`);
          fs.closeSync(file);
          this.deleteTempFile();
          return TaskStatus.CANCELED;
        }
        if (this.isTimedOut) {
          console.warn(DownloadTaskWorker.TAG, `Task ${this.task.taskId} timed out`);
          fs.closeSync(file);
          this.deleteTempFile();
          this.taskException = new TaskException(ExceptionType.GENERAL, undefined, 'Task timed out');
          return TaskStatus.FAILED;
        }
        const chunk = outputQueue.read(TaskWorker.BUFFER_SIZE);
        fs.writeSync(file.fd, chunk);
        offset += chunk.byteLength;
        this.bytesTotal = offset;
        console.log(DownloadTaskWorker.TAG, `chunk ${chunk.byteLength}`);

        if (this.prefs) {
          const progress =
            contentLength > 0 ? Math.min(1.0, (this.startByte + this.bytesTotal) / (this.startByte + contentLength)) :
              -1.0;
          console.log(DownloadTaskWorker.TAG, `progress ${progress}`);
          if (this.shouldSendProgressUpdate(progress, Date.now())) {
            await TaskWorker.processProgressUpdate(this.task, progress, this.prefs, contentLength);
          }
        }
      }

      fs.closeSync(file);
      if (this.prefs) {
        await TaskWorker.processProgressUpdate(this.task, 1.0, this.prefs, contentLength);
      }
      return TaskStatus.COMPLETE;
    } catch (e) {
      console.error(DownloadTaskWorker.TAG, e);
      return TaskStatus.FAILED;
    }
  }

  private determineIfResume(): boolean {
    const params = new TaskWantParams(this.want.parameters);
    this.requiredStartByte = params.keyStartByte ?? 0;
    if (this.requiredStartByte === 0) {
      return false;
    }
    this.eTag = params.keyETag;
    this.tempFilePath = params.keyResumeDataData ?? '';
    try {
      const stat = fs.statSync(this.tempFilePath);
      if (stat.size === this.requiredStartByte) {
        return true;
      } else {
        if (stat.size > this.requiredStartByte) {
          try {
            const file = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE);
            fs.truncateSync(file.fd, this.requiredStartByte);
            fs.closeSync(file);
            return true;
          } catch (e) {
            const error = e as BusinessError;
            console.error(DownloadTaskWorker.TAG, `Could not truncate temp file: ${error.message}`);
          }
        }
        console.info(DownloadTaskWorker.TAG, 'Partially downloaded file is corrupted, resume not possible');
      }
    } catch (e) {
      console.info(DownloadTaskWorker.TAG, 'Partially downloaded file not available, resume not possible');
    }
    return false;
  }


  private prepareResume(response: rcp.Response): boolean {
    if (this.tempFilePath.length === 0) {
      return false;
    }
    const contentRanges = response.headers['Content-Range'] as string;
    if (!contentRanges) {
      console.info(DownloadTaskWorker.TAG, 'Could not process partial response Content-Range');
      return false;
    }
    // Parse range
    const rangeParts = contentRanges.split(/[\s-\/]/);
    const start = parseInt(rangeParts[1]);
    try {
      const stat = fs.statSync(this.tempFilePath);
      this.startByte = start - this.taskRangeStartByte;
      if (this.startByte > stat.size) {
        console.info(DownloadTaskWorker.TAG,
          `Offered range not feasible: ${contentRanges} with startByte ${this.startByte}`);
        this.taskException = new TaskException(ExceptionType.RESUME, -1,
          `Offered range not feasible: ${contentRanges} with startByte ${this.startByte}`);
        return false;
      }
      const file = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE);
      fs.truncateSync(file.fd, this.startByte);
      fs.closeSync(file);
      return true;
    } catch (e) {
      const error = e as BusinessError;
      console.info(DownloadTaskWorker.TAG, `Could not truncate temp file: ${error.message}`);
      this.taskException = new TaskException(ExceptionType.RESUME, -1, 'Could not truncate temp file');
      return false;
    }
  }

  private deleteTempFile() {
    if (this.tempFilePath.length > 0) {
      try {
        fs.unlinkSync(this.tempFilePath);
      } catch (e) {
        const error = e as BusinessError;
        console.info(DownloadTaskWorker.TAG, `Could not delete temp file at ${this.tempFilePath}: ${error.message}`);
      }
    }
  }

  protected setTaskException(e: BusinessError) {
    let exceptionType = ExceptionType.GENERAL;
    if (e as BusinessError && (e.code === 200 || e.code === 201)) { // ETIMEDOUT or ENETUNREACH
      exceptionType = ExceptionType.CONNECTION;
    }
    this.taskException = new TaskException(exceptionType, -1, e.message);
  }
}