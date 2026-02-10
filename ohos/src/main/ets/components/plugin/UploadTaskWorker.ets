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
  private static readonly asciiOnlyRegEx = /^[\\x00-\\x7F]+$/;
  private static readonly jsonStringRegEx = /^\s*(\{.*\}|\[.*\])\s*$/;
  private static readonly multiValueRegEx = /^(?:"[^"]+"\s*,\s*)+"[^"]+"$/;

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


    const url = task.url;
    const stat = fs.statSync(filePath);
    const fileSize = stat.size;

    // Extract Range header information
    let start = 0;
    let end = fileSize - 1;
    const rangeHeader = task.headers.get('Range');
    if (rangeHeader) {
      const match = rangeHeader.match(/bytes=(\d+)-(\d*)/);
      if (match) {
        start = parseInt(match[1]);
        if (match[2]) {
          end = parseInt(match[2]);
        }
      } else {
        console.warn(UploadTaskWorker.TAG, `Invalid Range header ${rangeHeader}`);
        this.taskException = new TaskException(ExceptionType.GENERAL, -1, `Invalid Range header ${rangeHeader}`);
        return TaskStatus.FAILED;
      }
    }
    const contentLength = end - start + 1;

    const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;
    for (const entry of task.headers.entries()) {
      headers[entry[0]] = entry[1];
    }
    headers['Content-Length'] = contentLength.toString();
    const taskContentDisposition =
      task.headers.get('Content-Disposition') ?? task.headers.get('content-disposition');
    if (taskContentDisposition && taskContentDisposition !== "") { // Check for not empty
      headers['Content-Disposition'] = taskContentDisposition;
    } else if (!task.headers.has('Content-Disposition') && !task.headers.has('content-disposition')) {
       // Only add default if not present at all (or empty string in Android logic means omit)
       // Android: if value is "", omit. if null, set default.
       headers['Content-Disposition'] = `attachment; filename="${encodeURI(task.filename)}"`;
    }

    const session = await TaskWorker.createSession(this.prefs!, {
      headers: headers,
      requestConfiguration: {
        transfer: {
          timeout: {
            transferMs: this.prefs ? 
                await this.prefs.get(BDPlugin.KEY_CONFIG_REQUEST_TIMEOUT, TaskWorker.TASK_TIMEOUT_MILLIS) as number :
                TaskWorker.TASK_TIMEOUT_MILLIS
          }
        }
      }
    });

    // Producer: Reads the file and writes it to the queue
    const networkInputQueue = new rcp.NetworkInputQueue();
    const writeToQueue = async () => {
        let file: fs.File | undefined;
        try {
          file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
          let bytesReadTotal = 0; // Bytes read relative to the Range start
          // Seek to start
          if (start > 0) {
             // fs.readSync with offset parameter reads from file position `offset`, 
             // but here we want to seek. The offset in readSync is absolute position in file.
             // We can just maintain `currentFilePosition`
          }
          let currentFilePosition = start;

          const buffer = new ArrayBuffer(TaskWorker.BUFFER_SIZE);
          while (bytesReadTotal < contentLength) {
            if (this.isCancelled) throw new Error("Task cancelled");

            // Determine how much to read
            const remaining = contentLength - bytesReadTotal;
            const toRead = Math.min(TaskWorker.BUFFER_SIZE, remaining);
            
            const len = fs.readSync(file.fd, buffer, { offset: currentFilePosition, length: toRead });
            if (len > 0) {
              const chunkToWrite = new ArrayBuffer(len);
              new Uint8Array(chunkToWrite).set(new Uint8Array(buffer, 0, len));
              networkInputQueue.write(chunkToWrite);
              
              bytesReadTotal += len;
              currentFilePosition += len;

              if (this.prefs) {
                const progress = contentLength > 0 ? Math.min(1.0, bytesReadTotal / contentLength) : -1.0;
                if (this.shouldSendProgressUpdate(progress, Date.now())) {
                  await TaskWorker.processProgressUpdate(task, progress, this.prefs, contentLength);
                }
              }
            } else {
              break; // EOF
            }
          }
        } catch (e) {
          console.error(UploadTaskWorker.TAG, `Binary upload write error: ${e.message}`);
          networkInputQueue.close();
          session.close();
        } finally {
          if (file) fs.closeSync(file);
          networkInputQueue.close();
        }
    };
    // Start producer
    writeToQueue();

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

    // Helper to calculate UTF-8 byte length
    const textEncoder = new util.TextEncoder();
    const getByteLength = (str: string): number => {
      const result = textEncoder.encode(str);
      return result.byteLength;
    };

    // --- Pass 1: Calculate Total Size ---
    let totalContentLength = 0;
    let fieldCount = 0;
    let fileCount = 0;

    // 1.1 Fields Size
    for (const entry of task.fields.entries()) {
      const matchMulti = entry[1].match(UploadTaskWorker.multiValueRegEx);
      if (matchMulti) {
        const valueMatches = entry[1].match(/"([^"]+)"/g);
        if (valueMatches) {
          for (const valWithQuotes of valueMatches) {
            const val = valWithQuotes.substring(1, valWithQuotes.length - 1);
            const partStr = this.fieldEntry(entry[0], val);
            totalContentLength += getByteLength(partStr);
            fieldCount++;
          }
        }
      } else {
        const partStr = this.fieldEntry(entry[0], entry[1]);
        totalContentLength += getByteLength(partStr);
        fieldCount++;
      }
    }

    // 1.2 Files Data Preparation (Metadata only)
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

    fileCount = filesData.length;
    const fileSizes: number[] = [];

    for (const fileData of filesData) {
      const filePath = task.filePath(this.applicationContext, fileData.filename);
      let fileSize = 0;
      try {
        const stat = fs.statSync(filePath);
        fileSize = stat.size;
      } catch (e) {
        console.error(UploadTaskWorker.TAG, `File not found: ${filePath}`);
        // We continue, expecting write error later or 0 size
      }
      fileSizes.push(fileSize);

      let mimeType = fileData.mimeType;
      if (!mimeType || mimeType.length === 0) {
        mimeType = this.getMimeType(fileData.filename);
      }
      
      // Store resolved mimeType back for Pass 2 to avoid re-logic
      fileData.mimeType = mimeType; 

      const headerStr = this.fileHeader(fileData.fileField, fileData.filename, mimeType);
      totalContentLength += getByteLength(headerStr);
      totalContentLength += fileSize;
    }

    // 1.3 Boundaries Size
    const totalParts = fieldCount + fileCount;
    if (totalParts > 0) {
      totalContentLength += initialBoundary.length; // First boundary
      if (totalParts > 1) {
        totalContentLength += partBoundary.length * (totalParts - 1); // Middle boundaries
      }
      totalContentLength += finalBoundary.length; // End boundary
    }

    console.info(UploadTaskWorker.TAG, `Total content length: ${totalContentLength}`);

    // --- Prepare Headers & Session ---
    const headers: rcp.RequestHeaders = {} as rcp.RequestHeaders;
    for (const entry of task.headers.entries()) {
      headers[entry[0]] = entry[1];
    }
    headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
    headers['Content-Length'] = totalContentLength.toString();

    const configTimeout = this.prefs ?
      await this.prefs.get(BDPlugin.KEY_CONFIG_REQUEST_TIMEOUT, TaskWorker.TASK_TIMEOUT_MILLIS) as number :
    TaskWorker.TASK_TIMEOUT_MILLIS;

    const session = await TaskWorker.createSession(this.prefs!);

    let request = new rcp.Request(url, "POST", headers, networkInputQueue, undefined, undefined, {
      transfer: {
        timeout: {
          transferMs: configTimeout
        }
      }
    });

    // --- Pass 2: Stream Data (Producer) ---
    const writeToQueue = async () => {
      let bytesSent = 0;
      let partWritten = false;

      try {
        // 2.1 Write Fields
        for (const entry of task.fields.entries()) {
          const processField = (name: string, value: string) => {
            if (this.isCancelled) throw new Error("Task cancelled");
            
            // Write Boundary
            const boundaryStr = partWritten ? partBoundary : initialBoundary;
            const boundaryBuffer = this.stringToArrayBuffer(boundaryStr);
            networkInputQueue.write(boundaryBuffer);
            bytesSent += boundaryBuffer.byteLength;

            // Write Header & Value
            const partStr = this.fieldEntry(name, value);
            const partBuffer = this.stringToArrayBuffer(partStr);
            networkInputQueue.write(partBuffer);
            bytesSent += partBuffer.byteLength;
            
            partWritten = true;
          };

          const matchMulti = entry[1].match(UploadTaskWorker.multiValueRegEx);
          if (matchMulti) {
            const valueMatches = entry[1].match(/"([^"]+)"/g);
            if (valueMatches) {
              for (const valWithQuotes of valueMatches) {
                const val = valWithQuotes.substring(1, valWithQuotes.length - 1);
                processField(entry[0], val);
              }
            }
          } else {
            processField(entry[0], entry[1]);
          }
        }

        // 2.2 Write Files
        for (let i = 0; i < filesData.length; i++) {
          if (this.isCancelled) throw new Error("Task cancelled");
          
          // Write Boundary
          const boundaryStr = partWritten ? partBoundary : initialBoundary;
          const boundaryBuffer = this.stringToArrayBuffer(boundaryStr);
          networkInputQueue.write(boundaryBuffer);
          bytesSent += boundaryBuffer.byteLength;
          partWritten = true;

          // Write File Header
          const fileData = filesData[i];
          const headerStr = this.fileHeader(fileData.fileField, fileData.filename, fileData.mimeType);
          const headerBuffer = this.stringToArrayBuffer(headerStr);
          networkInputQueue.write(headerBuffer);
          bytesSent += headerBuffer.byteLength;

          // Stream File Content
          const filePath = task.filePath(this.applicationContext, fileData.filename);
          const fileSize = fileSizes[i];
          let file: fs.File | undefined;
          try {
            file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
            let bytesReadInFile = 0;
            const buffer = new ArrayBuffer(TaskWorker.BUFFER_SIZE);
            
            while (bytesReadInFile < fileSize) {
              if (this.isCancelled) throw new Error("Task cancelled");
              
              if (networkInputQueue.getFreeSpace() > TaskWorker.BUFFER_SIZE) {
                const len = fs.readSync(file.fd, buffer);
                if (len > 0) {
                  // Must copy because fs.readSync reuses buffer, but networkInputQueue might be async processing?
                  // Actually strict concurrency sharing in ArkTS often requires copying or transfer.
                  // rcp.NetworkInputQueue.write takes ArrayBuffer.
                  const chunkToWrite = new ArrayBuffer(len);
                  new Uint8Array(chunkToWrite).set(new Uint8Array(buffer, 0, len));
                  networkInputQueue.write(chunkToWrite);
                  
                  bytesReadInFile += len;
                  bytesSent += len;

                  if (this.prefs) {
                    const progress = totalContentLength > 0 ? Math.min(1.0, bytesSent / totalContentLength) : 0;
                    if (this.shouldSendProgressUpdate(progress, Date.now())) {
                      await TaskWorker.processProgressUpdate(task, progress, this.prefs, totalContentLength);
                    }
                  }
                } else {
                  break; // EOF
                }
              } else {
                await delay(30); // Backpressure handling
              }
            }
          } catch(err) {
             console.error(UploadTaskWorker.TAG, `File read error: ${err}`);
             throw err as Error;
          } finally {
            if (file) fs.closeSync(file);
          }
        }

        // 2.3 Write Final Boundary
        if (partWritten) {
          const finalBoundaryBuffer = this.stringToArrayBuffer(finalBoundary);
          networkInputQueue.write(finalBoundaryBuffer);
          bytesSent += finalBoundaryBuffer.byteLength;
        }

      } catch (e) {
        console.error(UploadTaskWorker.TAG, `Upload stream error: ${e.message}`);
        networkInputQueue.close();
        session.close();
      }
    };

    // Start producer (fire and forget, handled via queue interaction)
    writeToQueue().catch((err: BusinessError) => {
      console.error(UploadTaskWorker.TAG, `Unhandled error in writeToQueue: ${err.message}`);
    });

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
      networkInputQueue.close();
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
    let header = `Content-Disposition: form-data; name=\"${this.browserEncode(name)}\"`;
    
    if (value.match(UploadTaskWorker.jsonStringRegEx)) {
      header += `${lineFeed}Content-Type: application/json; charset=utf-8`;
    } else if (!value.match(UploadTaskWorker.asciiOnlyRegEx)) {
      header += `${lineFeed}Content-Type: text/plain; charset=utf-8${lineFeed}Content-Transfer-Encoding: binary`;
    }
    
    return `${header}${lineFeed}${lineFeed}${value}`;
  }

  private fileHeader(fileField: string, filename: string, mimeType: string): string {
    const lineFeed = UploadTaskWorker.lineFeed;
    let header =
      `Content-Disposition: form-data; name=\"${this.browserEncode(fileField)}\"; filename=\"${this.browserEncode(filename)}\"${lineFeed}`;
    header += `Content-Type: ${mimeType}${lineFeed}`;
    console.info(UploadTaskWorker.TAG, `fileHeaderParts ${header}`);
    return `${header}${lineFeed}`; // Two line feeds after headers
  }

  private getMimeType(filename: string): string {
    const ext = filename.split('.').pop()?.toLowerCase();
    switch (ext) {
      case 'txt': return 'text/plain';
      case 'html': return 'text/html';
      case 'json': return 'application/json';
      case 'png': return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'gif': return 'image/gif';
      case 'mp4': return 'video/mp4';
      case 'mp3': return 'audio/mpeg';
      case 'pdf': return 'application/pdf';
      default: return 'application/octet-stream';
    }
  }

  private escapeMultipartParameter(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  }

  private browserEncode(value: string): string {
    return value.replace(/\r\n|\r|\n/g, "%0D%0A").replace(/"/g, "%22");
  }

  private stringToArrayBuffer(str: string): ArrayBuffer {
    const textEncoder = new util.TextEncoder();
    const uint8Array = textEncoder.encode(str);
    return uint8Array.buffer as ArrayBuffer;
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
