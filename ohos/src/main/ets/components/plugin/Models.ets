import { common } from '@kit.AbilityKit';
import { collections, lang, uri } from '@kit.ArkTS';
import { Auth } from './Auth';
import fs from '@ohos.file.fs';
import { PostArg, PostArgValue } from './QueueService';

export enum TaskWorkerKey {
  keyNotificationConfig = 'notificationConfig',
  keyResumeDataData = 'tempFilename',
  keyStartByte = 'startByte',
  keyETag = 'eTag',
  keyTask = 'Task',
  keyWorkId = 'keyWorkId'
}

export class TaskWantParams {
  keyTask: string = '';
  keyNotificationConfig: string = '';
  keyResumeDataData: string = '';
  keyStartByte: number = -1;
  keyETag: string = '';

  constructor(params?: Record<string, Object>) {
    if (params) {
      this.keyTask = params.keyTask as string ?? '';
      this.keyNotificationConfig = params.keyNotificationConfig as string ?? '';
      this.keyResumeDataData = params.keyResumeDataData as string ?? '';
      this.keyStartByte = params.keyStartByte as number ?? -1;
      this.keyETag = params.keyETag as string ?? '';
    }
  }
}

export type ISendable = lang.ISendable;

// Base directory in which files will be stored, based on their relative path.
@Sendable
export class BaseDirectory {
  public readonly value: number;

  private constructor(value: number) {
    this.value = value;
  }

  static readonly APPLICATION_DOCUMENTS: BaseDirectory = new BaseDirectory(0);
  static readonly TEMPORARY: BaseDirectory = new BaseDirectory(1);
  static readonly APPLICATION_SUPPORT: BaseDirectory = new BaseDirectory(2);
  static readonly APPLICATION_LIBRARY: BaseDirectory = new BaseDirectory(3);
  static readonly ROOT: BaseDirectory = new BaseDirectory(4);

  toJSON() {
    return this.value;
  }
}

// Type of updates requested for a group of tasks
@Sendable
export class Updates {
  public readonly value: number;

  private constructor(value: number) {
    this.value = value;
  }

  static readonly NONE: Updates = new Updates(0);
  static readonly STATUS: Updates = new Updates(1);
  static readonly PROGRESS: Updates = new Updates(2);
  static readonly STATUS_AND_PROGRESS: Updates = new Updates(3);

  toJSON() {
    return this.value;
  }
}

@Sendable
export class TaskOptions {
  beforeTaskStartRawHandle?: number;
  onTaskStartRawHandle?: number;
  onTaskFinishedRawHandle?: number;
  auth?: Auth;

  constructor(
    beforeTaskStartRawHandle?: number,
    onTaskStartRawHandle?: number,
    onTaskFinishedRawHandle?: number,
    auth?: Auth
  ) {
    this.beforeTaskStartRawHandle = beforeTaskStartRawHandle;
    this.onTaskStartRawHandle = onTaskStartRawHandle;
    this.onTaskFinishedRawHandle = onTaskFinishedRawHandle;
    this.auth = auth;
  }

  hasBeforeStartCallback(): boolean {
    return this.beforeTaskStartRawHandle != null;
  }

  hasOnStartCallback(): boolean {
    return this.onTaskStartRawHandle != null;
  }

  hasOnFinishCallback(): boolean {
    return this.onTaskFinishedRawHandle != null;
  }
}

export interface TaskParams {
  taskId?: string;
  url?: string;
  urls?: collections.Array<string>;
  filename?: string;
  headers?: collections.Map<string, string>;
  httpRequestMethod?: string;
  chunks?: number;
  post?: string;
  fileField?: string;
  mimeType?: string;
  fields?: collections.Map<string, string>;
  directory?: string;
  baseDirectory?: BaseDirectory;
  group?: string;
  updates?: Updates;
  requiresWiFi?: boolean;
  retries?: number;
  retriesRemaining?: number;
  allowPause?: boolean;
  priority?: number;
  metaData?: string;
  displayName?: string;
  creationTime?: number;
  options?: TaskOptions;
  taskType?: string;
}

