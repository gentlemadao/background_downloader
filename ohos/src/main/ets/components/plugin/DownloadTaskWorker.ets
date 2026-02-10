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
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import { Want } from '@kit.AbilityKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { NotificationService } from './Notifications';
import { preferences } from '@kit.ArkData';

export class DownloadTaskWorker extends TaskWorker {
  private eTagHeader: string | undefined;
  private serverAcceptsRanges = false; // if true, send resume data on fail
  private tempFilePath = '';
  private requiredStartByte = 0; // required start byte within the task range
  private taskRangeStartByte = 0; // Start of the Task's download range
  private eTag: string | undefined;
  private chunkFilePath = '';

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
      this.notificationConfigJsonString = params.keyNotificationConfig;
      if (this.notificationConfigJsonString) {
        this.notificationConfig = NotificationConfig.fromObject(JSON.parse(this.notificationConfigJsonString) as ESObject);
      }
      this.isResume = this.determineIfResume();


      console.info(DownloadTaskWorker.TAG,
        `${this.isResume ? 'Resuming' : 'Starting'} task with taskId ${this.task?.taskId}`);
      if (this.task) {
        await TaskWorker.processStatusUpdate(this.task, TaskStatus.RUNNING, this.prefs);
        if (!this.isResume) {
          await TaskWorker.processProgressUpdate(this.task, 0.0, this.prefs);
        }
      }
      NotificationService.updateNotification(this, TaskStatus.RUNNING);

      const status = await this.doTaskInternal();

