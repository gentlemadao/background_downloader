import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  Task,
  TaskStatus,
  BaseDirectory,
  Updates,
  TaskOptions,
  TaskParams,
  RequireWiFi
} from './Models';
import { Auth } from './Auth';
import { collections } from '@kit.ArkTS';

export class TaskDatabase {
  private static readonly TAG = 'TaskDatabase';
  private static readonly DB_NAME = 'background_downloader.db';
  private static readonly TABLE_NAME = 'task';
  private rdbStore: relationalStore.RdbStore | undefined = undefined;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async init(): Promise<void> {
    const STORE_CONFIG: relationalStore.StoreConfig = {
      name: TaskDatabase.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      this.rdbStore = await relationalStore.getRdbStore(this.context, STORE_CONFIG);
      
      // Development migration: Drop table to ensure schema update
      // In production, use versioning and ALTER TABLE
      // await this.rdbStore.executeSql(`DROP TABLE IF EXISTS ${TaskDatabase.TABLE_NAME}`);

      const sql = `CREATE TABLE IF NOT EXISTS ${TaskDatabase.TABLE_NAME} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        taskId TEXT UNIQUE,
        url TEXT,
        filename TEXT,
        headers TEXT,
        httpRequestMethod TEXT,
        chunks INTEGER,
        post TEXT,
        fileField TEXT,
        mimeType TEXT,
        fields TEXT,
        directory TEXT,
        baseDirectory INTEGER,
        groupName TEXT,
        updates INTEGER,
        requiresWiFi INTEGER,
        requiresCharging INTEGER,
        requiresBatteryNotLow INTEGER,
        requiresStorageNotLow INTEGER,
        requiresDeviceIdle INTEGER,
        retries INTEGER,
        retriesRemaining INTEGER,
        allowPause INTEGER,
        priority INTEGER,
        metaData TEXT,
        displayName TEXT,
        creationTime INTEGER,
        options TEXT,
        taskType TEXT,
        status INTEGER,
        progress REAL
      )`;
      await this.rdbStore.executeSql(sql);
      
      // Check if new columns exist, if not, try to add them (poor man's migration for dev)
      // Or just ignore if we assume fresh install. 
      // For now, let's assume the user will reinstall or clear data if they see DB errors.
      
      console.info(TaskDatabase.TAG, 'Database initialized successfully');
    } catch (err) {
      console.error(TaskDatabase.TAG, `Failed to init database: ${(err as BusinessError).message}`);
    }
  }

  async insertOrUpdateTask(task: Task, status?: TaskStatus, progress?: number): Promise<void> {
    if (!this.rdbStore) await this.init();
    if (!this.rdbStore) return;

    try {
      // Check if exists
      const predicates = new relationalStore.RdbPredicates(TaskDatabase.TABLE_NAME);
      predicates.equalTo('taskId', task.taskId);
      const resultSet = await this.rdbStore.query(predicates);
      const exists = resultSet.rowCount > 0;
      resultSet.close();

      const values = this.taskToValuesBucket(task);
      if (status) {
        values.status = status.value;
      }
      if (progress !== undefined) {
        values.progress = progress;
      }

      if (exists) {
        await this.rdbStore.update(values, predicates);
      } else {
        // For new tasks, default status if not provided
        if (values.status === undefined) {
            values.status = TaskStatus.ENQUEUED.value;
        }
        if (values.progress === undefined) {
            values.progress = 0.0;
        }
        await this.rdbStore.insert(TaskDatabase.TABLE_NAME, values);
      }
    } catch (err) {
      console.error(TaskDatabase.TAG, `Failed to insert/update task: ${(err as BusinessError).message}`);
    }
  }

  async loadAllTasks(): Promise<Task[]> {
    if (!this.rdbStore) await this.init();
    if (!this.rdbStore) return [];

    try {
      const predicates = new relationalStore.RdbPredicates(TaskDatabase.TABLE_NAME);
      const resultSet = await this.rdbStore.query(predicates);
      const tasks: Task[] = [];
      while (resultSet.goToNextRow()) {
        const task = this.resultSetToTask(resultSet);
        if (task) {
          tasks.push(task);
        }
      }
      resultSet.close();
      return tasks;
    } catch (err) {
      console.error(TaskDatabase.TAG, `Failed to load all tasks: ${(err as BusinessError).message}`);
      return [];
    }
  }

