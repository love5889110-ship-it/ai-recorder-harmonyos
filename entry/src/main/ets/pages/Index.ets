// ════════════════════════════════════════════════
// 主界面
// 文件：entry/src/main/ets/pages/Index.ets
// ════════════════════════════════════════════════

import { UploadManager } from '../service/UploadManager';
import { GlobalService } from '../service/GlobalService';
import fileIo from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import http from '@ohos.net.http';

const PREFS_KEY = 'ai_recorder_prefs_v2';

function formatDur(sec: number): string {
  if (sec <= 0) return '';
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s > 0 ? `${m}m${s}s` : `${m}m`;
}

@Entry
@Component
struct Index {
  @StorageLink('recorderState') recorderState: string = 'idle';
  @StorageLink('micError') micError: string = '';
  @StorageLink('vadDebug') vadDebug: string = '';
  @State todayCount: number = 0;
  @State serverUrl: string = 'http://192.168.10.106:5678';
  @State autoUpload: boolean = false;
  @State isUploading: boolean = false;
  @State uploadLines: string[] = [];
  @State uploadProgress: number = 0;
  @State uploadTotal: number = 0;
  @State uploadDone: number = 0;
  @State recordingList: RecordingItem[] = [];
  @State activeTab: number = 0;
  @State serverConvList: ServerConv[] = [];
  @State isLoadingServer: boolean = false;
  @State showServerSettings: boolean = false;

  private uploadManager: UploadManager | null = null;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear() {
    this.loadPrefs();
    this.loadRecordingList();
    const svc = GlobalService.get();
    if (svc) {
      AppStorage.set<string>('recorderState', svc.getState() as string);
    }
  }

  onPageShow() {
    const svc = GlobalService.get();
    if (svc) {
      AppStorage.set<string>('recorderState', svc.getState() as string);
    }
    this.loadRecordingList();
  }

  private async loadPrefs() {
    try {
      const prefs = await preferences.getPreferences(this.context, PREFS_KEY);
      const url = await prefs.get('serverUrl', 'http://192.168.10.106:5678') as string;
      this.serverUrl = url;
      const auto = await prefs.get('autoUpload', false) as boolean;
      this.autoUpload = auto;
      AppStorage.set<boolean>('autoUpload', auto);
    } catch {}
  }

  private async savePrefs() {
    try {
      const prefs = await preferences.getPreferences(this.context, PREFS_KEY);
      await prefs.put('serverUrl', this.serverUrl);
      await prefs.put('autoUpload', this.autoUpload);
      await prefs.flush();
    } catch {}
  }