@Sendable
export class Task {
  readonly taskId: string;
  readonly url: string;
  readonly urls: collections.Array<string>;
  readonly filename: string;
  readonly headers: collections.Map<string, string>;
  readonly httpRequestMethod: string;
  readonly chunks: number;
  readonly post?: string;
  readonly fileField: string;
  readonly mimeType: string;
  readonly fields: collections.Map<string, string>;
  readonly directory: string;
  readonly baseDirectory: BaseDirectory;
  readonly group: string;
  readonly updates: Updates;
  readonly requiresWiFi: boolean;
  readonly retries: number;
  readonly retriesRemaining: number;
  readonly allowPause: boolean;
  readonly priority: number;
  readonly metaData: string;
  readonly displayName: string;
  readonly creationTime: number;
  readonly options?: TaskOptions;
  readonly taskType: string;

  static fromObject(obj: ESObject): Task {
    const params: TaskParams = {};
    params.taskId = obj.taskId;
    params.url = obj.url;
    if (obj.urls) {
      params.urls = new collections.Array<string>();
      (obj.urls as Array<string>).forEach((value) => {
        params.urls!.push(value);
      });
    }
    params.filename = obj.filename;
    if (obj.headers) {
      params.headers = new collections.Map<string, string>();
      Object.keys(obj.headers).forEach((key) => {
        params.headers!.set(key, obj.headers[key]);
      });
    }
    params.httpRequestMethod = obj.httpRequestMethod;
    params.chunks = obj.chunks;
    params.post = obj.post;
    params.fileField = obj.fileField;
    params.mimeType = obj.mimeType;
    if (obj.fields) {
      params.fields = new collections.Map<string, string>();
      Object.keys(obj.fields).forEach((key) => {
        params.fields!.set(key, obj.fields[key]);
      });
    }
    params.directory = obj.directory;
    if (obj.baseDirectory !== undefined) {
      params.baseDirectory = [
        BaseDirectory.APPLICATION_DOCUMENTS,
        BaseDirectory.TEMPORARY,
        BaseDirectory.APPLICATION_SUPPORT,
        BaseDirectory.APPLICATION_LIBRARY,
        BaseDirectory.ROOT
      ].find(e => e.value === obj.baseDirectory);
    }
    params.group = obj.group;
    if (obj.updates !== undefined) {
      params.updates = [
        Updates.NONE,
        Updates.STATUS,
        Updates.PROGRESS,
        Updates.STATUS_AND_PROGRESS
      ].find(e => e.value === obj.updates);
    }
    params.requiresWiFi = obj.requiresWiFi;
    params.retries = obj.retries;
    params.retriesRemaining = obj.retriesRemaining;
    params.allowPause = obj.allowPause;
    params.priority = obj.priority;
    params.metaData = obj.metaData;
    params.displayName = obj.displayName;
    params.creationTime = obj.creationTime;
    if (obj.options) {
      params.options = new TaskOptions(
        obj.options.beforeTaskStartRawHandle,
        obj.options.onTaskStartRawHandle,
        obj.options.onTaskFinishedRawHandle,
        obj.options.auth ? new Auth(obj.options.auth.user, obj.options.auth.password) : undefined
      );
    } else {
      params.options = undefined;
    }
    params.taskType = obj.taskType;
    return new Task(params);
  }

  constructor(init: TaskParams) {
    this.taskId = init.taskId ?? Math.floor(Math.random() * 1000000).toString();
    this.url = init.url ?? '';
    this.urls = init.urls ?? new collections.Array<string>();
    this.filename = init.filename ?? '';
    this.headers = init.headers ?? new collections.Map();
    this.httpRequestMethod = init.httpRequestMethod ?? 'GET';
    this.chunks = init.chunks ?? 1;
    this.post = init.post;
    this.fileField = init.fileField ?? '';
    this.mimeType = init.mimeType ?? '';
    this.fields = init.fields ?? new collections.Map();
    this.directory = init.directory ?? '';
    this.baseDirectory = init.baseDirectory ?? BaseDirectory.APPLICATION_DOCUMENTS;
    this.group = init.group ?? '';
    this.updates = init.updates ?? Updates.NONE;
    this.requiresWiFi = init.requiresWiFi ?? false;
    this.retries = init.retries ?? 0;
    this.retriesRemaining = init.retriesRemaining ?? 0;
    this.allowPause = init.allowPause ?? false;
    this.priority = init.priority ?? 5;
    this.metaData = init.metaData ?? '';
    this.displayName = init.displayName ?? '';
    this.creationTime = init.creationTime ?? Date.now();
    this.options = init.options;
    this.taskType = init.taskType ?? '';
  }

