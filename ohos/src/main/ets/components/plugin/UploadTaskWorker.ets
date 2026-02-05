import { Task, TaskStatus, ExceptionType, TaskException, TaskWantParams } from './Models';
import { TaskWorker } from './TaskWorker';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import BDPlugin from './BDPlugin';
import { Want } from '@kit.AbilityKit';
import { NotificationService } from './Notifications';
import { preferences } from '@kit.ArkData';
import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';

interface FileField {
  fileField: string;
  filename: string;
  mimeType: string;
}

export class UploadTaskWorker extends TaskWorker {
  private static readonly boundary = '-----background_downloader-akjhfw281onqciyhnIk';
  private static readonly lineFeed = '\r\n';

  constructor(applicationContext: common.UIAbilityContext, want: Want) {
    super(applicationContext, want);
  }

  override async doWork(): Promise<void> {
    try {
      this.startTimeout();
      const options: preferences.Options = { name: 'DEFAULT' };
      this.prefs = await preferences.getPreferences(this.applicationContext, options);
      const params = new TaskWantParams(this.want.parameters as Record<string, Object>);
      this.task = Task.fromObject(JSON.parse(params.keyTask) as ESObject);
      this.notificationConfigJsonString = params.keyNotificationConfig;

      console.info(UploadTaskWorker.TAG, `Starting upload task with taskId ${this.task?.taskId}`);
      if (this.task) {
        await TaskWorker.processStatusUpdate(this.task, TaskStatus.RUNNING, this.prefs);
        await TaskWorker.processProgressUpdate(this.task, 0.0, this.prefs);
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
          this.responseHeaders,
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
      console.error(UploadTaskWorker.TAG, `Fatal error in doWork: ${error.message}`);
    } finally {
      this.hasDeliveredResult = true;
    }
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    const task = this.task;
    if (!task) {
      return TaskStatus.FAILED;
    }
    try {
      console.info(UploadTaskWorker.TAG, task.post);
      if (task.post?.toLowerCase() === 'binary') {
        return await this.processBinaryUpload();
      } else {
        return await this.processMultipartUpload();
      }
    } catch (e) {
      const error = e as BusinessError;
      this.setTaskException(error);
      console.error(UploadTaskWorker.TAG, `Error for taskId ${task.taskId}: ${error.message}`);
      return TaskStatus.FAILED;
    }
  }

  private async processBinaryUpload(): Promise<TaskStatus> {
    const task = this.task;
    if (!task) {
      return TaskStatus.FAILED;
    }
    const filePath = task.filePath(this.applicationContext);
    const networkInputQueue = new rcp.NetworkInputQueue();

    // Producer: Reads the file and writes it to the queue
    let file: fs.File | undefined;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(filePath);
      let bytesRead = 0;
      const buffer = new ArrayBuffer(TaskWorker.BUFFER_SIZE);
      while (bytesRead < stat.size) {
        const len = fs.readSync(file.fd, buffer, { offset: bytesRead });
        if (len > 0) {
          // The queue takes ownership of the buffer, so we need to copy it
          // or create a new one for each write.
          const chunkToWrite = new ArrayBuffer(len);
          new Uint8Array(chunkToWrite).set(new Uint8Array(buffer, 0, len));
          networkInputQueue.write(chunkToWrite);
          bytesRead += len;

          if (this.prefs) {
            const progress =
              stat.size > 0 ? Math.min(1.0, (this.startByte + bytesRead) / (this.startByte + stat.size)) :
                -1.0;
            if (this.shouldSendProgressUpdate(progress, Date.now())) {
              await TaskWorker.processProgressUpdate(task, progress, this.prefs, stat.size);
            }
          }
        } else {
          break; // End of file
        }
      }
    } catch (e) {
      console.error(UploadTaskWorker.TAG, `File read error: ${e.message}`);
      this.taskException = new TaskException(ExceptionType.FILESYSTEM, e.code,
        `File to upload does not exist or cannot be read: ${filePath}`);
    } finally {
      if (file) {
        fs.closeSync(file);
      }
      networkInputQueue.close();
    }


    // Consumer: The rcp engine reads from the queue and uploads

    const url = task.url;
    const stat = fs.statSync(filePath);
    const fileSize = stat.size;

    const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;
    for (const entry of task.headers.entries()) {
      headers[entry[0]] = entry[1];
    }
    headers['Content-Length'] = fileSize.toString();
    const taskContentDisposition =
      task.headers.get('Content-Disposition') ?? task.headers.get('content-disposition');
    if (taskContentDisposition !== "") {
      headers['Content-Disposition'] =
        taskContentDisposition ?? `attachment; filename="${encodeURI(task.filename)}"`;
    }

    const session = rcp.createSession({
      headers: headers,
    });
    try {
      const response = await session.post(url, networkInputQueue);
      return await this.process(response);
    } catch (e) {
      const error = e as BusinessError;
      this.setTaskException(error);
      console.error(UploadTaskWorker.TAG, `Upload error for taskId ${task.taskId}: ${error.message}`);
      return TaskStatus.FAILED;
    } finally {
      session.close();
    }
  }

