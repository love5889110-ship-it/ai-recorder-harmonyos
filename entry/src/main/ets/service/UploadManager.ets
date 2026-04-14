// 上传管理器

import fileIo from '@ohos.file.fs';
import http from '@ohos.net.http';
import connection from '@ohos.net.connection';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';

const TAG = 'UploadManager';

export interface UploadConfig {
  serverUrl: string;
  uploadHourStart: number;
  uploadHourEnd: number;
}

interface PendingFile {
  filePath: string;
  dateDir: string;
  filename: string;
}

export class UploadManager {
  private config: UploadConfig;
  private filesDir: string;
  private context: common.UIAbilityContext;

  constructor(filesDir: string, cfg: UploadConfig, context?: common.UIAbilityContext) {
    this.filesDir = filesDir;
    this.config = cfg;
    this.context = context as common.UIAbilityContext;
  }

  getServerUrl(): string {
    return this.config.serverUrl;
  }

  private async isWifiConnected(): Promise<boolean> {
    try {
      return connection.hasDefaultNetSync();
    } catch {
      return false;
    }
  }

  private readMetaDuration(filePath: string): number {
    try {
      const metaPath = filePath + '.meta.json';
      fileIo.accessSync(metaPath);
      const mf = fileIo.openSync(metaPath, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(512);
      const bytesRead = fileIo.readSync(mf.fd, buf);
      fileIo.closeSync(mf.fd);
      const text = String.fromCharCode(...new Uint8Array(buf, 0, bytesRead));
      const meta = JSON.parse(text) as Record<string, number>;
      return meta['duration_sec'] ?? 0;
    } catch {
      return 0;
    }
  }

  async uploadPending(logFn?: (msg: string, done?: number, total?: number) => void): Promise<number> {
    const log = (msg: string, done?: number, total?: number) => {
      console.info(TAG, msg);
      if (logFn) logFn(msg, done, total);
    };
    if (!await this.isWifiConnected()) {
      logFn?.('❌ 未连接网络，无法上传', 0, -1);
      console.info(TAG, '未连接网络，跳过上传');
      return 0;
    }
    const recordingsDir = this.filesDir + '/recordings';
    logFn?.(`📂 扫描目录: ${recordingsDir}`, 0, 0);
    const pendingFiles: Array<PendingFile> = [];

    // 先扫描所有待上传文件
    try {
      const dateDirs = fileIo.listFileSync(recordingsDir);
      logFn?.(`📁 找到 ${dateDirs.length} 个日期目录`, 0, 0);
      for (const dateDir of dateDirs) {
        const dirPath = `${recordingsDir}/${dateDir}`;
        const files = fileIo.listFileSync(dirPath);
        const m4aFiles = files.filter(f => f.endsWith('.m4a') || f.endsWith('.wav'));
        logFn?.(`  ${dateDir}: ${m4aFiles.length} 个录音`, 0, 0);
        for (const filename of files) {
          if (!filename.endsWith('.m4a') && !filename.endsWith('.wav')) continue;
          const filePath = `${dirPath}/${filename}`;
          const donePath = `${dirPath}/${filename}.uploaded`;
          let alreadyUploaded = false;
          try { fileIo.accessSync(donePath); alreadyUploaded = true; } catch {}
          if (alreadyUploaded) {
            logFn?.(`    ✅ 已上传: ${filename}`, 0, 0);
            continue;
          }
          logFn?.(`    ⏳ 待上传: ${filename}`, 0, 0);
          const pf: PendingFile = { filePath: filePath, dateDir: dateDir, filename: filename };
          pendingFiles.push(pf);
        }
      }
    } catch (e) {
      logFn?.(`❌ 扫描目录失败：${JSON.stringify(e)}（目录可能不存在）`, 0, -1);
      console.error(TAG, `扫描录音目录失败：${JSON.stringify(e)}`);
      return 0;
    }

    const total = pendingFiles.length;
    if (total === 0) {
      logFn?.('✅ 没有待上传文件', 0, -1);
      return 0;
    }

    // 报告总数
    logFn?.(`发现 ${total} 个待上传文件`, 0, total);

    let uploaded = 0;
    for (let i = 0; i < pendingFiles.length; i++) {
      const pf = pendingFiles[i];
      const filePath = pf.filePath;
      const dateDir = pf.dateDir;
      const filename = pf.filename;
      const donePath = filePath + '.uploaded';
      log(`上传：${dateDir}/${filename}`);
      const duration = this.readMetaDuration(filePath);
      const ok = await this.uploadFile(filePath, dateDir, duration, log);
      if (ok) {
        const f = fileIo.openSync(donePath, fileIo.OpenMode.CREATE);
        fileIo.closeSync(f.fd);
        uploaded++;
        logFn?.(`✅ ${filename}${duration > 0 ? '  ' + Math.round(duration/60) + 'm' : ''}`, i + 1, total);
      } else {
        logFn?.(`❌ ${filename} 上传失败`, i + 1, total);
      }
    }
    return uploaded;
  }

  async uploadSingleFile(filePath: string, log?: (m: string) => void): Promise<boolean> {
    if (!await this.isWifiConnected()) return false;
    const parts = filePath.split('/');
    const date = parts[parts.length - 2] ?? new Date().toISOString().slice(0, 10);
    const logFn = log ?? ((_m: string) => {});
    const duration = this.readMetaDuration(filePath);
    const ok = await this.uploadFile(filePath, date, duration, logFn);
    if (ok) {
      try {
        const f = fileIo.openSync(filePath + '.uploaded', fileIo.OpenMode.CREATE);
        fileIo.closeSync(f.fd);
      } catch {}
    }
    return ok;
  }

  private async uploadFile(filePath: string, date: string, duration: number, log: (m: string) => void): Promise<boolean> {
    const httpReq = http.createHttp();
    try {
      const stat = fileIo.statSync(filePath);
      const totalKB = Math.floor(stat.size / 1024);
      log(`  大小：${totalKB}KB${duration > 0 ? '  时长：' + duration + 's' : ''}`);

      const f = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      await fileIo.read(f.fd, buf);
      fileIo.closeSync(f.fd);

      const boundary = `----HarmonyBoundary${Date.now()}`;
      const filename = filePath.split('/').pop() ?? 'audio.m4a';
      const prefix = `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${filename}"\r\nContent-Type: audio/mp4\r\n\r\n`;
      const suffix = `\r\n--${boundary}\r\nContent-Disposition: form-data; name="date"\r\n\r\n${date}\r\n--${boundary}\r\nContent-Disposition: form-data; name="source"\r\n\r\nharmony\r\n--${boundary}\r\nContent-Disposition: form-data; name="duration_sec"\r\n\r\n${duration}\r\n--${boundary}--\r\n`;

      const encoder = util.TextEncoder.create('utf-8');
      const prefixBytes = encoder.encodeInto(prefix).buffer;
      const suffixBytes = encoder.encodeInto(suffix).buffer;
      const body = new Uint8Array(prefixBytes.byteLength + stat.size + suffixBytes.byteLength);
      body.set(new Uint8Array(prefixBytes), 0);
      body.set(new Uint8Array(buf), prefixBytes.byteLength);
      body.set(new Uint8Array(suffixBytes), prefixBytes.byteLength + stat.size);

      log(`  发送中...`);
      const response = await httpReq.request(
        `${this.config.serverUrl}/api/conversations/upload`,
        {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
          extraData: body.buffer as ArrayBuffer,
          connectTimeout: 15000,
          readTimeout: 120000,
        }
      );
      if (response.responseCode === 200) {
        log(`  ✅ 已接收`);
        return true;
      } else {
        log(`  ❌ 服务器返回 ${response.responseCode}`);
        return false;
      }
    } catch (e) {
      log(`  ❌ 失败：${JSON.stringify(e)}`);
      return false;
    } finally {
      httpReq.destroy();
    }
  }
}