  copyWith(params: TaskParams): Task {
    return new Task(params);
  }

  public providesProgressUpdates(): boolean {
    return this.updates.value === Updates.PROGRESS.value || this.updates.value === Updates.STATUS_AND_PROGRESS.value;
  }

  public providesStatusUpdates(): boolean {
    return this.updates.value === Updates.STATUS.value || this.updates.value === Updates.STATUS_AND_PROGRESS.value;
  }

  public isDownloadTask(): boolean {
    return this.taskType === 'DownloadTask' || this.taskType === 'UriDownloadTask' ||
      this.taskType === 'ParallelDownloadTask';
  }

  public isUploadTask(): boolean {
    return this.taskType === 'UploadTask' || this.taskType === 'UriUploadTask' || this.taskType === 'MultiUploadTask';
  }

  public isParallelDownloadTask(): boolean {
    return this.taskType === 'ParallelDownloadTask';
  }

  public  isMultiUploadTask(): boolean {
    return this.taskType === 'MultiUploadTask';
  }

  public isDataTask(): boolean {
    return this.taskType === 'DataTask';
  }

  public host(): string {
    try {
      return new uri.URI(this.url).host ?? '';
    } catch (e) {
      console.error('Models: get host error', e);
      return '';
    }
  }

  private baseDirPath(context: common.UIAbilityContext, baseDirectory: BaseDirectory): string {
    switch (baseDirectory.value) {
      case BaseDirectory.APPLICATION_DOCUMENTS.value:
        return context.filesDir;
      case BaseDirectory.TEMPORARY.value:
        return context.cacheDir;
      case BaseDirectory.APPLICATION_SUPPORT.value:
        return context.filesDir; // Approximation
      case BaseDirectory.APPLICATION_LIBRARY.value:
        return `${context.filesDir}/library`; // Approximation
      case BaseDirectory.ROOT.value:
        return ''; // Not directly supported for security reasons
      default:
        return context.filesDir;
    }
  }

  public filePath(context: common.UIAbilityContext, withFilename?: string): string {
    if (this.isMultiUploadTask() && !withFilename) {
      return '';
    }
    const filenameToUse = withFilename ?? this.filename;
    console.log('baseDirectory', this.baseDirectory.toJSON());
    const baseDirPath = this.baseDirPath(context, this.baseDirectory);
    console.log('baseDirPath', baseDirPath);
    console.log('baseDirPath length', baseDirPath.length);
    if (baseDirPath == null) {
      throw new Error('Base directory is not available');
    }
    if (this.directory) {
      const targetDir = baseDirPath + '/' + this.directory;
      try {
        if (!fs.accessSync(targetDir)) {
          fs.mkdirSync(targetDir, true);
          console.log('Directory created successfully:', targetDir);
        } else {
          console.log('The directory already exists');
        }
      } catch (error) {
        console.error('Failed to create directory:', error.code, error.message);
      }
    }
    return this.directory ? `${baseDirPath}/${this.directory}/${filenameToUse}` : `${baseDirPath}/${filenameToUse}`;
  }
}

export interface ResumeDataParams {
  task: Task;
  data: string;
  requiredStartByte: number;
  eTag?: string;
}

@Sendable
export class ResumeData {
  readonly task: Task;
  readonly data: string;
  readonly requiredStartByte: number;
  readonly eTag?: string;

  constructor(init: ResumeDataParams) {
    this.task = init.task;
    this.data = init.data;
    this.requiredStartByte = init.requiredStartByte;
    this.eTag = init.eTag;
  }

  copyWith(init: ResumeDataParams): ResumeData {
    return new ResumeData(init);
  }
}

@Sendable
export class RequireWiFi {
  public readonly value: number;

  private constructor(value: number) {
    this.value = value;
  }

