# Moodiary W9.5.2 交付与接续说明

日期：2026-11-08（北京时间）。接续“聊天2-日记软件迭代项目讨论”的 W9.5.1。

## 成品

[下载 W9.5.2 验证包（ZIP，内含 APK 和校验记录）](https://github.com/promiseMMD/codex-learning/actions/runs/42424085662/artifacts/13594238399)

压缩包内 APK 名称：`Moodiary_V3_W9_5_2_Daily_Timeline_arm64.apk`。
另含 `verification.json`、`signature.txt`、`manifest.txt`。

| 项目 | 验证结果 |
| --- | --- |
| 应用版本 | 2.9.2+101，开发验证包 |
| 包名 | cn.yooss.moodiary.v3dev |
| 架构 | arm64-v8a |
| APK 大小 | 56,755,490 字节 |
| SHA-256 | 1b0ea183c3b9da10ca341e042b85f471c921fb43835d39406e6d6a0b80a4aa42 |
| Android | minSdk 28 / targetSdk 36 |
| 签名 | Android apksigner 验证成功，APK Signature Scheme v2 |
| ZIP / 资源 | CRC、包名、版本、ABI、网页与原生编辑器资源均通过 |
| 构建 CI | [42421819359，成功](https://github.com/promiseMMD/codex-learning/actions/runs/42421819359) |
| 独立成品校验 | [42424085662，成功](https://github.com/promiseMMD/codex-learning/actions/runs/42424085662) |
| 下载保留期限 | 当前 GitHub 成品保留至 2026-12-08 07:11（北京时间），应在到期前下载 |

运行环境在出包后中断，未能保存为直接下载附件。通过 GitHub 完成了独立成品验证，并保留了上述可下载产物。源码和本说明已保存到仓库。

## 安装与数据边界

本包与 W9.5.1 的开发签名不同，不能直接覆盖该版本。**请保留带数据的旧包，不要为了强行更新而卸载它。**

- W9.5.1 证书 SHA-256：`c01971ee33e13dec95a43e70ab8c8d9afe21133bc5f61d5046ee6eac8066bee2`。
- W9.5.2 证书 SHA-256：`19a9a5816297abfac1daaba0fbeeeedfd5bc8a67aa42e479aa60a3534c880b3a`。
- 新记录块仍仅保存在手机，尚未接入完整 ZIP/WebDAV 恢复。
- 本次没有迁移、覆盖或删除任何现有手机数据。
- 稳定签名、连续覆盖升级和 HyperOS 真机验收尚未完成。

## 本轮实现

1. 日期入口打开独立当日时间线，搜索、数量、回收站均按日过滤；月度总结不混入当天记录。
2. 当日追加默认所选日期；保存成功关闭底部弹窗，停留原页并刷新数量。
3. 首页置顶主题“＋”直接打开追加弹窗，关闭后仍在首页，避免先跳转主题页。
4. 弹窗不能通过误点遮罩或拖拽关闭；离开草稿继续要求明确确认。
5. 保存结果未知时保留草稿与原请求，同操作、同修订、同正文重试；冲突不静默覆盖。
6. SQLite、手机与 PC 统一使用事件时间 → 原始创建时间 → Block ID 排序；编辑时间不改变顺序。
7. 创建时间来自现有持久化字段，HTTP 不允许伪造；缺失或非法元数据不能被网页当成有效数据。

保留了旧记录入口、普通日记流程、配对/CSRF/撤销、已有 CAS 和失效通知，没有更改数据库版本。

## 验收证据

| 检查 | 结果 |
| --- | --- |
| 编辑器前端测试命令 | 172 项通过 |
| PC 前端测试命令 | 31 项通过 |
| 原生编辑器回归 | 21 项通过 |
| 旧数据库迁移 | 2 项通过 |
| 应用/SQLite/HTTP/组件 | 107 项通过 |
| WebDAV 回归 | 63 项通过 |
| 生产浏览器 | PC 月度场景和原生编辑器资源场景通过 |
| 完整出包 | 正常 Flutter/Rust ARM64 构建成功 |
| 成品独立校验 | 哈希、CRC、包名、版本、资源及 Android 签名通过 |

手机组件包含 390×844 窄屏和 320 像素键盘占位。它不替代 Android WebView、输入法、锁屏及后台保活的真机验证。

## 明确未完成

最终产品目标仍为**同主题、同自然日一篇真实原生日记**。当前月度表只承担存储分区和月份浏览；本轮日视图不等于真实 DailyDiary 已经完成。

- 真实 DailyDiary 唯一映射、普通列表默认显示/本机隐藏开关、最近 3 块预览及专用编辑路由。
- 投影进入普通同步/导出路径前的逐实体保护，防止只备份可读正文却漏掉块历史。
- Topic/Block/Revision/Head/Operation、日期关联、墓碑和附件的完整归档、哈希验证及新设备恢复。
- WebDAV 块传输、双设备离线合并、同块并发及删除/编辑冲突解决。
- 新块持久化草稿、强杀/崩溃恢复；旧 Alpha/Beta 非破坏迁移、幂等重跑及回滚。
- 首页今日次数/最后更新摘要、主题管理和内部标记分离、独立块标题、图片上传及媒体操作日志。
- IANA 主题时区、全局搜索/日历、性能、稳定签名升级和完整真机验收。

## 接续位置

- 功能实现：`b0e80ef56f912912a135df997300dc5eefa2f92b`。
- 主开发分支：`moodiary-v3-w9-5-2-day-timeline-20261108`。
- 独立校验分支：`moodiary-v3-w9-5-2-verify-20261108`。
- 固定上游：`ZhuJHua/moodiary@2c552ddd7939a054122380397fb914cf000824b0`。
- 构建入口：`.github/workflows/moodiary-v3-lan-w1.yml`。
- 本轮增量：`moodiary-v3-w9-5-2/apply_w9_5_2.py`。
- 主要代码：`mod_month_page.dart`、`mod_month_composer.dart`、`mod_month_order.dart`、`mod_month_store.dart`、`mod_lan_month_http.dart` 和 PC `month_api.ts`。
- 生成文案已保存在 `generated-i18n.b64`，CI 重新生成并比较哈希。
- 成品复核程序：`moodiary-v3-w9-5-2/verify_apk.py`，同目录 STATUS.md 为详细阶段状态。

下一阶段优先实现真实 DailyDiary、专用编辑保护和完整备份/恢复，再接通新块同步。不能回退到 W9.4 旧截点重做，也不能在恢复能力验证前自动迁移正式数据或宣称 RC 完成。