  async loadTasksWithStatus(status: TaskStatus): Promise<Task[]> {
      if (!this.rdbStore) await this.init();
      if (!this.rdbStore) return [];
  
      try {
        const predicates = new relationalStore.RdbPredicates(TaskDatabase.TABLE_NAME);
        predicates.equalTo('status', status.value);
        const resultSet = await this.rdbStore.query(predicates);
        const tasks: Task[] = [];
        while (resultSet.goToNextRow()) {
          const task = this.resultSetToTask(resultSet);
          if (task) {
            tasks.push(task);
          }
        }
        resultSet.close();
        return tasks;
      } catch (err) {
        console.error(TaskDatabase.TAG, `Failed to load tasks with status: ${(err as BusinessError).message}`);
        return [];
      }
    }

  async deleteTask(taskId: string): Promise<void> {
    if (!this.rdbStore) await this.init();
    if (!this.rdbStore) return;

    try {
      const predicates = new relationalStore.RdbPredicates(TaskDatabase.TABLE_NAME);
      predicates.equalTo('taskId', taskId);
      await this.rdbStore.delete(predicates);
    } catch (err) {
      console.error(TaskDatabase.TAG, `Failed to delete task: ${(err as BusinessError).message}`);
    }
  }

  private taskToValuesBucket(task: Task): relationalStore.ValuesBucket {
    const headersObj: Record<string, string> = {};
    task.headers.forEach((value, key) => {
      headersObj[key] = value;
    });

    const fieldsObj: Record<string, string> = {};
    task.fields.forEach((value, key) => {
      fieldsObj[key] = value;
    });

    let optionsStr = '';
    if (task.options) {
        // Simple serialization for TaskOptions, might need enhancement
        optionsStr = JSON.stringify(task.options);
    }

    const bucket: relationalStore.ValuesBucket = {
      taskId: task.taskId,
      url: task.url,
      filename: task.filename,
      headers: JSON.stringify(headersObj),
      httpRequestMethod: task.httpRequestMethod,
      chunks: task.chunks,
      post: task.post ?? '',
      fileField: task.fileField,
      mimeType: task.mimeType,
      fields: JSON.stringify(fieldsObj),
      directory: task.directory,
      baseDirectory: task.baseDirectory.value,
      groupName: task.group,
      updates: task.updates.value,
      requiresWiFi: task.requiresWiFi ? 1 : 0,
      requiresCharging: task.requiresCharging ? 1 : 0,
      requiresBatteryNotLow: task.requiresBatteryNotLow ? 1 : 0,
      requiresStorageNotLow: task.requiresStorageNotLow ? 1 : 0,
      requiresDeviceIdle: task.requiresDeviceIdle ? 1 : 0,
      retries: task.retries,
      retriesRemaining: task.retriesRemaining,
      allowPause: task.allowPause ? 1 : 0,
      priority: task.priority,
      metaData: task.metaData,
      displayName: task.displayName,
      creationTime: task.creationTime,
      options: optionsStr,
      taskType: task.taskType
    };
    return bucket;
  }

