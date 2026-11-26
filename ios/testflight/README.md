# FlowArc — TestFlight 与上架材料

- **首次启动隐私告知**：英文、中文和其他受支持语言见 [`arb/`](../../arb/)，搜索 `vpnPrivacyNotice`。首次启动确认后不会开启 VPN；可在「工具 → VPN 隐私告知」重读。
- **公开隐私政策**：[https://flowarc.sub-you.top/privacy](https://flowarc.sub-you.top/privacy)。替换生效日期、发布主体和联系邮箱，再发布为无需登录的 HTTPS 页面。把同一个地址填入 App Store Connect 的 **Privacy Policy URL**，构建分发包时传入 `--dart-define=VPN_PRIVACY_POLICY_URL=<HTTPS URL>`，隐私告知弹窗才会显示该链接。
- **公开支持页**：[https://flowarc.sub-you.top/support](https://flowarc.sub-you.top/support)。替换联系邮箱与隐私政策链接，发布后将页面地址填入 **Support URL**。TestFlight 外部测试的 **Feedback Email** 可填同一个能收信的邮箱。
- **Beta 描述、测试步骤、审核备注**：[review-notes.md](review-notes.md)。正式提交前替换审核专用下载地址，填写 App Store Connect 审核联系人；不需要添加虚构的 App 登录账号。
- **测试配置**：[review-profile.example.yaml](review-profile.example.yaml)。复制到未跟踪的临时目录，替换 `server`、`sni`、端口（若非 443）和密码。`sni` 必须匹配服务器证书；不要关闭证书校验。只用独立、可撤销的审核节点凭据，不用生产订阅。若审核验证 URL 导入，将实际 YAML 放在无需登录、无需预先连接 VPN 的 HTTPS 直链；用未安装旧包的设备完整测试，保持审核期间有效，结束后撤销凭据并移除链接。此示例没有可用节点，不是可直接送审的文件。

## 提交前核对

1. 干净安装：先出现告知，确认后仍未连接；无配置时不能开启；导入并选择审核配置后，用户手动开启才弹系统授权并能访问测试网页。
2. 核对实际分发包：没有服务商登录、内置节点、销售入口、遥测或自动回传。核对测速、出口检查、订阅及资源更新的请求去向；不要把「不向开发者上传」填报成「不联网」。审核配置的托管和测试服务器也不要收集或保留用户的 VPN 活动。
3. 依据实际分发包核对 App Privacy 填报、出口合规及目的地地区的 VPN 要求；这份文案不能代替核查。
4. 打开两个公开地址、核对邮箱能收信，检查 App 内政策入口和 TestFlight 的 FlowArc 名称、图标、Bundle ID、系统 VPN 与控制中心名称。此目录不负责构建、发布网页或上传。