  private async loadRecordingList() {
    const dir = this.context.filesDir + '/recordings';
    const items: RecordingItem[] = [];
    try {
      const dateDirs = fileIo.listFileSync(dir).sort().reverse();
      for (const d of dateDirs.slice(0, 7)) {
        const dirPath = `${dir}/${d}`;
        const files = fileIo.listFileSync(dirPath).sort().reverse();
        for (const f of files) {
          if (!f.endsWith('.m4a') && !f.endsWith('.wav')) continue;
          const uploaded = (() => { try { fileIo.accessSync(`${dirPath}/${f}.uploaded`); return true; } catch { return false; } })();

          // 从文件名（毫秒时间戳）解析时间
          const tsMs = parseInt(f.replace(/\.\w+$/, ''));
          const timeStr = isNaN(tsMs) ? '' : (() => {
            const dt = new Date(tsMs);
            return `${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
          })();

          // 读 .meta.json 获取时长；没有则用文件大小估算（64kbps ≈ 8000 bytes/s）
          let duration = 0;
          try {
            const metaPath = `${dirPath}/${f}.meta.json`;
            fileIo.accessSync(metaPath);
            const mf = fileIo.openSync(metaPath, fileIo.OpenMode.READ_ONLY);
            const buf = new ArrayBuffer(512);
            const bytesRead = fileIo.readSync(mf.fd, buf);
            fileIo.closeSync(mf.fd);
            const text = String.fromCharCode(...new Uint8Array(buf, 0, bytesRead));
            const meta = JSON.parse(text) as Record<string, number>;
            duration = meta['duration_sec'] ?? 0;
          } catch {}
          if (duration === 0) {
            try {
              const stat = fileIo.statSync(`${dirPath}/${f}`);
              duration = Math.floor(stat.size / 8000); // 64kbps 估算
            } catch {}
          }

          let fileSizeKB = 0;
          try {
            const stat = fileIo.statSync(`${dirPath}/${f}`);
            fileSizeKB = Math.floor(stat.size / 1024);
          } catch {}

          items.push({ name: f, date: d, uploaded, path: `${dirPath}/${f}`, timeStr, duration, fileSizeKB, selected: false });
        }
      }
    } catch {}
    this.recordingList = items;
    this.todayCount = items.filter(i => i.date === this.getTodayStr()).length;
  }

  private getTodayStr(): string {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  }

  private deleteSelected(): void {
    const toDelete = this.recordingList.filter(i => i.selected);
    for (const item of toDelete) {
      try { fileIo.unlinkSync(item.path); } catch {}
      try { fileIo.unlinkSync(item.path + '.uploaded'); } catch {}
      try { fileIo.unlinkSync(item.path + '.meta.json'); } catch {}
    }
    this.loadRecordingList();
  }

  private clearUploadedMarks(): void {
    for (const item of this.recordingList) {
      try { fileIo.unlinkSync(item.path + '.uploaded'); } catch {}
    }
    this.loadRecordingList();
  }

  private async loadServerConversations() {
    this.isLoadingServer = true;
    try {
      const req = http.createHttp();
      const resp = await req.request(`${this.serverUrl}/api/conversations?limit=30`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 15000,
      });
      req.destroy();
      if (resp.responseCode === 200) {
        const data = JSON.parse(resp.result as string) as ServerConv[];
        this.serverConvList = data;
      }
    } catch {}
    this.isLoadingServer = false;
  }

  private async deleteServerConv(convId: number) {
    try {
      const req = http.createHttp();
      await req.request(`${this.serverUrl}/api/conversations/${convId}`, {
        method: http.RequestMethod.DELETE,
        connectTimeout: 8000,
        readTimeout: 10000,
      });
      req.destroy();
      this.serverConvList = this.serverConvList.filter(c => c.id !== convId);
    } catch {}
  }

  build() {
    Column() {
      // ── 顶栏 ──────────────────────────────────────
      Row() {
        Text('🎙 对话助手')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text(`今日 ${this.todayCount} 段`)
          .fontSize(13)
          .fontColor('#888')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })
      .backgroundColor('#FFFFFF')

      Scroll() {
        Column() {

          // ── 状态卡片 ────────────────────────────────
          Column() {
            Row() {
              Circle({ width: 12, height: 12 })
                .fill(this.recorderState === 'recording' ? '#FF3B30' :
                      this.recorderState === 'listening' ? '#34C759' : '#AAAAAA')
              Text(this.recorderState === 'recording' ? '录音中...' :
                   this.recorderState === 'listening' ? '待机中，有声音自动录' : '已停止')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .margin({ left: 8 })
            }
            .margin({ bottom: 16 })

            if (this.recorderState === 'idle') {
              Button('开始监听')
                .width('100%')
                .backgroundColor('#34C759')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .height(50)
                .borderRadius(12)
                .onClick(async () => {
                  try {
                    const atManager = abilityAccessCtrl.createAtManager();
                    const result = await atManager.requestPermissionsFromUser(
                      this.context, ['ohos.permission.MICROPHONE']
                    );
                    const granted = result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
                    if (granted) {
                      AppStorage.set<string>('micError', '');
                      GlobalService.get()?.startListening();
                    } else {
                      AppStorage.set<string>('micError', '请在设置中授予麦克风权限');
                    }
                  } catch (e) {
                    GlobalService.get()?.startListening();
                  }
                })
            } else {
              Button('停止监听')
                .width('100%')
                .backgroundColor('#FF3B30')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .height(50)
                .borderRadius(12)
                .onClick(() => {
                  GlobalService.get()?.stopRecordingAndRestart(true);
                })
            }

            Text(this.recorderState === 'listening' ?
              '检测到持续对话声音将自动录音' :
              this.recorderState === 'recording' ?
              '静音3分钟后自动保存' : '点击"开始监听"或重启App自动启动')
              .fontSize(12)
              .fontColor('#888888')
              .margin({ top: 10 })
              .textAlign(TextAlign.Center)

            if (this.micError !== '') {
              Text(this.micError)
                .fontSize(12)
                .fontColor('#FF3B30')
                .margin({ top: 6 })
                .textAlign(TextAlign.Center)
            }
          }
          .width('100%')
          .padding(20)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 14 })
          .shadow({ radius: 8, color: '#0A000000', offsetX: 0, offsetY: 2 })

          // ── 上传控制 ────────────────────────────────
          Column() {
            // 标题行 + 折叠按钮
            Row() {
              Text('上传设置').fontSize(13).fontColor('#888').fontWeight(FontWeight.Medium)
              Blank()
              Text(this.showServerSettings ? '收起 ▲' : '展开 ▼')
                .fontSize(12).fontColor('#007AFF')
                .onClick(() => { this.showServerSettings = !this.showServerSettings; })
            }
            .width('100%')
            .margin({ bottom: this.showServerSettings ? 10 : 0 })

            // 折叠内容：服务器IP + 自动上传
            if (this.showServerSettings) {
              TextInput({ text: this.serverUrl, placeholder: 'http://192.168.x.x:5678' })
                .onChange(v => { this.serverUrl = v; AppStorage.set<string>('serverUrl', v); this.savePrefs(); })
                .fontSize(13)
                .height(40)
                .borderRadius(8)
                .margin({ bottom: 10 })

              Row() {
                Text('自动上传（录音保存后立即上传）').fontSize(13).fontColor('#555').layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.autoUpload })
                  .onChange((v: boolean) => {
                    this.autoUpload = v;
                    AppStorage.set<boolean>('autoUpload', v);
                    this.savePrefs();
                  })
              }
              .width('100%')
              .margin({ bottom: 10 })
            }

            Row() {
              Button('⬆ 上传')
                .onClick(async () => {
                  this.isUploading = true;
                  this.uploadLines = ['扫描录音中...'];
                  this.uploadProgress = 0;
                  this.uploadTotal = 0;
                  this.uploadDone = 0;
                  this.uploadManager = new UploadManager(
                    this.context.filesDir,
                    { serverUrl: this.serverUrl, uploadHourStart: 0, uploadHourEnd: 24 },
                    this.context
                  );
                  await this.uploadManager.uploadPending((msg: string, done?: number, total?: number) => {
                    if (msg) {
                      this.uploadLines = [...this.uploadLines, msg];
                    }
                    if (total !== undefined && total > 0) {
                      this.uploadTotal = total;
                      this.uploadDone = done ?? 0;
                      this.uploadProgress = Math.floor((done ?? 0) / total * 100);
                    }
                    if (total === -1) {
                      this.isUploading = false;
                    }
                  });
                  if (this.isUploading) {
                    this.uploadProgress = 100;
                    this.isUploading = false;
                  }
                  this.loadRecordingList();
                })
                .backgroundColor(this.isUploading ? '#AAAAAA' : '#007AFF')
                .fontColor('#FFFFFF')
                .fontSize(14)
                .height(40)
                .borderRadius(8)
                .enabled(!this.isUploading)
                .layoutWeight(1)

              Blank().width(10)

              Button('↻ 刷新')
                .onClick(() => this.loadRecordingList())
                .backgroundColor('#F0F0F0')
                .fontColor('#333333')
                .fontSize(14)
                .height(40)
                .borderRadius(8)
                .width(70)
            }
            .margin({ top: this.showServerSettings ? 0 : 10 })

            // 进度条 + 日志
            if (this.isUploading || this.uploadLines.length > 0) {
              Column() {
                // 扫描中（total=0）：不确定进度条
                if (this.isUploading && this.uploadTotal === 0) {
                  Progress({ value: 30, total: 100, type: ProgressType.Linear })
                    .width('100%')
                    .height(6)
                    .color('#007AFF')
                    .backgroundColor('#E0E0E0')
                    .margin({ top: 8, bottom: 4 })
                }
                // 上传中（total>0）：确定进度条
                if (this.uploadTotal > 0) {
                  Progress({ value: this.uploadProgress, total: 100, type: ProgressType.Linear })
                    .width('100%')
                    .height(6)
                    .color('#34C759')
                    .backgroundColor('#E0E0E0')
                    .margin({ top: 8, bottom: 2 })
                  Text(`${this.uploadDone} / ${this.uploadTotal} 个文件  ${this.uploadProgress}%`)
                    .fontSize(11)
                    .fontColor('#34C759')
                    .margin({ bottom: 4 })
                }
                ForEach(this.uploadLines.slice(-8), (line: string) => {
                  if (line) {
                    Text(line)
                      .fontSize(11)
                      .fontColor('#888')
                      .fontFamily('monospace')
                      .width('100%')
                  }
                })
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#F8F8FA')
              .borderRadius(8)
              .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .margin({ bottom: 14 })
          .shadow({ radius: 8, color: '#0A000000', offsetX: 0, offsetY: 2 })

          // ── 录音列表 / 已上传 Tab ──────────────────────
          Column() {
            // Tab 标签
            Row() {
              Text('本地录音')
                .fontSize(13)
                .fontWeight(this.activeTab === 0 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.activeTab === 0 ? '#007AFF' : '#888')
                .padding({ bottom: 6 })
                .borderWidth({ bottom: this.activeTab === 0 ? 2 : 0 })
                .borderColor('#007AFF')
                .onClick(() => {
                  this.activeTab = 0;
                  this.loadRecordingList();
                })
              Blank().width(24)
              Text('已上传分析')
                .fontSize(13)
                .fontWeight(this.activeTab === 1 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.activeTab === 1 ? '#007AFF' : '#888')
                .padding({ bottom: 6 })
                .borderWidth({ bottom: this.activeTab === 1 ? 2 : 0 })
                .borderColor('#007AFF')
                .onClick(() => {
                  this.activeTab = 1;
                  this.loadServerConversations();
                })
            }
            .width('100%')
            .margin({ bottom: 12 })

            // Tab 0：本地录音列表
            if (this.activeTab === 0) {
              // 批量操作栏
              if (this.recordingList.some(i => i.selected)) {
                Row() {
                  Button('删除选中')
                    .backgroundColor('#FF3B30')
                    .fontColor('#FFFFFF')
                    .fontSize(13)
                    .height(36)
                    .borderRadius(8)
                    .onClick(() => this.deleteSelected())
                  Blank()
                  Text(`已选 ${this.recordingList.filter(i => i.selected).length} 个`)
                    .fontSize(13)
                    .fontColor('#FF3B30')
                }
                .width('100%')
                .margin({ bottom: 10 })
              }

              if (this.recordingList.length === 0) {
                Text('暂无录音，开始监听后会自动录制').fontSize(13).fontColor('#AAAAAA').margin({ top: 10 })
              } else {
                Row() {
                  Text(`录音文件（${this.recordingList.length}）`)
                    .fontSize(12).fontColor('#AAA').layoutWeight(1)
                  Text('重置上传标记')
                    .fontSize(11).fontColor('#FF9500')
                    .onClick(() => { this.clearUploadedMarks(); })
                }
                .width('100%')
                .margin({ bottom: 6 })
                ForEach(this.recordingList, (item: RecordingItem) => {
                  Row() {
                    Checkbox({ name: item.name, group: 'recGroup' })
                      .select(item.selected)
                      .onChange((v: boolean) => {
                        this.recordingList = this.recordingList.map(r =>
                          r.name === item.name && r.date === item.date
                            ? { name: r.name, date: r.date, uploaded: r.uploaded, path: r.path,
                                timeStr: r.timeStr, duration: r.duration, fileSizeKB: r.fileSizeKB, selected: v }
                            : r
                        );
                      })
                      .width(20)
                      .margin({ right: 8 })

                    Column() {
                      Row() {
                        Text(item.timeStr || item.name.replace(/\.\w+$/, ''))
                          .fontSize(14)
                          .fontWeight(FontWeight.Medium)
                        if (item.duration > 0) {
                          Text(`  ${formatDur(item.duration)}`)
                            .fontSize(12)
                            .fontColor('#007AFF')
                        } else if (item.fileSizeKB > 0) {
                          Text(`  ${item.fileSizeKB}KB`)
                            .fontSize(12)
                            .fontColor('#AAAAAA')
                        }
                      }
                      Text(item.date).fontSize(11).fontColor('#888')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Text(item.uploaded ? '✅' : '·')
                      .fontSize(item.uploaded ? 14 : 20)
                      .fontColor(item.uploaded ? '#34C759' : '#CCCCCC')
                  }
                  .width('100%')
                  .padding({ top: 10, bottom: 10 })
                  Divider().color('#F0F0F0')
                })
              }
            }

            // Tab 1：已上传对话列表（服务端）
            if (this.activeTab === 1) {
              if (this.isLoadingServer) {
                Text('加载中...').fontSize(13).fontColor('#AAAAAA').margin({ top: 10 })
              } else if (this.serverConvList.length === 0) {
                Column() {
                  Text('暂无已上传对话').fontSize(13).fontColor('#AAAAAA').margin({ top: 10 })
                  Button('点击加载')
                    .backgroundColor('#007AFF')
                    .fontColor('#FFF')
                    .fontSize(13)
                    .height(36)
                    .borderRadius(8)
                    .margin({ top: 12 })
                    .onClick(() => this.loadServerConversations())
                }
              } else {
                ForEach(this.serverConvList, (conv: ServerConv) => {
                  Column() {
                    Row() {
                      Column() {
                        Row() {
                          Text(conv.date).fontSize(12).fontColor('#888')
                          if (conv.duration_sec > 0) {
                            Text(`  ${formatDur(conv.duration_sec)}`).fontSize(11).fontColor('#007AFF')
                          }
                        }
                        if (conv.key_points?.scene) {
                          Text(conv.key_points.scene)
                            .fontSize(11)
                            .fontColor('#007AFF')
                            .backgroundColor('#007AFF18')
                            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                            .borderRadius(8)
                            .margin({ top: 2 })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Button('🗑')
                        .backgroundColor('#FFF0F0')
                        .fontColor('#FF3B30')
                        .fontSize(16)
                        .width(40)
                        .height(36)
                        .borderRadius(8)
                        .onClick(() => this.deleteServerConv(conv.id))
                    }
                    .width('100%')
                    .margin({ bottom: 6 })

                    Text(conv.summary || '（分析中...）')
                      .fontSize(13)
                      .fontColor('#333')
                      .width('100%')

                    if (conv.key_points?.next_action) {
                      Text(`→ ${conv.key_points.next_action}`)
                        .fontSize(12)
                        .fontColor('#007AFF')
                        .margin({ top: 4 })
                        .width('100%')
                    }
                  }
                  .width('100%')
                  .padding({ top: 12, bottom: 12 })
                  .alignItems(HorizontalAlign.Start)
                  Divider().color('#F0F0F0')
                })
              }
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0A000000', offsetX: 0, offsetY: 2 })

        }
        .padding({ left: 16, right: 16, top: 14, bottom: 30 })
      }
      .layoutWeight(1)

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0F2F5')
  }
}

interface RecordingItem {
  name: string;
  date: string;
  uploaded: boolean;
  path: string;
  timeStr: string;
  duration: number;
  fileSizeKB: number;
  selected: boolean;
}

interface ServerConv {
  id: number;
  date: string;
  duration_sec: number;
  summary: string;
  key_points: Record<string, string>;
}