  private resultSetToTask(resultSet: relationalStore.ResultSet): Task | undefined {
    try {
        const taskId = resultSet.getString(resultSet.getColumnIndex('taskId'));
        const url = resultSet.getString(resultSet.getColumnIndex('url'));
        const filename = resultSet.getString(resultSet.getColumnIndex('filename'));
        const headersStr = resultSet.getString(resultSet.getColumnIndex('headers'));
        const httpRequestMethod = resultSet.getString(resultSet.getColumnIndex('httpRequestMethod'));
        const chunks = resultSet.getLong(resultSet.getColumnIndex('chunks'));
        const post = resultSet.getString(resultSet.getColumnIndex('post'));
        const fileField = resultSet.getString(resultSet.getColumnIndex('fileField'));
        const mimeType = resultSet.getString(resultSet.getColumnIndex('mimeType'));
        const fieldsStr = resultSet.getString(resultSet.getColumnIndex('fields'));
        const directory = resultSet.getString(resultSet.getColumnIndex('directory'));
        const baseDirectoryVal = resultSet.getLong(resultSet.getColumnIndex('baseDirectory'));
        const group = resultSet.getString(resultSet.getColumnIndex('groupName'));
        const updatesVal = resultSet.getLong(resultSet.getColumnIndex('updates'));
        
        const requiresWiFiVal = resultSet.getLong(resultSet.getColumnIndex('requiresWiFi'));
        
        // Handle potential missing columns if DB wasn't recreated
        let requiresChargingVal = 0;
        let requiresBatteryNotLowVal = 0;
        let requiresStorageNotLowVal = 0;
        let requiresDeviceIdleVal = 0;
        
        try { requiresChargingVal = resultSet.getLong(resultSet.getColumnIndex('requiresCharging')); } catch(e) {}
        try { requiresBatteryNotLowVal = resultSet.getLong(resultSet.getColumnIndex('requiresBatteryNotLow')); } catch(e) {}
        try { requiresStorageNotLowVal = resultSet.getLong(resultSet.getColumnIndex('requiresStorageNotLow')); } catch(e) {}
        try { requiresDeviceIdleVal = resultSet.getLong(resultSet.getColumnIndex('requiresDeviceIdle')); } catch(e) {}

        const retries = resultSet.getLong(resultSet.getColumnIndex('retries'));
        const retriesRemaining = resultSet.getLong(resultSet.getColumnIndex('retriesRemaining'));
        const allowPauseVal = resultSet.getLong(resultSet.getColumnIndex('allowPause'));
        const priority = resultSet.getLong(resultSet.getColumnIndex('priority'));
        const metaData = resultSet.getString(resultSet.getColumnIndex('metaData'));
        const displayName = resultSet.getString(resultSet.getColumnIndex('displayName'));
        const creationTime = resultSet.getLong(resultSet.getColumnIndex('creationTime'));
        const optionsStr = resultSet.getString(resultSet.getColumnIndex('options'));
        const taskType = resultSet.getString(resultSet.getColumnIndex('taskType'));

        const params: TaskParams = {
            taskId: taskId,
            url: url,
            filename: filename,
            httpRequestMethod: httpRequestMethod,
            chunks: chunks,
            post: post,
            fileField: fileField,
            mimeType: mimeType,
            directory: directory,
            group: group,
            requiresWiFi: requiresWiFiVal === 1,
            requiresCharging: requiresChargingVal === 1,
            requiresBatteryNotLow: requiresBatteryNotLowVal === 1,
            requiresStorageNotLow: requiresStorageNotLowVal === 1,
            requiresDeviceIdle: requiresDeviceIdleVal === 1,
            retries: retries,
            retriesRemaining: retriesRemaining,
            allowPause: allowPauseVal === 1,
            priority: priority,
            metaData: metaData,
            displayName: displayName,
            creationTime: creationTime,
            taskType: taskType
        };

        // Reconstruct Maps
        if (headersStr) {
            const headersMap = new collections.Map<string, string>();
            const obj = JSON.parse(headersStr) as Record<string, string>;
            Object.keys(obj).forEach(key => headersMap.set(key, obj[key]));
            params.headers = headersMap;
        }

        if (fieldsStr) {
            const fieldsMap = new collections.Map<string, string>();
            const obj = JSON.parse(fieldsStr) as Record<string, string>;
            Object.keys(obj).forEach(key => fieldsMap.set(key, obj[key]));
            params.fields = fieldsMap;
        }

        // Enums
        params.baseDirectory = [
            BaseDirectory.APPLICATION_DOCUMENTS,
            BaseDirectory.TEMPORARY,
            BaseDirectory.APPLICATION_SUPPORT,
            BaseDirectory.APPLICATION_LIBRARY,
            BaseDirectory.ROOT
        ].find(e => e.value === baseDirectoryVal) ?? BaseDirectory.APPLICATION_DOCUMENTS;

        params.updates = [
            Updates.NONE,
            Updates.STATUS,
            Updates.PROGRESS,
            Updates.STATUS_AND_PROGRESS
        ].find(e => e.value === updatesVal) ?? Updates.NONE;

        // Options
        if (optionsStr) {
            // Note: Reconstructing Auth and raw handles might be tricky if not stored fully
            // For now, basic reconstruction if the JSON matches
            const optsObj = JSON.parse(optionsStr) as Record<string, ESObject>;
            // Simplified reconstruction:
            params.options = new TaskOptions(
                optsObj.beforeTaskStartRawHandle as number,
                optsObj.onTaskStartRawHandle as number,
                optsObj.onTaskFinishedRawHandle as number,
                optsObj.auth ? new Auth(optsObj.auth.user, optsObj.auth.password) : undefined
            );
        }

        return new Task(params);

    } catch (e) {
        console.error(TaskDatabase.TAG, `Error deserializing task from DB: ${e}`);
        return undefined;
    }
  }
}
