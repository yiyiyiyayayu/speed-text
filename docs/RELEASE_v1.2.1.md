# NodeScope 1.2.1

- 调整 IPA 封装以减少全能签 / ESign 导入时的 ZIP 解压兼容问题：使用无压缩 ZIP32，移除 ZIP 扩展字段、资源叉和压缩描述符，将 XML 格式的主包 Info.plist 放在最前面的文件位置。安装包体积因此增加。
- 每次从本次构建的 App 重新生成 IPA，避免旧文件残留；打包和发布均校验浅层 `Payload/NodeScope.app/Info.plist`、本地 ZIP 头、CRC、完整性与 arm64 可执行文件。
- 保留 1.2.0 的暂停与继续、下载测速优化、网络档案、地区排除等功能。此版本未在全能签真机验证，不能据此保证特定版本的全能签一定可以导入。

请直接下载本页 Assets 中的 **NodeScope-unsigned.ipa**，不要将 Actions 的外层 ZIP 改名为 IPA；Actions 产物需要先解压一次，才能得到 IPA。使用原签名身份和 Bundle ID 重签覆盖安装，保留本机设置。

下载完成后可对照 `SHA256SUMS.txt` 校验文件。最低 iOS 16；尚未在 iOS 27 真机验证。