      if (this.task) {
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
    } catch (e) {
      const error = e as BusinessError;
      console.error(DownloadTaskWorker.TAG, `Fatal error in doWork: ${error.message}`);
    } finally {
      this.hasDeliveredResult = true;
    }
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    const task = this.task;
    if (!task || !this.prefs) {
      return TaskStatus.FAILED;
    }
    try {
      const url = task.url;
      const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;

      for (const entry of task.headers.entries()) {
        headers[entry[0]] = entry[1];
      }

      if (this.isResume) {
        this.taskRangeStartByte = 0;
        const resumeRangeStart = this.taskRangeStartByte + this.requiredStartByte;
        headers['Range'] = `bytes=${resumeRangeStart}-`;
        this.chunkFilePath = `${this.tempFilePath}.part`;
      } else {
        const tempDir = this.applicationContext.cacheDir;
        this.tempFilePath = `${tempDir}/com.bbflight.background_downloader${Math.random()}`;
        this.chunkFilePath = this.tempFilePath;
      }

      const configTimeout = await this.prefs.get(BDPlugin.KEY_CONFIG_REQUEST_TIMEOUT, TaskWorker.TASK_TIMEOUT_MILLIS) as number;

      const session = await TaskWorker.createSession(this.prefs!);

      try {
        console.info(DownloadTaskWorker.TAG, `Going to request ${url}`);

        let downloadToFile: rcp.DownloadToFile = {
          kind: 'file',
          file: (request, _) => {
            const transferConfig: rcp.TransferConfiguration = {
              timeout: {
                transferMs: configTimeout
              }
            };
            request.configuration = {
              transfer: transferConfig,
              tracing: {
                httpEventsHandler: {
                  onHeaderReceive: (resp) => {
                    console.info(DownloadTaskWorker.TAG, `response receive ${resp['content-length']}`);
                  },
                  onDownloadProgress: (totalSize: number, transferredSize: number) => {
                    if (this.prefs && task) {
                      const totalExpected = this.isResume ? this.requiredStartByte + totalSize : totalSize;
                      const transferredTotal = this.isResume ? this.requiredStartByte + transferredSize : transferredSize;
                      const progress = totalExpected > 0 ? Math.min(1.0, transferredTotal / totalExpected) : -1.0;
                      if (this.shouldSendProgressUpdate(progress, Date.now())) {
                        TaskWorker.processProgressUpdate(task, progress, this.prefs!, totalExpected);
                      }
                    }
                  }
                },
              }
            };
            return { path: this.chunkFilePath }
          }
        } as rcp.DownloadToFile

        const resp = await session.downloadToFile(url, downloadToFile);
        return await this.process(resp);

      } catch (e) {
        console.error(DownloadTaskWorker.TAG, `Session error: ${(e as BusinessError).message}`);
      } finally {
        session.close();
      }
    } catch (e) {
      const error = e as BusinessError;
      console.error(DownloadTaskWorker.TAG, `Error for taskId ${task.taskId}: ${error.message}`);
      this.setTaskException(error);
    }
    return TaskStatus.FAILED;
  }

  private async process(response: rcp.Response): Promise<TaskStatus> {
    const task = this.task;
    if (!task) {
      return TaskStatus.FAILED;
    }
    this.responseStatusCode = response.statusCode;
    if (response.statusCode >= 200 && response.statusCode <= 206) {
      this.eTagHeader = (response.headers['ETag'] || response.headers['etag']) as string;
      const acceptRangesHeader = (response.headers['Accept-Ranges'] || response.headers['accept-ranges']) as string;
      this.serverAcceptsRanges = acceptRangesHeader === 'bytes' || response.statusCode === 206;
      if (task.allowPause) {
        this.taskCanResume = this.serverAcceptsRanges;
      }
      this.isResume = this.isResume && response.statusCode === 206;

      if (this.isResume && !this.prepareResume(response)) {
        this.deleteTempFile();
        return TaskStatus.FAILED;
      }

      if (this.isResume) {
        if (this.eTagHeader !== this.eTag) {
          this.deleteTempFile();
          this.taskException = new TaskException(
            ExceptionType.RESUME,
            undefined,
            'Cannot resume: ETag is not identical'
          );
          return TaskStatus.FAILED;
        }
        
        // Append chunk to main temp file
        try {
            const chunkStat = fs.statSync(this.chunkFilePath);
            const chunkContentLength = parseInt(response.headers['content-length'] as string ?? '-1');
            if (chunkContentLength !== -1 && chunkStat.size !== chunkContentLength) {
                 // Incomplete chunk
                 this.deleteTempFile(); // deletes chunkFilePath too if implemented correctly? No, deleteTempFile only handles tempFilePath.
                 try { fs.unlinkSync(this.chunkFilePath); } catch(e) {}
                 return TaskStatus.FAILED;
            }

            const chunkFile = fs.openSync(this.chunkFilePath, fs.OpenMode.READ_ONLY);
            const mainFile = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
            
            // Efficient copy buffer
            const buffer = new ArrayBuffer(4096);
            let bytesRead = 0;
            let totalBytesCopied = 0;
            while ((bytesRead = fs.readSync(chunkFile.fd, buffer)) > 0) {
               fs.writeSync(mainFile.fd, buffer, { length: bytesRead });
               totalBytesCopied += bytesRead;
            }
            fs.closeSync(chunkFile);
            fs.closeSync(mainFile);
            fs.unlinkSync(this.chunkFilePath);
            
            // Update this.tempFilePath size implicitly for checkTransfer?
            // checkTransfer uses this.tempFilePath.
        } catch (e) {
            const error = e as BusinessError;
            console.error(DownloadTaskWorker.TAG, `Resume append error: ${error.message}`);
            this.taskException = new TaskException(ExceptionType.FILESYSTEM, error.code, error.message);
            this.deleteTempFile();
            try { fs.unlinkSync(this.chunkFilePath); } catch(e) {}
            return TaskStatus.FAILED;
        }
      } else {
        // Non-resume case: chunkFilePath IS tempFilePath.
        // But we should verify size.
      }

      const destFilePath = task.filePath(this.applicationContext);
      // For resume, contentLength is of the CHUNK.
      // Total size check should be against expected total?
      // Or just trust the append + checkTransfer?
      
      const contentLength = parseInt(response.headers['content-length'] as string ?? '-1');
      // If resume, contentLength is partial.
      // checkTransfer checks this.tempFilePath size.
      // If we appended, this.tempFilePath size should be original + chunk.
      // And we need to know TOTAL expected size?
      // HTTP 206 Content-Range: bytes start-end/total
      let totalSize = contentLength;
      if (this.isResume) {
          const contentRange = response.headers['content-range'] || response.headers['Content-Range'];
          if (contentRange) {
              const match = (contentRange as string).match(/\/(\d+)/);
              if (match) {
                  totalSize = parseInt(match[1]);
              }
          } else {
              totalSize = this.requiredStartByte + contentLength; 
          }
      }

      try {
        const transferResult = await this.checkTransfer(totalSize);
        if (transferResult === TaskStatus.COMPLETE) {
          const destFile = fs.openSync(destFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.copyFileSync(this.tempFilePath, destFilePath);
          fs.closeSync(destFile);
          this.deleteTempFile();
          console.info(DownloadTaskWorker.TAG, `Successfully downloaded taskId ${task.taskId} to ${destFilePath}`);
          return TaskStatus.COMPLETE;
        }
        if (transferResult === TaskStatus.PAUSED && this.prefs) {
          BDPlugin.pausedTaskIds.delete(task.taskId);
          if (this.taskCanResume) {
            await TaskWorker.processResumeData(
              new ResumeData({
                task: task,
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
        console.error(DownloadTaskWorker.TAG, e);
        this.taskException = new TaskException(ExceptionType.FILESYSTEM, error.code, error.message);
        return TaskStatus.FAILED;
      }
    } else {
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
      }
    } catch (e) {
      // Not possible to resume
    }
    return false;
  }


  private prepareResume(response: rcp.Response): boolean {
    if (this.tempFilePath.length === 0) {
      return false;
    }
    const contentRanges = (response.headers['Content-Range'] || response.headers['content-range']) as string;
    if (!contentRanges) {
      return false;
    }
    const rangeParts = contentRanges.split(/[\s-\/]/);
    const start = parseInt(rangeParts[1]);
    try {
      const stat = fs.statSync(this.tempFilePath);
      this.startByte = start - this.taskRangeStartByte;
      if (this.startByte > stat.size) {
        return false;
      }
      const file = fs.openSync(this.tempFilePath, fs.OpenMode.READ_WRITE);
      fs.truncateSync(file.fd, this.startByte);
      fs.closeSync(file);
      return true;
    } catch (e) {
      return false;
    }
  }

  private deleteTempFile() {
    if (this.tempFilePath.length > 0) {
      try {
        fs.unlinkSync(this.tempFilePath);
      } catch (e) {
        // Ignore
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