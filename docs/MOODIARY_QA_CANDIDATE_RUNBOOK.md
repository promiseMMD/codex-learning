# Moodiary 签名候选 APK 与真机 QA 工作说明

> 规范基准：[Moodiary 长期开发规范 V1.0](MOODIARY_MOD_PROJECT_SPEC_V1.0.md)。
> **只适用于测试候选包，不代表正式 APK 已获准交付。** 原版数据不得清除，用户的原版笔记不得上传 GitHub。

## 当前验收现状

- V1.0 要求原版与魔改版独立包名、数据目录和坚果云 WebDAV 路径。
- 魔改版候选包使用 `cn.yooss.moodiary.v3safe`；正式长期包名在首次正式发布前仍须确认。
- 当前显示版本 2.9.2、内部 versionCode 126，仅是此候选的配置。
- QA 候选 APK 需要长期稳定签名材料，严禁自动生成临时 JKS 或使用 debug 签名替代。
- **默认 main 分支尚无手动 QA 工作流**，所以不能声称已通过 GitHub workflow_dispatch 的真机门槛。
- 开发分支可经 `[apk-ci]` 推送触发 `apk-after-fast`，在满足签名密钥、CI 和包体校验要求后产生 *signed QA candidate*；这不是正式发布。

## 构建候选包前的必备检查

1. 检查 Fast CI 与 Full Acceptance。签名包构建在全回归之后执行。
2. 用户自行安全生成并保管长期 JKS 密钥（可用仓库已有的 `moodiary-v3-w9-8-4-13/generate-safe-signing-key.ps1`）。**不要把 JKS、Base64、密码发送到聊天或提交仓库**；仅在 GitHub Actions Secrets 中设置四个 `MOODIARY_SAFE_*` 字段，并保存离线备份。
3. 签名配置不存在、证书不匹配、APK 包名/版本不匹配、没有可靠构建证明时，候选 APK 构建必须失败，不得降级为 debug 包。
4. 下载由具体 GitHub Actions Run 产生的 `Moodiary-V3-Safe-<source-sha>-arm64` artifact（包含 APK、SHA-256、BUILD-PROVENANCE.txt、APK-VERIFICATION.json 等）。

## 不依赖默认分支的候选包证据核验

下载并解压候选包 artifact。在具有 Python 3 的电脑上执行：

```bash
python3 moodiary-ci/check-qa-artifact.py \
  --artifact-dir /path/to/extracted-artifact \
  --candidate-run-id <the-exact-GitHub-Actions-run-id> \
  --tested-sha <40-character-source-commit> \
  --tested-apk-sha256 <sha256-of-the-apk-you-installed> \
  --current-sha <same-40-character-source-commit> \
  --expected-workflow-ref refs/heads/<exact-moodiary-v3-w9-8-4-NN-branch>
```

证据校验必须核对下载来源、运行 ID、提交、包名、版本、签名指纹和 APK 字节哈希，并拒绝不匹配的输入。对于未经审核的其他分支，不允许使用此候选 QA 模式。校验只证明**候选 APK 的来源证据一致**，不能证明真机功能正常。

## 真机测试的边界

- 不卸载官方原版、不清除其数据，也不与原版共享 WebDAV 目录。
- 首次在实际小米 / HyperOS 设备启动后检查魔改版数据库是否有预置分类或日记。
- 用**可控的非生产样本备份**先测试导入、编辑、媒体打开、重启、备份恢复和相同签名原地覆盖升级。任何真实官方笔记导入前，应先进行数据备份、格式核验和 C06 验收准备。
- 对真实官方原版导出备份执行 C06 核对：数量、正文、富文本、创建/修改日期、分类标签、地点、图片/音频/视频/附件及失败统计，不得把部分成功当成完整迁移。
- 保存每项 QA 结果、设备型号/系统版本、测试的候选提交和 APK SHA-256，失败不标成成功。

## 正式发布边界

此开发分支的候选 QA 不能代替未来经过审核合并至 main 后的正式发布及设备验收流程；**不为加速交付而合并几百个历史提交**，需单独审查。正式发布守卫 `check-release-readiness.py` 默认仍应拒绝未完成的官方备份与真机验收。
