# Moodiary 3.0 开发状态

分支：moodiary-v3-monthly-lan-dev-20261107  
基线：ZhuJHua/moodiary@2c552ddd7939a054122380397fb914cf000824b0

## W1 已编码

- 新 Android flavour：cn.yooss.moodiary.v3dev（不覆盖官方版、Alpha、Beta）。
- 旧 Beta 记录的只读月度索引：年月分组、每日时间升序、最近三条预览。
- Android connectedDevice 前台服务 + WLAN IPv4 HTTP 服务器。
- 手机主动开启、手机确认配对、会话认证、限流、Host/Origin 检查。
- PC 端同源网页，可只读浏览普通日记与长期主题的月份索引。
- 保留 Beta 的草稿持久化、重复提交保护、WebDAV 下行失败阻止上行的回归测试。

CI：见 `.github/workflows/moodiary-v3-lan-w1.yml`（现已整合 W2 测试）。构建载荷：`moodiary-longrecord/build-payload.b64`，解码为 ZIP 后运行 `modkit/apply_beta_patch.py` 与 `modkit/apply_v3_patch.py`。

## W2 已编码（正在 CI 验证）

- 增加独立的 `mod_monthly_ledger.dart` 纯 Dart 数据模型：以 Topic ID + YYYY-MM 确定月度逻辑身份。
- 每个记录块使用 Block ID 和不可变 Revision ID，父修订链完整检查；单独为可选本月总结提供修订。
- 支持离线设备不同记录块的并集合并；同一记录块并发编辑保留冲突双头，删除和编辑冲突同样不覆盖。
- 无效日期、跨月混入、损坏/截断的修订链、重复版本 ID 都拒绝处理；最近三条预览按事件时间选取再升序展示。
- 新增 9 组月度账本回归测试；并已加入 W2 GitHub Actions 构建流程。具体源码在 `moodiary-v3-w2/ledger-source.zip`。
- **该数据层尚未接入原生 Diary 持久化和 WebDAV；不是已可写的真实月度日记功能。** 在完成生产级数据适配之前，不进行实际历史记录迁移。
- GitHub Actions W2：`https://github.com/promiseMMD/codex-learning/actions/runs/42346866794`。

## 严格未完成

- 每主题/每月唯一的真实原生 Diary，以及将已实现的纯 Dart 块级修订模型接入持久化与 WebDAV。
- 电脑端新建、编辑普通日记、完整 Tiptap 富文本、图片上传。
- 月度总结、跨月移动、WebDAV 冲突副本与旧 Beta 无损迁移。
- 系统强杀/HyperOS 3 的锁屏真机稳定性测试；稳定 APK 签名。

### 安全说明

W1 是只读开发验证包，所有写入 API 明确拒绝（405），避免未完成的编辑逻辑修改老日记。HTTP 局域网访问不加密；请仅在可信 Wi-Fi 与隔离测试 WebDAV 目录使用，不要把旧 Beta 与 v3dev 同时连接正式可写目录。
