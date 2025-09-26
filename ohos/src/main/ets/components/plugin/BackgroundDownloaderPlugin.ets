import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

/** BackgroundDownloaderPlugin **/
export default class BackgroundDownloaderPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  constructor() {
  }

  getUniqueClassName(): string {
    return "BackgroundDownloaderPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "com.bbflight.background_downloader");
    this.channel.setMethodCallHandler(this)
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case "enqueue":
        // methodEnqueue(call, result)
        result.notImplemented();
        break;
      case "enqueueAll":
        // methodEnqueueAll(call, result)
        result.notImplemented();
        break;
      case "reset":
        // methodReset(call, result)
        result.notImplemented();
        break;
      case "allTasks":
        // methodAllTasks(call, result)
        result.notImplemented();
        break;
      case "cancelTasksWithIds":
        // methodCancelTasksWithIds(call, result)
        result.notImplemented();
        break;
      case "killTaskWithId":
        // methodKillTaskWithId(call, result)
        result.notImplemented();
        break;
      case "taskForId":
        // methodTaskForId(call, result)
        result.notImplemented();
        break;
      case "pause":
        // methodPause(call, result)
        result.notImplemented();
        break;
      case "pauseAll":
        // methodPauseAll(call, result)
        result.notImplemented();
        break;
      case "updateNotification":
        // methodUpdateNotification(call, result)
        result.notImplemented();
        break;
      case "moveToSharedStorage":
        // methodMoveToSharedStorage(call, result)
        result.notImplemented();
        break;
      case "pathInSharedStorage":
        // methodPathInSharedStorage(call, result)
        result.notImplemented();
        break;
      case "openFile":
        // methodOpenFile(call, result)
        result.notImplemented();
        break;
      case "requireWiFi":
        // methodRequireWiFi(call, result)
        result.notImplemented();
        break;
      case "getRequireWiFiSetting":
        // methodGetRequireWiFiSetting(result)
        result.notImplemented();
        break;
      case "chunkStatusUpdate":
        // methodUpdateChunkStatus(call, result)
        result.notImplemented();
        break;
      case "chunkProgressUpdate":
        // methodUpdateChunkProgress(call, result)
        result.notImplemented();
        break;
      case "permissionStatus":
        // methodPermissionStatus(call, result)
        result.notImplemented();
        break;
      case "requestPermission":
        // methodRequestPermission(call, result)
        result.notImplemented();
        break;
      case "shouldShowPermissionRationale":
        // methodShouldShowPermissionRationale(call, result)
        result.notImplemented();
        break;
      case "popResumeData":
        // methodPopResumeData(result)
        result.notImplemented();
        break;
      case "popStatusUpdates":
        // methodPopStatusUpdates(result)
        result.notImplemented();
        break;
      case "popProgressUpdates":
        // methodPopProgressUpdates(result)
        result.notImplemented();
        break;
      case "getTaskTimeout":
        // methodGetTaskTimeout(result)
        result.notImplemented();
        break;
      case "registerCallbackDispatcher":
        // methodRegisterCallbackDispatcher(call, result)
        result.notImplemented();
        break;
      case "configForegroundFileSize":
        // methodConfigForegroundFileSize(call, result)
        result.notImplemented();
        break;
      case "configProxyAddress":
        // methodConfigProxyAddress(call, result)
        result.notImplemented();
        break;
      case "configProxyPort":
        // methodConfigProxyPort(call, result)
        result.notImplemented();
        break;
      case "configRequestTimeout":
        // methodConfigRequestTimeout(call, result)
        result.notImplemented();
        break;
      case "configBypassTLSCertificateValidation":
        // methodConfigBypassTLSCertificateValidation(result)
        result.notImplemented();
        break;
      case "configCheckAvailableSpace":
        // methodConfigCheckAvailableSpace(call, result)
        result.notImplemented();
        break;
      case "configUseCacheDir":
        // methodConfigUseCacheDir(call, result)
        result.notImplemented();
        break;
      case "configUseExternalStorage":
        // methodConfigUseExternalStorage(call, result)
        result.notImplemented();
        break;
      case "configHoldingQueue":
        // methodConfigHoldingQueue(call, result)
        result.notImplemented();
        break;
      case "platformVersion":
        result.success("OpenHarmony");
        break;
      case "forceFailPostOnBackgroundChannel":
        // methodForceFailPostOnBackgroundChannel(call, result)
        result.notImplemented();
        break;
      case "testSuggestedFilename":
        // methodTestSuggestedFilename(call, result)
        result.notImplemented();
        break;
      default:
        result.notImplemented();
        break;
    }
  }
}