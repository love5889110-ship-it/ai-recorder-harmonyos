// VAD + 录音 Foreground Service

import audio from '@ohos.multimedia.audio';
import media from '@ohos.multimedia.media';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import fileIo from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import wifiManager from '@ohos.wifiManager';
import util from '@ohos.util';

const TAG = 'RecorderService';

const REC_SAMPLE_RATE = 16000;
const VAD_THRESHOLD = 0.012;      // 适中阈值，平衡灵敏度和误触发
const VAD_WINDOW_MS = 3000;
const VAD_ACTIVE_RATIO = 0.4;     // 40%帧有声即触发，降低漏录概率
const SILENCE_STOP_MS = 600000;   // 10分钟无声才停止（保证一场会议完整录制）
const REC_VAD_THRESHOLD = 0.010;  // 录音中声音检测阈值

// 家庭WiFi SSID列表（连接时不录音）
const HOME_WIFI_SSIDS: string[] = ['chinanet-1802', '18025g'];

export enum RecorderState {
  IDLE = 'idle',
  LISTENING = 'listening',
  RECORDING = 'recording',
}

export class RecorderService {
  private state: RecorderState = RecorderState.IDLE;
  private avRecorder: media.AVRecorder | null = null;
  private audioCapturer: audio.AudioCapturer | null = null;
  private currentFilePath: string = '';
  private onStateChange?: (s: RecorderState, filePath?: string) => void;
  private context: common.UIAbilityContext;
  private vadActiveFrames: number[] = [];
  private vadTotalFrames: number[] = [];
  private silenceTimerId: number = -1;
  private silenceStart: number = 0;
  private foregroundStarted: boolean = false;
  private recordStartTs: number = 0;
  private micRetryCount: number = 0;
  private readonly MIC_MAX_RETRY: number = 3;
  private recVadCapturer: audio.AudioCapturer | null = null;

  constructor(ctx: common.UIAbilityContext, cb?: (s: RecorderState, fp?: string) => void) {
    this.context = ctx;
    this.onStateChange = cb;
  }

