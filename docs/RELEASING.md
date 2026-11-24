# 发布指南

源码和 APK Release 均发布在公开仓库 `Alone4869/AxPlayer`。App 默认通过 GitHub Releases API 读取这个仓库的最新正式版本，不需要在客户端保存 GitHub 凭据。

## 一次性配置

1. 创建 Android 签名密钥并离线备份。丢失密钥后，已安装用户无法覆盖升级。
2. 在仓库 Actions secrets 中配置 `ANDROID_KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_PASSWORD`、`KEY_ALIAS`。
3. 在仓库的 Actions 设置中允许工作流拥有 `Read and write permissions`。发布工作流使用仓库自带的 `GITHUB_TOKEN` 创建 Release，不需要个人访问令牌。

生成密钥示例：

2.0.0 起应用 ID 是 `io.github.alone4869.axplayer`，与旧的 `m3u8downloader` 包名是两个不同应用，系统层面不存在从旧版覆盖升级的路径。因此新版本使用一把全新的密钥、别名 `axplayer`，不必也不应该沿用旧别名。

```bash
keytool -genkeypair -v \
  -keystore release.jks \
  -alias axplayer \
  -keyalg RSA -keysize 4096 -validity 10000
base64 < release.jks | tr -d '\n'
```

旧的 `release.jks`（别名 `m3u8downloader`）离线归档保留，只在需要给旧包名补发版本时才用；`AxPlayer` 的发布全部使用新密钥。切换密钥时记得同步替换 secrets 里的 `ANDROID_KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_PASSWORD` 和 `KEY_ALIAS` 四项——只改其中一部分会签名失败。

本地正式签名时，在 `android/key.properties` 写入以下内容。该文件和密钥已被 `.gitignore` 排除：

```properties
storePassword=...
keyPassword=...
keyAlias=axplayer
storeFile=/absolute/path/to/release.jks
```

## 发布版本

1. 更新 `pubspec.yaml` 中的 `version: x.y.z+build`，并保证版本号高于已发布版本。
2. 同步更新 `CHANGELOG.md`，提交并推送所有改动，确认 CI 通过。
3. 创建并推送匹配的标签，例如 `git tag v1.2.0 && git push origin v1.2.0`。
4. `release.yml` 会验证标签、运行测试，并使用正式密钥分别构建 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三个 APK。
5. 工作流在本仓库创建 GitHub Release，并按 ARM64、ARMv7、x86_64 的顺序上传三个 APK。App 会根据设备 ABI 自动选择对应文件；无法匹配时打开 Release 页面，不会直接下载错误架构。
6. 从 Release 安装与设备匹配的 APK，确认“设置 > 检查更新”能读到发布版本。

一旦某个应用 ID 用某把密钥发布了正式版，就不要再换密钥——换掉会让已安装用户无法覆盖升级。`AxPlayer` 目前处于新应用 ID 的起步阶段，没有历史包袱，但 `v2.0.0` 发布之后就适用这条规则。不要在源码、日志、Artifact 或 Release 中上传 `key.properties`、JKS 文件或其他凭据。
