# Moodiary 签名候选 APK 与真机 QA 工作说明

> 规范基准：[Moodiary 长期开发规范 V1.0](MOODIARY_MOD_PROJECT_SPEC_V1.0.md)。
> **只适用于测试候选包，不代表正式 APK 已获准交付。** 原版数据不得清除，用户的原版笔记不得上传 GitHub。

## 当前验收现状

- V1.0 要求原版与魔改版独立包名、数据目录和坚果云 WebDAV 路径。
- 魔改版永久 `applicationId` 已按 V1.0 D02 于 2026-11-10 经用户明确批准固定为 `cn.yooss.moodiary.v3safe`；不再属于待确认事项。永久包名与“签名 QA 候选/正式发布”状态是两回事。
- 当前 v3safe 候选构建目标为显示版本 `2.9.2`、内部 `versionCode 126`；实际 APK 必须由 Manifest 验证脚本和构建来源证明再次核对。
- QA 候选 APK 需要长期稳定签名材料，严禁自动生成临时 JKS 或使用 debug 签名替代。
- 当前开发分支已包含 `.github/workflows/moodiary-v3-release.yml` 手动设备证据核验工作流；其 job 允许 `main` 和经批准的 `moodiary-v3-w9-8-4-*` 分支。GitHub 对未合并到默认分支的工作流可能不显示手动触发入口；在实际 workflow_dispatch 运行并核验同一 APK 与真机证据前，不得声称设备验收通过。
- 自 2026-11-11 起，**公开主仓库的 `build_apk=true` 会主动失败并拒绝签名**；正式签名流程已迁至独立 Private 仓库 [`promiseMMD/moodiary-signing-vault`](https://github.com/promiseMMD/moodiary-signing-vault)。公开源代码只能进行 Fast / Full 回归，不能读取永久签名 Secrets；Private 保险库分开执行无密钥构建与签名作业。只有通过签名和真机验收的候选才能进入正式交付判断。

## 构建候选包前的必备检查

1. 检查 Fast CI 与 Full Acceptance。签名包构建在全回归之后执行。
2. **用户已批准完全云端生成 JKS，禁止要求用户本地运行脚本或安装 JDK。** 在独立 Private 保险库的 GitHub Actions 网页配置临时 PAT 与独立恢复口令后，手动执行 `Cloud Signing Identity Bootstrap`；永久 JKS 仅保存在私人保险库的四项 `MOODIARY_SAFE_*` Actions Secrets，并将**AES-256-GCM 加密备份**保存至私人保险库 `backups/`。用户必须在密码管理器中另存恢复口令。旧 PowerShell 脚本仅为历史备用，**不是本项目认可的当前操作步骤**。
3. 签名配置不存在、证书不匹配、APK 包名/版本不匹配、没有可靠构建证明时，候选 APK 构建必须失败，不得降级为 debug 包。
4. 从 Private 保险库 `Build Without Secrets and Sign Privately` 手动工作流获取 `Moodiary-V3Safe-Permanent-Signer-ARM64-QA` artifact。它是**签名 QA 候选**，包含 APK、SHA-256、签名和构建来源信息；不能仅凭文件存在判定通过原版数据迁移或正式验收。现有 `moodiary-ci/check-qa-artifact.py` 仍绑定旧公开构建证据格式，**尚未适配私人保险库的新 artifact**，必须补齐校验后再声称自动证据验收通过。

## 不依赖默认分支的候选包证据核验

**以下为旧公开仓库候选包的历史验收命令，当前私人签名 artifact 不能直接套用；需要后续适配到新来源证明。** 不要求用户在本地执行命令；验收脚本应由云端 CI 或隔离测试环境运行。

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
