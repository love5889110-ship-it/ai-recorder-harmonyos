// 全局服务单例桥接
// 让 Index.ets 直接调用 RecorderService，无需跨线程传指令

import { RecorderService } from './RecorderService';

export class GlobalService {
  private static instance: RecorderService | null = null;

  static set(svc: RecorderService): void {
    GlobalService.instance = svc;
  }

  static get(): RecorderService | null {
    return GlobalService.instance;
  }
}