  private async processMultipartUpload(): Promise<TaskStatus> {
    const task = this.task;
    if (!task) {
      return TaskStatus.FAILED;
    }
    const networkInputQueue = new rcp.NetworkInputQueue();
    const url = task.url;
    const boundary = UploadTaskWorker.boundary;
    const lineFeed = UploadTaskWorker.lineFeed;

    const initialBoundary = `--${boundary}${lineFeed}`;
    const partBoundary = `${lineFeed}--${boundary}${lineFeed}`;
    const finalBoundary = `${lineFeed}--${boundary}--${lineFeed}`;

    // The producer logic runs in a separate, non-awaited promise.
    // It calculates the total size, prepares headers, and then streams
    // the body to the queue.

    // 1. Calculate total size and prepare all parts
    // Fields
    const fieldParts: ArrayBuffer[] = [];
    let fieldsSize = 0;
    for (const entry of task.fields.entries()) {
      const part = this.stringToArrayBuffer(this.fieldEntry(entry[0], entry[1]));
      fieldParts.push(part);
      fieldsSize += part.byteLength;
    }

    // Files
    const filesData: FileField[] = [];
    if (task.isMultiUploadTask()) {
      const fileFields = JSON.parse(task.fileField) as string[];
      const filenames = JSON.parse(task.filename) as string[];
      const mimeTypes = JSON.parse(task.mimeType) as string[];
      for (let i = 0; i < filenames.length; i++) {
        filesData.push({
          fileField: fileFields[i],
          filename: filenames[i],
          mimeType: mimeTypes[i]
        });
      }
    } else {
      filesData.push({
        fileField: task.fileField,
        filename: task.filename,
        mimeType: task.mimeType
      });
    }

    const fileHeaderParts: ArrayBuffer[] = [];
    const fileSizes: number[] = [];
    let filesContentSize = 0;
    for (const fileData of filesData) {
      const filePath = task.filePath(this.applicationContext, fileData.filename);
      const stat = fs.statSync(filePath);
      const fileSize = stat.size;

      fileSizes.push(fileSize);
      filesContentSize += fileSize;

      const fileHeaderPart =
        this.stringToArrayBuffer(this.fileHeader(fileData.fileField, fileData.filename, fileData.mimeType));
      fileHeaderParts.push(fileHeaderPart);
    }

    // Calculate total content length
    let totalContentLength = 0;
    if (fieldParts.length > 0 || filesData.length > 0) {
      totalContentLength += initialBoundary.length;
      totalContentLength += fieldParts.reduce((sum, part) => sum + part.byteLength, 0);
      if (fieldParts.length > 1) {
        totalContentLength += partBoundary.length * (fieldParts.length - 1);
      }
      if (filesData.length > 0 && fieldParts.length > 0) {
        totalContentLength += partBoundary.length;
      }
      totalContentLength += fileHeaderParts.reduce((sum, part) => sum + part.byteLength, 0);
      totalContentLength += fileSizes.reduce((sum, size) => sum + size, 0);
      if (filesData.length > 1) {
        totalContentLength += partBoundary.length * (filesData.length - 1);
      }
      totalContentLength += finalBoundary.length;
    }

    // 2. Prepare headers object, as requested
    const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;
    for (const entry of task.headers.entries()) {
      headers[entry[0]] = entry[1];
    }
    headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
    headers['Content-Length'] = totalContentLength.toString();

    const session = rcp.createSession();

    let request = new rcp.Request(url, "POST", headers, networkInputQueue, undefined, undefined, {
      transfer: {
        timeout: {
          transferMs: TaskWorker.TASK_TIMEOUT_MILLIS
        }
      }
    });

    const writeToQueue = async () => {
      let bytesSent = 0;
      try {
        let partWritten = false;

        console.info(UploadTaskWorker.TAG, `fieldParts length ${fieldParts.length}`);

        // 写入表单字段
        for (const part of fieldParts) {
          const boundaryStr = partWritten ? partBoundary : initialBoundary;
          const boundaryBuffer = this.stringToArrayBuffer(boundaryStr);
          networkInputQueue.write(boundaryBuffer);
          bytesSent += boundaryBuffer.byteLength;

          networkInputQueue.write(part);
          bytesSent += part.byteLength;
          partWritten = true;
        }

        // Write files
        for (let i = 0; i < filesData.length; i++) {
          const boundaryStr = partWritten ? partBoundary : initialBoundary;
          const boundaryBuffer = this.stringToArrayBuffer(boundaryStr);
          networkInputQueue.write(boundaryBuffer);
          bytesSent += boundaryBuffer.byteLength;
          partWritten = true;

          // 写入文件头
          networkInputQueue.write(fileHeaderParts[i]);
          bytesSent += fileHeaderParts[i].byteLength;
          console.info(UploadTaskWorker.TAG, "fileHeaderParts send ",
            `${new util.TextDecoder().decodeToString(new Uint8Array(fileHeaderParts[i]))}`);

          // 分块写入文件内容
          const filePath = task.filePath(this.applicationContext, filesData[i].filename);
          const fileSize = fileSizes[i];
          let file: fs.File | undefined;
          try {
            file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
            let bytesReadInFile = 0; // Track bytes read for the current file
            const buffer = new ArrayBuffer(TaskWorker.BUFFER_SIZE);
            while (bytesReadInFile < fileSize) {
              if (this.isCancelled) {
                break;
              }
              console.info(UploadTaskWorker.TAG, "upload task bytesRead ", bytesReadInFile);
              if (networkInputQueue.getFreeSpace() > TaskWorker.BUFFER_SIZE) {
                const len = fs.readSync(file.fd, buffer);
                if (len > 0) {
                  const chunkToWrite = new ArrayBuffer(len);
                  new Uint8Array(chunkToWrite).set(new Uint8Array(buffer, 0, len));
                  networkInputQueue.write(chunkToWrite);
                  bytesReadInFile += len;
                  bytesSent += len; // Accumulate total bytes sent

                  if (this.prefs) {
                    const progress = Math.min(1.0, bytesSent / totalContentLength);
                    if (this.shouldSendProgressUpdate(progress, Date.now())) {
                      await TaskWorker.processProgressUpdate(task, progress, this.prefs, totalContentLength);
                    }
                  }
                } else {
                  break; // End of file
                }
              } else {
                await delay(30);
              }
            }
          } finally {
            if (file) {
              fs.closeSync(file);
            }
          }
        }

        // 写入最终边界
        if (partWritten) {
          const finalBoundaryBuffer = this.stringToArrayBuffer(finalBoundary);
          networkInputQueue.write(finalBoundaryBuffer);
          bytesSent += finalBoundaryBuffer.byteLength;
        }

      } catch (e) {
        console.error(UploadTaskWorker.TAG,
          `Upload request error when writeToQueue for taskId ${task.taskId}: ${e.message}`);
      }
    };
    writeToQueue();

    try {
      const response = await session.fetch(request);
      return await this.process(response);
    } catch (e) {
      const error = e as (BusinessError);
      if (!this.taskException) {
        if (error instanceof TaskException) {
          this.taskException = error;
        } else {
          this.setTaskException(error);
        }
      }
      console.error(UploadTaskWorker.TAG, `Upload request error for taskId ${task.taskId}: ${error.message}`);
      return TaskStatus.FAILED;
    } finally {
      networkInputQueue.close(); // Ensure the queue is closed after all data is written
      session.close();
    }
  }