  static readonly AS_SET_BY_TASK: RequireWiFi = new RequireWiFi(0);
  static readonly FOR_ALL_TASKS: RequireWiFi = new RequireWiFi(1);
  static readonly FOR_NO_TASKS: RequireWiFi = new RequireWiFi(2);

  toJSON() {
    return this.value;
  }
}

@Sendable
export class TaskStatus {
  public readonly value: number;

  constructor(value: number) {
    this.value = value;
  }

  static readonly ENQUEUED: TaskStatus = new TaskStatus(0);
  static readonly RUNNING: TaskStatus = new TaskStatus(1);
  static readonly COMPLETE: TaskStatus = new TaskStatus(2);
  static readonly NOT_FOUND: TaskStatus = new TaskStatus(3);
  static readonly FAILED: TaskStatus = new TaskStatus(4);
  static readonly CANCELED: TaskStatus = new TaskStatus(5);
  static readonly WAITING_TO_RETRY: TaskStatus = new TaskStatus(6);
  static readonly PAUSED: TaskStatus = new TaskStatus(7);
  private static readonly nonFinalStates: collections.Set<number> = new collections.Set<number>([
    TaskStatus.ENQUEUED.value,
    TaskStatus.RUNNING.value,
    TaskStatus.WAITING_TO_RETRY.value,
    TaskStatus.PAUSED.value,
  ]);

  public isFinalState(): boolean {
    return !TaskStatus.nonFinalStates.has(this.value);
  }

  public equals(other: TaskStatus): boolean {
    return other?.value === this.value;
  }

  public static from(value: number): TaskStatus {
    switch (value) {
      case 0:
        return TaskStatus.ENQUEUED;
      case 1:
        return TaskStatus.RUNNING;
      case 2:
        return TaskStatus.COMPLETE;
      case 3:
        return TaskStatus.NOT_FOUND;
      case 4:
        return TaskStatus.FAILED;
      case 5:
        return TaskStatus.CANCELED;
      case 6:
        return TaskStatus.WAITING_TO_RETRY;
      case 7:
        return TaskStatus.PAUSED;
      default:
        throw new Error(`Invalid TaskStatus value: ${value}`);
    }
  }

  toJSON() {
    return this.value;
  }
}

export interface TaskStatusUpdateParams {
  readonly task: Task;
  readonly taskStatus: TaskStatus;
  readonly exception?: TaskException;
  readonly responseBody?: string;
  readonly responseStatusCode?: number;
  readonly responseHeaders?: collections.Map<string, string>;
  readonly mimeType?: string;
  readonly charSet?: string;
}

@Sendable
export class TaskStatusUpdate {
  readonly task: Task;
  readonly taskStatus: TaskStatus;
  readonly exception?: TaskException;
  readonly responseBody?: string;
  readonly responseStatusCode?: number;
  readonly responseHeaders?: collections.Map<string, string>;
  readonly mimeType?: string;
  charSet?: string;

  constructor(params: TaskStatusUpdateParams) {
    this.task = params.task;
    this.taskStatus = params.taskStatus;
    this.exception = params.exception;
    this.responseBody = params.responseBody;
    this.responseStatusCode = params.responseStatusCode;
    this.responseHeaders = params.responseHeaders;
    this.mimeType = params.mimeType;
    this.charSet = params.charSet;
  }

  static fromObject(obj: ESObject): TaskStatusUpdate {
    let headers: collections.Map<string, string> | undefined;
    if (obj.responseHeaders) {
      headers = new collections.Map<string, string>();
      Object.keys(obj.responseHeaders).forEach((key) => {
        headers!.set(key, obj.responseHeaders[key]);
      });
    }

    const params: TaskStatusUpdateParams = {
      task: Task.fromObject(obj.task),
      taskStatus: TaskStatus.from(obj.taskStatus),
      exception: TaskException.fromObject(obj.exception),
      responseBody: obj.responseBody,
      responseStatusCode: obj.responseStatusCode,
      responseHeaders: headers,
      mimeType: obj.mimeType,
      charSet: obj.charSet,
    };
    return new TaskStatusUpdate(params);
  }

