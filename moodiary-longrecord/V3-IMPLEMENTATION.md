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

CI：见 `.github/workflows/moodiary-v3-lan-w1.yml`。构建载荷：`moodiary-longrecord/build-payload.b64`，解码为 ZIP 后运行 `modkit/apply_beta_patch.py` 与 `modkit/apply_v3_patch.py`。

## 严格未完成

- 每主题/每月唯一的真实原生 Diary 与块级修订模型。
- 电脑端新建、编辑普通日记、完整 Tiptap 富文本、图片上传。
- 月度总结、跨月移动、WebDAV 冲突副本与旧 Beta 无损迁移。
- 系统强杀/HyperOS 3 的锁屏真机稳定性测试；稳定 APK 签名。

### 安全说明

W1 是只读开发验证包，所有写入 API 明确拒绝（405），避免未完成的编辑逻辑修改老日记。HTTP 局域网访问不加密；请仅在可信 Wi-Fi 与隔离测试 WebDAV 目录使用，不要把旧 Beta 与 v3dev 同时连接正式可写目录。