  private async process(response: rcp.Response): Promise<TaskStatus> {
    const task = this.task;
    if (!task) {
      return TaskStatus.FAILED;
    }
    this.responseStatusCode = response.statusCode;
    // this.responseHeaders = new Map(Object.entries(response.headers));
    const decoder = new util.TextDecoder();
    if (this.responseStatusCode >= 200 && this.responseStatusCode < 300) {
      if (response.body !== null && response.body !== undefined) {
        const uint8Array = new Uint8Array(response.body as ArrayBuffer);
        this.responseBody = decoder.decodeToString(uint8Array);
        console.info(UploadTaskWorker.TAG, `Response body ${this.responseBody}`);
      }
      await TaskWorker.processProgressUpdate(task, 1.0, this.prefs!);
      console.info(UploadTaskWorker.TAG, `Successfully uploaded taskId ${task.taskId}`);
      return TaskStatus.COMPLETE;
    } else {
      this.cancel();
      console.info(UploadTaskWorker.TAG, `Response code ${this.responseStatusCode} for taskId ${task.taskId}`);
      if (response.body !== null && response.body !== undefined) {
        const uint8Array = new Uint8Array(response.body as ArrayBuffer);
        this.responseBody = decoder.decodeToString(uint8Array);
        console.info(UploadTaskWorker.TAG, `Response body ${this.responseBody}`);
      }
      this.taskException = new TaskException(
        ExceptionType.HTTP_RESPONSE,
        this.responseStatusCode,
        this.responseBody
      );
      return this.responseStatusCode === 404 ? TaskStatus.NOT_FOUND : TaskStatus.FAILED;
    }
  }