  get argList(): Array<string | number | collections.Map<string, string> | null | undefined> {
    if (this.taskStatus.equals(TaskStatus.FAILED)) {
      return [
        this.taskStatus.value,
        this.exception?.type.value,
        this.exception?.description,
        this.exception?.httpResponseCode,
        this.responseBody,
      ];
    } else {
      const isFinal = this.taskStatus.isFinalState();
      const statusIsCompleteOrNotFound =
        this.taskStatus.equals(TaskStatus.COMPLETE) || this.taskStatus.equals(TaskStatus.NOT_FOUND);

      return [
        this.taskStatus.value,
        isFinal ? this.responseBody : null,
        isFinal ? this.responseHeaders : null,
        statusIsCompleteOrNotFound ? this.responseStatusCode : null,
        isFinal ? this.mimeType : null,
        isFinal ? this.charSet : null,
      ];
    }
  }
}

@Sendable
export class ExceptionType {
  public readonly value: string;

  private constructor(value: string) {
    this.value = value;
  }

  static readonly GENERAL: ExceptionType = new ExceptionType('TaskException');
  static readonly FILESYSTEM: ExceptionType = new ExceptionType('TaskFileSystemException');
  static readonly URL: ExceptionType = new ExceptionType('TaskUrlException');
  static readonly CONNECTION: ExceptionType = new ExceptionType('TaskConnectionException');
  static readonly RESUME: ExceptionType = new ExceptionType('TaskResumeException');
  static readonly HTTP_RESPONSE: ExceptionType = new ExceptionType('TaskHttpException');
}

@Sendable
export class TaskException {
  readonly type: ExceptionType;
  readonly httpResponseCode: number;
  readonly description: string;

  constructor(type: ExceptionType, httpResponseCode: number = -1, description: string = '') {
    this.type = type;
    this.httpResponseCode = httpResponseCode;
    this.description = description;
  }

  static fromObject(obj: ESObject): TaskException | undefined {
    if (!obj) {
      return undefined;
    }
    const exceptionTypes = [
      ExceptionType.GENERAL,
      ExceptionType.FILESYSTEM,
      ExceptionType.URL,
      ExceptionType.CONNECTION,
      ExceptionType.RESUME,
      ExceptionType.HTTP_RESPONSE
    ];
    const type = exceptionTypes.find(e => e.value === obj.type) ?? ExceptionType.GENERAL;
    return new TaskException(type, obj.httpResponseCode, obj.description);
  }
}

@Sendable
export class TaskProgressUpdate {
  readonly task: Task;
  readonly progress: number;
  readonly expectedFileSize: number;

  constructor(task: Task, progress: number, expectedFileSize: number) {
    this.task = task;
    this.progress = progress;
    this.expectedFileSize = expectedFileSize;
  }
}

@Sendable
export class TaskNotification {
  readonly title: string;
  readonly body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }

  static fromObject(obj: ESObject): TaskNotification | undefined {
    if (!obj) {
      return undefined;
    }
    return new TaskNotification(obj.title, obj.body);
  }
}

@Sendable
export class NotificationConfig {
  readonly running?: TaskNotification;
  readonly complete?: TaskNotification;
  readonly error?: TaskNotification;
  readonly paused?: TaskNotification;
  readonly canceled?: TaskNotification;
  readonly progressBar: boolean;
  readonly tapOpensFile: boolean;
  readonly groupNotificationId: string;

  constructor(
    running?: TaskNotification,
    complete?: TaskNotification,
    error?: TaskNotification,
    paused?: TaskNotification,
    canceled?: TaskNotification,
    progressBar: boolean = false,
    tapOpensFile: boolean = false,
    groupNotificationId: string = ''
  ) {
    this.running = running;
    this.complete = complete;
    this.error = error;
    this.paused = paused;
    this.canceled = canceled;
    this.progressBar = progressBar;
    this.tapOpensFile = tapOpensFile;
    this.groupNotificationId = groupNotificationId;
  }

  static fromObject(obj: ESObject): NotificationConfig {
    return new NotificationConfig(
      TaskNotification.fromObject(obj.running),
      TaskNotification.fromObject(obj.complete),
      TaskNotification.fromObject(obj.error),
      TaskNotification.fromObject(obj.paused),
      TaskNotification.fromObject(obj.canceled),
      obj.progressBar,
      obj.tapOpensFile,
      obj.groupNotificationId
    );
  }
}