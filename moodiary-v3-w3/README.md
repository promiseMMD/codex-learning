# Moodiary 3.0 — W3 局域网实时通知模块

开发分支：`moodiary-v3-monthly-lan-dev-20261107`

## 这一批已实现（截至 CI 验证）

- 将 `DiaryRepository.diaryEvents` 转换为仅含日记 ID、变更类型和来源的失效通知。
- 获得手机确认授权的浏览器通过同源 `GET /api/events` 建立 WebSocket。
- 事件有递增序号和独立服务 epoch，支持有界事件补发；事件窗口丢失则通知完整重新获取。
- 手机修改后网页自动刷新普通日记列表与长期记录月度索引；不依赖 WebDAV 网络是否可用。
- 断线提示、重试、心跳与会话撤销后关闭 WebSocket。
- 禁止未授权 WebSocket；验证 Origin/Host；配对状态查询校验来源 IP 和浏览器标识。
- 修正原 W1 的 `HttpHeaders.originHeader` 不存在导致的 Dart 编译错误。
- 提供 W3 事件序号、补发窗口、取消订阅的 Flutter 测试，CI 同时执行 W2 月度修订账本测试。
- 原代码保持 **只读 Web API**；不提供未验证的远端写入接口。

## 必须明确的未完成项

1. 电脑创建、修改普通日记的真正富文本写入与手机数据库乐观并发控制。
2. 图片上传与附件引用原子化处理。
3. 月度块级账本的手机持久化与 WebDAV 同步协议。
4. 两端同一记录的冲突界面和完整双向编辑验收。
5. Android 前台服务真机锁屏运行、稳定签名升级及完整恢复演练。

## 安全与兼容

- 本地 HTTP 传输不加密，仅适用于可信私人局域网。
- Android 包名：`cn.yooss.moodiary.v3dev`；不会覆盖原版、Alpha、Beta。
- 不得让 v3dev 和旧 Beta 同时写入同一个真实 WebDAV 目录。
- W3 只读事件推送并不代表普通日记与月度记录的 PC 写入功能已经完成。

CI 工作流：`.github/workflows/moodiary-v3-lan-w1.yml`（工作流名为 W3）。
