import UIAbility from '@ohos.app.ability.UIAbility';
import hilog from '@ohos.hilog';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import preferences from '@ohos.data.preferences';
import { RecorderService, RecorderState } from '../service/RecorderService';
import { UploadManager } from '../service/UploadManager';
import { GlobalService } from '../service/GlobalService';

const DOMAIN = 0xAA00;
const TAG = 'EntryAbility';
const PREFS_KEY = 'ai_recorder_prefs_v2';
const DEFAULT_SERVER_URL = 'http://192.168.10.106:5678';

export default class EntryAbility extends UIAbility {
  private recorderService: RecorderService | null = null;
  private uploadManager: UploadManager | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    AppStorage.setOrCreate<string>('recorderState', 'idle');
    AppStorage.setOrCreate<string>('micError', '');
    AppStorage.setOrCreate<string>('vadDebug', '');
    AppStorage.setOrCreate<boolean>('autoUpload', false);
    AppStorage.setOrCreate<string>('serverUrl', DEFAULT_SERVER_URL);

    // 先加载偏好设置，再初始化服务（避免竞态）
    this.initFromPrefs();
  }

  private async initFromPrefs(): Promise<void> {
    let serverUrl = DEFAULT_SERVER_URL;
    let autoUpload = false;
    try {
      const prefs = await preferences.getPreferences(this.context, PREFS_KEY);
      serverUrl = await prefs.get('serverUrl', DEFAULT_SERVER_URL) as string;
      autoUpload = await prefs.get('autoUpload', false) as boolean;
      hilog.info(DOMAIN, TAG, `偏好加载完成: serverUrl=${serverUrl}, autoUpload=${autoUpload}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `读取偏好设置失败: ${JSON.stringify(e)}`);
    }

    // 写入 AppStorage，让 Index.ets 读到正确值
    AppStorage.set<boolean>('autoUpload', autoUpload);
    AppStorage.set<string>('serverUrl', serverUrl);

    // 用真实的服务器地址创建 UploadManager
    this.uploadManager = new UploadManager(this.context.filesDir, {
      serverUrl: serverUrl,
      uploadHourStart: 0,
      uploadHourEnd: 24,
    }, this.context);

    // 创建 RecorderService，录音结束回调中读取最新 serverUrl
    this.recorderService = new RecorderService(
      this.context,
      (state: RecorderState, filePath?: string) => {
        hilog.info(DOMAIN, TAG, `状态变更: ${state}, 文件: ${filePath ?? ''}`);
        AppStorage.set<string>('recorderState', state as string);

        if (filePath && AppStorage.get<boolean>('autoUpload')) {
          // 每次上传前读取最新 serverUrl（用户可能在 App 里改过）
          const latestUrl = AppStorage.get<string>('serverUrl') ?? DEFAULT_SERVER_URL;
          if (!this.uploadManager || latestUrl !== this.uploadManager.getServerUrl()) {
            this.uploadManager = new UploadManager(this.context.filesDir, {
              serverUrl: latestUrl,
              uploadHourStart: 0,
              uploadHourEnd: 24,
            }, this.context);
          }
          this.uploadManager.uploadSingleFile(filePath, (msg: string) => {
            hilog.info(DOMAIN, TAG, `自动上传: ${msg}`);
          });
        }
      }
    );

    GlobalService.set(this.recorderService);

    // preferences 加载完毕后再启动录音权限申请
    await this.requestMicAndStart();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `加载页面失败: ${JSON.stringify(err)}`);
      }
    });
  }

  private async requestMicAndStart(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'requestMicAndStart: 开始');
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(
        this.context,
        ['ohos.permission.MICROPHONE']
      );
      const granted = result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      hilog.info(DOMAIN, TAG, `麦克风权限: ${granted}`);
      if (granted) {
        AppStorage.set<string>('micError', '');
        await this.recorderService?.startForeground();
        await this.recorderService?.startListening();
        hilog.info(DOMAIN, TAG, '已自动启动 VAD 监听');
      } else {
        AppStorage.set<string>('micError', '请在设置中授予麦克风权限');
        hilog.error(DOMAIN, TAG, '麦克风权限被拒绝');
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `权限申请失败: ${JSON.stringify(e)}`);
      AppStorage.set<string>('micError', `启动失败: ${JSON.stringify(e)}`);
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground - 保持后台录音运行');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    // App 从后台恢复时，若 VAD 已停止则重新启动
    const currentState = AppStorage.get<string>('recorderState');
    if (currentState === 'idle' && this.recorderService) {
      hilog.info(DOMAIN, TAG, 'onForeground: 检测到 IDLE，重新启动监听');
      this.recorderService.startListening();
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.recorderService?.stopForeground();
  }
}
