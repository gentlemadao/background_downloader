import {
  Task,
  TaskStatus,
  ExceptionType,
  TaskException,
  NotificationConfig,
  TaskWantParams,
  Chunk
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

export class ParallelDownloadTaskWorker extends TaskWorker {
  private chunks: Chunk[] = [];
  private totalSize: number = 0;
  private downloadedBytes: number = 0;
  private fileFd: number = -1;

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
          undefined,
          this.responseStatusCode,
          undefined,
          undefined,
          this.applicationContext
        );
        NotificationService.updateNotification(this, status);
        BDPlugin.holdingQueue?.taskFinished(this.task);
      }
    } catch (e) {
      console.error(ParallelDownloadTaskWorker.TAG, `Parallel download fatal error: ${(e as BusinessError).message}`);
    } finally {
      if (this.fileFd !== -1) {
          fs.closeSync(this.fileFd);
      }
      this.hasDeliveredResult = true;
    }
  }

  private async doTaskInternal(): Promise<TaskStatus> {
    const task = this.task;
    if (!task || !this.prefs) return TaskStatus.FAILED;

    const session = await TaskWorker.createSession(this.prefs!);
    try {
      // 1. 获取文件信息 (HEAD)
      const headRequest = new rcp.Request(task.url, 'HEAD');
      const headResponse = await session.fetch(headRequest);
      
      if (headResponse.statusCode !== 200) {
          this.taskException = new TaskException(ExceptionType.HTTP_RESPONSE, headResponse.statusCode, "Head request failed");
          return TaskStatus.FAILED;
      }

      this.totalSize = parseInt(headResponse.headers['content-length'] as string ?? '0');
      const acceptRanges = headResponse.headers['accept-ranges'] as string;
      
      if (this.totalSize <= 0 || acceptRanges !== 'bytes') {
          console.warn(ParallelDownloadTaskWorker.TAG, "Server does not support ranges or size is unknown, falling back to single download is not implemented here.");
          return TaskStatus.FAILED;
      }

      // 2. 准备文件
      const destPath = task.filePath(this.applicationContext);
      // 先创建/清空文件
      const file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.truncateSync(file.fd, 0);
      this.fileFd = file.fd;

      // 3. 计算分片
      const numChunks = task.chunks > 0 ? task.chunks : 1;
      const chunkSize = Math.ceil(this.totalSize / numChunks);
      const chunkPromises: Promise<void>[] = [];

      for (let i = 0; i < numChunks; i++) {
        const start = i * chunkSize;
        const end = Math.min(start + chunkSize - 1, this.totalSize - 1);
        const chunk = new Chunk(task.taskId, task.url, task.filename, destPath, start, end);
        this.chunks.push(chunk);
        chunkPromises.push(this.downloadChunk(session, chunk));
      }

      // 4. 等待所有分片完成
      await Promise.all(chunkPromises);

      // 检查是否有分片失败
      if (this.chunks.some(c => !c.status.equals(TaskStatus.COMPLETE))) {
          return TaskStatus.FAILED;
      }

      return TaskStatus.COMPLETE;

    } catch (e) {
      const error = e as BusinessError;
      console.error(ParallelDownloadTaskWorker.TAG, `Parallel download error: ${error.message}`);
      this.setTaskException(error);
      return TaskStatus.FAILED;
    } finally {
      session.close();
    }
  }

  private async downloadChunk(session: rcp.Session, chunk: Chunk): Promise<void> {
    try {
      const request = new rcp.Request(chunk.url, 'GET');
      request.headers = { 'Range': `bytes=${chunk.chunkStart}-${chunk.chunkEnd}` } as ESObject;
      
      chunk.status = TaskStatus.RUNNING;
      
      // 使用 fetch 获取数据流或完整 body
      const response = await session.fetch(request);
      
      if (response.statusCode === 206 || response.statusCode === 200) {
        if (response.body) {
          const buffer = response.body;
          fs.writeSync(this.fileFd, buffer, { offset: chunk.chunkStart });
          
          chunk.progress = 1.0;
          chunk.status = TaskStatus.COMPLETE;
          
          // 聚合进度上报
          this.downloadedBytes += buffer.byteLength;
          const totalProgress = this.downloadedBytes / this.totalSize;
          if (this.shouldSendProgressUpdate(totalProgress, Date.now()) && this.task && this.prefs) {
              TaskWorker.processProgressUpdate(this.task, totalProgress, this.prefs, this.totalSize);
          }
        }
      } else {
        chunk.status = TaskStatus.FAILED;
      }
    } catch (e) {
      console.error(ParallelDownloadTaskWorker.TAG, `Chunk download failed: ${(e as BusinessError).message}`);
      chunk.status = TaskStatus.FAILED;
    }
  }

  protected setTaskException(e: BusinessError) {
    this.taskException = new TaskException(ExceptionType.GENERAL, -1, e.message);
  }
}