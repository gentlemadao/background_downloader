import { common } from '@kit.AbilityKit';
import { FlutterPage } from '@ohos/flutter_ohos'

// 推荐使用全局变量或 AppStorage 代替 LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry
@Component
struct Index {
  // 在 API 12+ 中，推荐通过构造函数或在生命周期中获取 context
  // 这里使用 getContext() 的现代转型
  private context = getContext() as common.UIAbilityContext;
  @StorageLink('viewId') viewId: string = "";

  build() {
    Column() {
      // 这里的 viewId 如果是通过 AppStorage 传递的，建议使用 @StorageLink
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}