  private fieldEntry(name: string, value: string): string {
    const lineFeed = UploadTaskWorker.lineFeed;
    let header = `Content-Disposition: form-data; name=\"${this.browserEncode(name)}\"${lineFeed}`;
    // Add content type for JSON strings
    if (value.trim().startsWith('{') || value.trim().startsWith('[')) {
      header += `Content-Type: application/json; charset=utf-8${lineFeed}`;
    }
    return `${header}${lineFeed}${value}`;
  }

  private fileHeader(fileField: string, filename: string, mimeType: string): string {
    const lineFeed = UploadTaskWorker.lineFeed;
    let header =
      `Content-Disposition: form-data; name=\"${this.browserEncode(fileField)}\"; filename=\"${this.browserEncode(filename)}\"${lineFeed}`;
    header += `Content-Type: ${mimeType}${lineFeed}`;
    console.info(UploadTaskWorker.TAG, `fileHeaderParts ${header}`);
    return `${header}${lineFeed}`; // Two line feeds after headers
  }

  private escapeMultipartParameter(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  }

  private browserEncode(value: string): string {
    return value.replace(/\r\n|\r|\n/g, "%0D%0A").replace(/"/g, "%22");
  }

  private stringToArrayBuffer(str: string): ArrayBuffer {
    const textEncoder = new util.TextEncoder();
    const uint8Array = textEncoder.encodeInto(str);
    return uint8Array.buffer;
  }

  protected setTaskException(e: BusinessError) {
    let exceptionType = ExceptionType.GENERAL;
    if (e.code === 200 || e.code === 201) { // ETIMEDOUT or ENETUNREACH
      exceptionType = ExceptionType.CONNECTION;
    }
    this.taskException = new TaskException(exceptionType, -1, e.message);
  }
}

const delay = (ms: number): Promise<void> => {
  return new Promise(resolve => setTimeout(resolve, ms));
};