  async startForeground(): Promise<void> {
    if (this.foregroundStarted) return;
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: 'com.aiassistant.recorder', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
      };
      const wa = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        wa
      );
      this.foregroundStarted = true;
    } catch (e) {
      console.error(TAG, '启动后台服务失败：', JSON.stringify(e));
    }
  }

  async stopForeground(): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.foregroundStarted = false;
    } catch (e) {
      console.error(TAG, '停止后台服务失败：', JSON.stringify(e));
    }
  }

  async startListening(): Promise<void> {
    if (this.state !== RecorderState.IDLE) return;
    this.setState(RecorderState.LISTENING);

    const capturerOptions: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_8000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };

    try {
      this.audioCapturer = await audio.createAudioCapturer(capturerOptions);
      // 监听音频中断（电话/其他App抢占麦克风）
      this.audioCapturer.on('audioInterrupt', async (interruptEvent: audio.InterruptEvent) => {
        if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
          // 被系统强制中断（如来电），先释放资源再重置状态
          AppStorage.set<string>('vadDebug', '📞 麦克风被中断，等待恢复...');
          const cap = this.audioCapturer;
          this.audioCapturer = null;
          this.setState(RecorderState.IDLE);
          try { await cap?.stop(); await cap?.release(); } catch {}
          setTimeout(() => { this.micRetryCount = 0; this.startListening(); }, 5000);
        }
      });
      await this.audioCapturer.start();
      this.micRetryCount = 0; // 成功后重置重试计数
      this.vadActiveFrames = [];
      this.vadTotalFrames = [];
      AppStorage.set<string>('vadDebug', '监听中...');
      this.readVAD();
    } catch (e) {
      if (this.audioCapturer) {
        try { await this.audioCapturer.stop(); await this.audioCapturer.release(); } catch {}
        this.audioCapturer = null;
      }
      this.setState(RecorderState.IDLE);
      this.micRetryCount++;
      // 前3次快速重试（3/6/9秒），之后每30秒无限重试，确保通话结束后能自动恢复
      const delay = this.micRetryCount <= this.MIC_MAX_RETRY
        ? 3000 * this.micRetryCount
        : 30000;
      AppStorage.set<string>('micError', `麦克风启动失败，${delay/1000}秒后重试...（${JSON.stringify(e)}）`);
      setTimeout(() => { this.startListening(); }, delay);
    }
  }

  private readVAD(): void {
    if (this.state !== RecorderState.LISTENING || !this.audioCapturer) return;
    const capturer = this.audioCapturer;
    capturer.read(1024, true, (err: Error, buf: ArrayBuffer) => {
      if (err || this.state !== RecorderState.LISTENING) return;
      const rms = this.calcRMS(buf);
      const now = Date.now();

      this.vadTotalFrames.push(now);
      if (rms > VAD_THRESHOLD) {
        this.vadActiveFrames.push(now);
      }
      const cutoff = now - VAD_WINDOW_MS;
      this.vadTotalFrames = this.vadTotalFrames.filter(t => t > cutoff);
      this.vadActiveFrames = this.vadActiveFrames.filter(t => t > cutoff);

      const ratio = this.vadTotalFrames.length > 0
        ? this.vadActiveFrames.length / this.vadTotalFrames.length : 0;

      AppStorage.set<string>('vadDebug',
        `音量: ${rms.toFixed(4)}  活跃: ${(ratio * 100).toFixed(0)}%`);

      if (ratio >= VAD_ACTIVE_RATIO && this.vadTotalFrames.length >= 20) {
        this.stopListeningStartRecording();
        return;
      }
      setTimeout(() => this.readVAD(), 50);
    });
  }

  private async stopListeningStartRecording(): Promise<void> {
    if (this.audioCapturer) {
      try {
        await this.audioCapturer.stop();
        await this.audioCapturer.release();
      } catch {}
      this.audioCapturer = null;
    }

    // 检查是否连接家庭WiFi，是则不录音，恢复监听
    if (await this.isHomeWifi()) {
      AppStorage.set<string>('vadDebug', '🏠 家庭WiFi，已跳过录音');
      this.setState(RecorderState.IDLE);
      setTimeout(() => { this.startListening(); }, 3000);
      return;
    }

    await this.startRecording();
  }

  private async isHomeWifi(): Promise<boolean> {
    try {
      const info = await wifiManager.getLinkedInfo();
      const ssid = (info.ssid ?? '').toLowerCase().trim();
      return HOME_WIFI_SSIDS.some(h => ssid === h || ssid === `"${h}"`);
    } catch {
      return false;
    }
  }

  private async startRecording(): Promise<void> {
    const dateStr = this.getTodayStr();
    const baseDir = this.context.filesDir + '/recordings';
    const dir = baseDir + `/${dateStr}`;
    try { fileIo.mkdirSync(baseDir); } catch {}
    try { fileIo.mkdirSync(dir); } catch {}

    const ts = Date.now();
    this.currentFilePath = `${dir}/${ts}.m4a`;
    this.recordStartTs = ts;

    let fd: number = -1;
    try {
      fd = fileIo.openSync(this.currentFilePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE).fd;
    } catch (e) {
      AppStorage.set<string>('vadDebug', `创建文件失败: ${JSON.stringify(e)}`);
      this.setState(RecorderState.IDLE);
      setTimeout(() => { this.startListening(); }, 2000);
      return;
    }

    const avConfig: media.AVRecorderConfig = {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
      profile: {
        audioBitrate: 64000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: REC_SAMPLE_RATE,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A,
      },
      url: `fd://${fd}`,
    };

    try {
      this.avRecorder = await media.createAVRecorder();
      await this.avRecorder.prepare(avConfig);
      // 监听录音中断（来电/其他App抢占），中断后保存已录内容并恢复监听
      this.avRecorder.on('stateChange', async (state: media.AVRecorderState) => {
        if (state === 'error' || state === 'idle') {
          if (this.state === RecorderState.RECORDING) {
            AppStorage.set<string>('vadDebug', '📞 录音被中断，保存并恢复监听...');
            await this.stopRecordingAndRestart();
          }
        }
      });
      await this.avRecorder.start();
      this.setState(RecorderState.RECORDING);
      AppStorage.set<string>('vadDebug', '录音中');
      this.silenceStart = Date.now();
      this.startSilenceTimer();
      this.startRecVad(); // 同时开启录音中VAD，有声音时重置静音计时
    } catch (e) {
      AppStorage.set<string>('vadDebug', `录音启动失败: ${JSON.stringify(e)}`);
      if (this.avRecorder) {
        try { await this.avRecorder.release(); } catch {}
        this.avRecorder = null;
      }
      this.setState(RecorderState.IDLE);
      setTimeout(() => { this.startListening(); }, 2000);
    }
  }

  private startSilenceTimer(): void {
    this.silenceStart = Date.now();
    this.silenceTimerId = setInterval(async () => {
      if (this.state !== RecorderState.RECORDING) {
        clearInterval(this.silenceTimerId);
        return;
      }
      if (Date.now() - this.silenceStart >= SILENCE_STOP_MS) {
        clearInterval(this.silenceTimerId);
        await this.stopRecordingAndRestart();
      }
    }, 5000) as number;
  }

  async stopRecordingAndRestart(manual: boolean = false): Promise<void> {
    if (this.silenceTimerId !== -1) {
      clearInterval(this.silenceTimerId);
      this.silenceTimerId = -1;
    }
    // 停止录音中VAD
    if (this.recVadCapturer) {
      try { await this.recVadCapturer.stop(); await this.recVadCapturer.release(); } catch {}
      this.recVadCapturer = null;
    }
    if (!this.avRecorder) {
      this.setState(RecorderState.IDLE);
      return;
    }
    const savedPath = this.currentFilePath;
    const recStartTs = this.recordStartTs;
    try {
      await this.avRecorder.stop();
      await this.avRecorder.release();
      this.avRecorder = null;
    } catch (e) {
      console.error(TAG, '停止录音失败：', JSON.stringify(e));
      this.avRecorder = null;
    }
    // 写 meta.json（时长 + 开始时间戳）
    if (savedPath && recStartTs > 0) {
      try {
        const duration = Math.floor((Date.now() - recStartTs) / 1000);
        const metaPath = savedPath + '.meta.json';
        const fd = fileIo.openSync(metaPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        const content = JSON.stringify({ duration_sec: duration, start_ts: recStartTs });
        const encoder = util.TextEncoder.create('utf-8');
        fileIo.writeSync(fd.fd, encoder.encodeInto(content).buffer as ArrayBuffer);
        fileIo.closeSync(fd.fd);
      } catch {}
    }
    this.setState(RecorderState.IDLE, savedPath);
    if (!manual) {
      setTimeout(() => { this.startListening(); }, 2000);
    }
  }

  private async startRecVad(): Promise<void> {
    const opts: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_8000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };
    try {
      this.recVadCapturer = await audio.createAudioCapturer(opts);
      await this.recVadCapturer.start();
      this.readRecVad();
    } catch {
      // 录音中VAD启动失败不影响主录音，忽略
      this.recVadCapturer = null;
    }
  }

  private readRecVad(): void {
    if (this.state !== RecorderState.RECORDING || !this.recVadCapturer) return;
    const capturer = this.recVadCapturer;
    capturer.read(1024, true, (err: Error, buf: ArrayBuffer) => {
      if (err || this.state !== RecorderState.RECORDING) return;
      const rms = this.calcRMS(buf);
      if (rms > REC_VAD_THRESHOLD) {
        this.silenceStart = Date.now(); // 有声音 → 重置静音计时
      }
      setTimeout(() => this.readRecVad(), 200); // 每200ms检测一次（低功耗）
    });
  }

  private calcRMS(buf: ArrayBuffer): number {
    const view = new Int16Array(buf);
    let sum = 0;
    for (let i = 0; i < view.length; i++) {
      sum += (view[i] / 32768) * (view[i] / 32768);
    }
    return Math.sqrt(sum / view.length);
  }

  private getTodayStr(): string {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  private setState(s: RecorderState, fp?: string): void {
    this.state = s;
    if (this.onStateChange) this.onStateChange(s, fp);
  }

  getState(): RecorderState { return this.state; }
}
